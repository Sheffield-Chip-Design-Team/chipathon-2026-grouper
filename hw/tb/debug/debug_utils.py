"""Shared helpers for the Debug Unit's directed cocotb bench.

The debug port is a valid/ready request/response pair, not AHB - see
docs/hardware/design/blocks/Debug Unit.md § Debug Port Interface. This module
gives both the block-level bench (hw/tb/debug/test_debug_unit.py, DUT
ahb_debug_unit == dbg_ctrl standalone) and the SoC-level acceptance tests
(hw/tb/top/) a single place to frame a request and collect its response.
"""

import logging

import cocotb
from cocotb.triggers import RisingEdge, SimTimeoutError, with_timeout

log = logging.getLogger("cocotb.debug")

# --- Debug port commands (Debug Unit.md § Debug Port Commands) -------------

CMD_NOP = 0x0
CMD_LOCK = 0x1
CMD_UNLOCK = 0x2
CMD_READ = 0x3
CMD_WRITE = 0x4
CMD_STATUS = 0x5
CMD_STATE_READ = 0x6
CMD_STEP = 0x7
CMD_RESUME = 0x8
CMD_REG_READ = 0xA
CMD_REG_WRITE = 0xB
CMD_DBG_ENABLE = 0xC

# Transfer sizes (dbg_req_size).
SIZE_BYTE = 0
SIZE_HALF = 1
SIZE_WORD = 2

# Register offsets (§ Register Map).
REG_CTRL = 0x00
REG_STATUS = 0x04
REG_BUSADDR = 0x08
REG_BUSDATA = 0x0C
REG_BUSERR = 0x10
REG_DBGPC = 0x14
REG_DBGTRACE = 0x18
REG_DBGTRACEH = 0x1C
REG_DBGREG = 0x20
REG_DBGSEL = 0x24

# CTRL bits.
CTRL_LOCK_EN = 1 << 0
CTRL_LOCK_MODE = 1 << 1
CTRL_DBG_EN = 1 << 3

# STATUS bits.
STATUS_LOCK_ACTIVE = 1 << 0
STATUS_LOCK_MODE_ACT = 1 << 1
STATUS_LOCK_PENDING = 1 << 2
STATUS_CPU_HALTED = 1 << 3
STATUS_REJECTED = 1 << 5
STATUS_BUS_ERR = 1 << 6
STATUS_STEP_DONE = 1 << 7

# State-read selectors.
SEL_PC = 0x00
SEL_TRACE_LOW = 0x01
SEL_TRACE_FLAGS = 0x02

DEFAULT_TIMEOUT_NS = 1000


async def dbg_request(dut, cmd, addr=0, wdata=0, size=SIZE_WORD,
                       timeout_ns=DEFAULT_TIMEOUT_NS, bus=None, clk=None):
    """Issue one debug-port command and return (rdata, err).

    Drives dbg_req_* until dbg_req_ready, then waits for dbg_rsp_valid and
    immediately asserts dbg_rsp_ready - this bench never needs to hold a
    response back, so there is no reason to model backpressure on this side.

    `bus` and `clk` default to `dut` itself and `dut.clk` (the block-level
    bench, where dbg_req_* lives on the DUT's own port list). The SoC-level
    tests instead pass `bus=dut.u_grouper_soc_dig_ss.u_cpu_ss` (dbg_req_* is
    not brought out past cpu_ss - see Debug Unit.md GRPR-DBG-042 - so this is
    a backdoor VPI path, the same convention hw/tb/top/test_soc.py's own
    cpu_state() already uses) and `clk=dut.clk` (grouper_soc_top's own port).
    """
    bus = dut if bus is None else bus
    clk = dut.clk if clk is None else clk

    bus.dbg_req_valid.value = 1
    bus.dbg_req_cmd.value = cmd
    bus.dbg_req_addr.value = addr
    bus.dbg_req_wdata.value = wdata
    bus.dbg_req_size.value = size

    async def wait_accept():
        while int(bus.dbg_req_ready.value) != 1:
            await RisingEdge(clk)
        await RisingEdge(clk)

    try:
        await with_timeout(wait_accept(), timeout_ns, "ns")
    except SimTimeoutError:
        raise AssertionError(
            f"dbg_req_ready never asserted for cmd=0x{cmd:X} "
            f"addr=0x{addr:08X}"
        ) from None

    bus.dbg_req_valid.value = 0

    async def wait_response():
        while int(bus.dbg_rsp_valid.value) != 1:
            await RisingEdge(clk)

    try:
        await with_timeout(wait_response(), timeout_ns, "ns")
    except SimTimeoutError:
        raise AssertionError(
            f"dbg_rsp_valid never asserted for cmd=0x{cmd:X} "
            f"addr=0x{addr:08X}"
        ) from None

    rdata = int(bus.dbg_rsp_rdata.value)
    err = int(bus.dbg_rsp_err.value)

    bus.dbg_rsp_ready.value = 1
    await RisingEdge(clk)
    bus.dbg_rsp_ready.value = 0

    log.debug(
        "dbg cmd=0x%X addr=0x%08X wdata=0x%08X -> rdata=0x%08X err=%d",
        cmd, addr, wdata, rdata, err,
    )
    return rdata, err


async def reg_read(dut, offset, **kwargs):
    return await dbg_request(dut, CMD_REG_READ, addr=offset, **kwargs)


async def reg_write(dut, offset, value, **kwargs):
    return await dbg_request(dut, CMD_REG_WRITE, addr=offset, wdata=value, **kwargs)


async def status(dut, **kwargs):
    rdata, err = await dbg_request(dut, CMD_STATUS, **kwargs)
    return rdata, err


async def lock(dut, mode=None, **kwargs):
    """Issue LOCK. mode=None uses CTRL.LOCK_MODE; 0/1 overrides it (wdata[8])."""
    wdata = 0
    if mode is not None:
        wdata = (1 << 8) | (mode & 1)
    return await dbg_request(dut, CMD_LOCK, wdata=wdata, **kwargs)


async def unlock(dut, **kwargs):
    return await dbg_request(dut, CMD_UNLOCK, **kwargs)


async def dbg_enable(dut, **kwargs):
    return await dbg_request(dut, CMD_DBG_ENABLE, **kwargs)


async def bus_write(dut, addr, wdata, size=SIZE_WORD, **kwargs):
    return await dbg_request(dut, CMD_WRITE, addr=addr, wdata=wdata, size=size, **kwargs)


async def bus_read(dut, addr, size=SIZE_WORD, **kwargs):
    return await dbg_request(dut, CMD_READ, addr=addr, size=size, **kwargs)
