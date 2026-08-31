"""A CPU stub standing in for cpu_ss/picorv32 at dbg_ctrl's own boundary.

Per docs/hardware/verification/blocks/Debug Unit Verification Plan.md § The
CPU stub: a real picorv32 will not do "start a transfer and hold it
outstanding for N cycles" on command, which the handover-atomicity sweep
needs, so the block-level bench drives dbg_ctrl directly (DUT `ahb_debug_unit`
== dbg_ctrl standalone) against this model instead of a real CPU.

Responsibilities, mirroring what cpu_ss actually does around the signals this
stub replaces:
  - Answer a debug-sourced bus request (dbg_own/dbg_req/dbg_write/dbg_addr/
    dbg_wdata/dbg_wstrb) with dbg_ready/dbg_rdata/dbg_bus_error, backed by a
    dict memory and an injectable error set - same shape as
    hw/tb/spi_s/spi_s_utils.py's DebugStub, mirrored for the opposite role.
  - Model an independent, on-demand "CPU transfer" that can be held
    outstanding for N cycles, for the handover-atomicity sweep
    (V-DBG-DIR-010).
  - Track cpu_freeze/cpu_rst_req as observed, and retire instructions on
    demand by pulsing cpu_trace_valid/cpu_trace_data, so STEP/trace-capture
    have something to react to.
"""

import logging

import cocotb
from cocotb.triggers import RisingEdge

log = logging.getLogger("cocotb.cpu_stub")

# picorv32 trace_data flag encoding (bits [35:32]), per Debug Unit.md and
# ip/picorv32/picorv32.v's TRACE_BRANCH/TRACE_ADDR/TRACE_IRQ.
TRACE_BRANCH = 0b0001
TRACE_ADDR = 0b0010
TRACE_IRQ = 0b1000


class CpuStub:
    def __init__(self, dut, memory=None, err_addrs=None):
        self.dut = dut
        self.memory = dict(memory or {})
        self.err_addrs = set(err_addrs or [])
        self.requests = []          # (write, addr, wdata_or_none) log
        self._task = None
        self._own_transfer_active = False
        self._own_transfer_hold = 0

    def start(self):
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self):
        if self._task is not None:
            self._task.kill()
            self._task = None

    async def _run(self):
        dut = self.dut
        dut.dbg_ready.value = 0
        dut.dbg_rdata.value = 0
        dut.dbg_bus_error.value = 0

        while True:
            await RisingEdge(dut.clk)
            dut.dbg_ready.value = 0

            if self._own_transfer_hold > 0:
                self._own_transfer_hold -= 1
                continue

            if int(dut.dbg_req.value) != 1:
                continue

            write = int(dut.dbg_write.value)
            addr = int(dut.dbg_addr.value)
            wstrb = int(dut.dbg_wstrb.value)

            if write:
                wdata = int(dut.dbg_wdata.value)
                self.requests.append((True, addr, wdata))
                if addr in self.err_addrs:
                    dut.dbg_bus_error.value = 1
                else:
                    dut.dbg_bus_error.value = 0
                    existing = self.memory.get(addr, 0)
                    for lane in range(4):
                        if wstrb & (1 << lane):
                            shift = lane * 8
                            existing = (existing & ~(0xFF << shift)) | (
                                ((wdata >> shift) & 0xFF) << shift
                            )
                    self.memory[addr] = existing
                dut.dbg_rdata.value = 0
            else:
                self.requests.append((False, addr, None))
                if addr in self.err_addrs:
                    dut.dbg_bus_error.value = 1
                    dut.dbg_rdata.value = 0
                else:
                    dut.dbg_bus_error.value = 0
                    dut.dbg_rdata.value = self.memory.get(addr, 0)

            dut.dbg_ready.value = 1

    async def hold_cpu_transfer(self, cycles):
        """Occupy the bus for `cycles` as if a CPU transfer were outstanding.

        Used by the handover-atomicity sweep: request a lock at every offset
        relative to this window and confirm dbg_own never asserts mid-hold.
        Simplified relative to cpu_ss's real look-ahead timing - this stub
        models "something is using the memory interface right now", which is
        the property GRPR-DBG-009 cares about, not the exact mem_la_* pipeline.
        """
        self._own_transfer_hold = cycles

    def retire(self, wdata_or_target, branch=False, addr_flag=False, irq=False):
        """Pulse cpu_trace_valid/cpu_trace_data for one retirement.

        branch=True encodes TRACE_BRANCH with wdata_or_target as the taken
        target; addr_flag=True encodes TRACE_ADDR (load/store effective
        address - never a PC, see dbg_ctrl.sv's own note on why DBGPC is not
        trace-derived); otherwise this is a plain non-branch retirement
        carrying a write-back value.
        """
        flags = 0
        if branch:
            flags |= TRACE_BRANCH
        if addr_flag:
            flags |= TRACE_ADDR
        if irq:
            flags |= TRACE_IRQ

        self.dut.cpu_trace_valid.value = 1
        self.dut.cpu_trace_data.value = (flags << 32) | (wdata_or_target & 0xFFFFFFFF)

    def clear_retire(self):
        self.dut.cpu_trace_valid.value = 0

    async def retire_one(self, wdata_or_target=0, **kwargs):
        """One full retirement pulse: assert for a cycle, then deassert."""
        self.retire(wdata_or_target, **kwargs)
        await RisingEdge(self.dut.clk)
        self.clear_retire()

    def freeze_asserted(self):
        return int(self.dut.cpu_freeze.value) == 1

    def reset_req_asserted(self):
        return int(self.dut.cpu_rst_req.value) == 1
