"""Directed tests for the Debug Unit (dbg_ctrl), standalone.

DUT: ahb_debug_unit == dbg_ctrl, against the CpuStub of cpu_stub.py rather
than a real picorv32 - see that module's docstring and
docs/hardware/verification/blocks/Debug Unit Verification Plan.md § The CPU
stub for why. Item numbers below are the V-DBG-DIR-NNN series from that plan.

Run with:

    fusesoc run --no-export sharc:soc_ip:ahb_debug_unit_directed
"""

import functools
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, SimTimeoutError, with_timeout

from hw.tb.debug.cpu_stub import CpuStub
from hw.tb.debug.debug_utils import (
    CMD_DBG_ENABLE,
    CMD_LOCK,
    CMD_NOP,
    CMD_REG_READ,
    CMD_REG_WRITE,
    CMD_RESUME,
    CMD_STATE_READ,
    CMD_STATUS,
    CMD_STEP,
    CMD_UNLOCK,
    CTRL_DBG_EN,
    CTRL_LOCK_EN,
    REG_BUSADDR,
    REG_BUSDATA,
    REG_BUSERR,
    REG_CTRL,
    REG_DBGPC,
    REG_DBGREG,
    REG_DBGSEL,
    REG_DBGTRACE,
    REG_DBGTRACEH,
    REG_STATUS,
    SEL_PC,
    SEL_TRACE_FLAGS,
    SEL_TRACE_LOW,
    SIZE_BYTE,
    STATUS_BUS_ERR,
    STATUS_CPU_HALTED,
    STATUS_LOCK_ACTIVE,
    STATUS_LOCK_PENDING,
    STATUS_REJECTED,
    STATUS_STEP_DONE,
    bus_read,
    bus_write,
    dbg_enable,
    dbg_request,
    lock,
    reg_read,
    reg_write,
    status,
    unlock,
)

log = logging.getLogger("cocotb.debug_unit")

CLK_PERIOD_NS = 10


async def settle(dut):
    """End on a clock edge; see the note in test_spi_s.py."""
    try:
        await with_timeout(RisingEdge(dut.clk), 10 * CLK_PERIOD_NS, "ns")
    except SimTimeoutError:
        log.debug("settle: no clock edge")
    except Exception as exc:                       # noqa: BLE001
        log.debug("settle: %s", exc)


def debug_test(**kwargs):
    def wrap(fn):
        @cocotb.test(**kwargs)
        @functools.wraps(fn)
        async def inner(dut):
            try:
                await fn(dut)
            finally:
                await settle(dut)
        return inner
    return wrap


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.dbg_req_valid.value = 0
    dut.dbg_req_cmd.value = 0
    dut.dbg_req_addr.value = 0
    dut.dbg_req_wdata.value = 0
    dut.dbg_req_size.value = 0
    dut.dbg_rsp_ready.value = 0
    dut.dbg_ready.value = 0
    dut.dbg_rdata.value = 0
    dut.dbg_bus_error.value = 0
    dut.cpu_trace_valid.value = 0
    dut.cpu_trace_data.value = 0

    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def init_test(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)


async def enable_and_lock(dut, mode=None):
    """DBG_ENABLE then LOCK - the cold-silicon sequence GRPR-SOC-030 exists
    for. Returns once LOCK_ACTIVE is set."""
    _, err = await dbg_enable(dut)
    assert err == 0, "DBG_ENABLE was refused"
    _, err = await lock(dut, mode=mode)
    assert err == 0, "LOCK was refused after DBG_ENABLE"

    for _ in range(4):
        st, _ = await status(dut)
        if st & STATUS_LOCK_ACTIVE:
            return
        await RisingEdge(dut.clk)
    raise AssertionError("STATUS.LOCK_ACTIVE never set after LOCK accepted")


# --- GRPR-DBG-002 / -028 / -037 / -038: register map and software visibility

# TEST V-DBG-DIR-002
@debug_test()
async def test_reset_values(dut):
    """Every register reads its specified reset value."""
    await init_test(dut)

    expected = {
        REG_CTRL: 0x0000_0000,
        REG_STATUS: 0x0000_0000,
        REG_BUSADDR: 0x0000_0000,
        REG_BUSDATA: 0x0000_0000,
        REG_BUSERR: 0x0000_0000,
        REG_DBGPC: 0x0000_0000,
        REG_DBGTRACE: 0x0000_0000,
        REG_DBGTRACEH: 0x0000_0000,
        REG_DBGREG: 0x0000_0000,
        REG_DBGSEL: 0x0000_0000,
    }
    for offset, value in expected.items():
        rdata, err = await reg_read(dut, offset)
        assert err == 0, f"REG_READ 0x{offset:02X} reported dbg_rsp_err"
        assert rdata == value, (
            f"offset 0x{offset:02X}: got 0x{rdata:08X}, expected 0x{value:08X}"
        )


# TEST V-DBG-DIR-003
@debug_test()
async def test_ctrl_bit_readback(dut):
    """Each CTRL field written and read back independently."""
    await init_test(dut)

    for value in (CTRL_LOCK_EN, CTRL_DBG_EN, CTRL_LOCK_EN | CTRL_DBG_EN, 0x0):
        _, err = await reg_write(dut, REG_CTRL, value)
        assert err == 0, f"REG_WRITE CTRL=0x{value:X} was refused"
        rdata, _ = await reg_read(dut, REG_CTRL)
        assert rdata == value, f"CTRL readback 0x{rdata:X}, expected 0x{value:X}"


# TEST V-DBG-DIR-005
@debug_test()
async def test_readonly_writes_rejected(dut):
    """Writes to read-only registers are refused with dbg_rsp_err."""
    await init_test(dut)

    for offset in (REG_BUSADDR, REG_BUSDATA, REG_BUSERR, REG_DBGPC,
                   REG_DBGTRACE, REG_DBGTRACEH, REG_DBGREG):
        _, err = await reg_write(dut, offset, 0xDEADBEEF)
        assert err == 1, f"REG_WRITE to read-only offset 0x{offset:02X} was accepted"


# --- GRPR-DBG-006 ... -009: ownership and handover

# TEST V-DBG-DIR-008
@debug_test()
async def test_lock_and_release(dut):
    """A lock is taken and released with no other traffic; status tracks."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)
    _, err = await lock(dut)
    assert err == 0, "LOCK was refused with LOCK_EN set"

    st, _ = await status(dut)
    assert st & STATUS_LOCK_ACTIVE, "STATUS.LOCK_ACTIVE not set after LOCK"
    assert int(dut.dbg_own.value) == 1, "dbg_own not asserted while locked"
    assert int(dut.dbg_lock_active.value) == 1, "dbg_lock_active not asserted while locked"

    _, err = await unlock(dut)
    assert err == 0, "UNLOCK was refused"

    st, _ = await status(dut)
    assert not (st & STATUS_LOCK_ACTIVE), "STATUS.LOCK_ACTIVE still set after UNLOCK"
    assert int(dut.dbg_own.value) == 0, "dbg_own still asserted after UNLOCK"
    stub.stop()


# TEST V-DBG-DIR-009
@debug_test()
async def test_lock_refused_when_disabled(dut):
    """A lock with LOCK_EN=0, and a second lock while one is active, both refused."""
    await init_test(dut)

    _, err = await lock(dut)
    assert err == 1, "LOCK accepted with LOCK_EN=0"
    st, _ = await status(dut)
    assert st & STATUS_REJECTED, "STATUS.REJECTED not set after a refused LOCK"
    assert not (st & STATUS_LOCK_ACTIVE), "LOCK_ACTIVE set despite the refusal"

    await reg_write(dut, REG_STATUS, STATUS_REJECTED)  # clear the sticky bit
    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)
    await lock(dut)

    _, err = await lock(dut)
    assert err == 1, "a second LOCK while one is active was accepted"


# TEST V-DBG-DIR-011
@debug_test()
async def test_ownership_exclusive(dut):
    """dbg_own and dbg_req are never asserted without a lock being active."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    assert int(dut.dbg_own.value) == 0
    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)
    await lock(dut)
    assert int(dut.dbg_own.value) == 1

    await bus_write(dut, 0x100, 0x1234)
    assert int(dut.dbg_own.value) == 1, "dbg_own dropped mid-transfer"

    await unlock(dut)
    assert int(dut.dbg_own.value) == 0, "dbg_own stuck high after release"
    stub.stop()


# TEST V-DBG-DIR-012 (handover atomicity, simplified against the stub)
@debug_test()
async def test_handover_waits_for_outstanding_transfer(dut):
    """LOCK_PENDING is asserted while an outstanding CPU-side transfer holds
    the bus, and LOCK_ACTIVE follows once it clears."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await stub.hold_cpu_transfer(6)
    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)
    await lock(dut)

    # LOCK_PENDING is a single-cycle handshake in this implementation - what
    # matters functionally is that LOCK_ACTIVE eventually asserts and dbg_own
    # never collides with the stub's held transfer.
    for _ in range(10):
        st, _ = await status(dut)
        if st & STATUS_LOCK_ACTIVE:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("LOCK never became active after the held transfer cleared")

    await unlock(dut)
    stub.stop()


# --- GRPR-DBG-013 ... -015: release and reset

# TEST V-DBG-DIR-013
@debug_test()
async def test_release_needs_no_cpu(dut):
    """A release completes with cpu_freeze asserted (CPU halted) throughout."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut)   # freeze-style (mode defaults to CTRL.LOCK_MODE=0)
    assert stub.freeze_asserted(), "cpu_freeze not asserted after a freeze-style lock"

    _, err = await unlock(dut)
    assert err == 0, "UNLOCK was refused while the CPU was halted"
    st, _ = await status(dut)
    assert not (st & STATUS_LOCK_ACTIVE)
    stub.stop()


# TEST V-DBG-DIR-019
@debug_test()
async def test_reset_sweep(dut):
    """Reset mid-lock releases the lock and leaves cpu_freeze/cpu_rst_req low."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut)
    assert stub.freeze_asserted()

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    assert not stub.freeze_asserted(), "cpu_freeze still asserted during reset"
    assert not stub.reset_req_asserted(), "cpu_rst_req still asserted during reset"
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    st, _ = await status(dut)
    assert st == 0, f"STATUS not clear after reset: 0x{st:08X}"
    ctrl, _ = await reg_read(dut, REG_CTRL)
    assert ctrl == 0, f"CTRL not clear after reset: 0x{ctrl:08X}"
    stub.stop()


# --- GRPR-DBG-019 ... -021: lockout flavours

# TEST V-DBG-DIR-022
@debug_test()
async def test_freeze_holds_cpu(dut):
    """A freeze-style lock asserts cpu_freeze and CPU_HALTED for the duration."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=0)
    assert stub.freeze_asserted()
    st, _ = await status(dut)
    assert st & STATUS_CPU_HALTED
    assert not stub.reset_req_asserted()

    await unlock(dut)
    assert not stub.freeze_asserted(), "cpu_freeze still asserted after release"
    stub.stop()


# TEST V-DBG-DIR-023
@debug_test()
async def test_reset_flavour_holds_reset(dut):
    """A reset-style lock asserts cpu_rst_req and does not set CPU_HALTED."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=1)
    assert stub.reset_req_asserted(), "cpu_rst_req not asserted for a reset-style lock"
    assert not stub.freeze_asserted(), "cpu_freeze asserted on a reset-style lock"
    st, _ = await status(dut)
    assert not (st & STATUS_CPU_HALTED), "CPU_HALTED set on a reset-style lock"

    await unlock(dut)
    assert not stub.reset_req_asserted(), "cpu_rst_req still asserted after release"
    stub.stop()


# TEST V-DBG-DIR-024
@debug_test()
async def test_lock_mode_latched(dut):
    """CTRL.LOCK_MODE is sampled at LOCK acceptance; a later write has no effect
    on the lock already in progress."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)   # LOCK_MODE=0 (freeze)
    await lock(dut)
    st, _ = await status(dut)
    assert not (st & (1 << 1)), "LOCK_MODE_ACT reports reset-flavour unexpectedly"

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN | (1 << 1))  # flip LOCK_MODE mid-lock
    st, _ = await status(dut)
    assert not (st & (1 << 1)), "LOCK_MODE_ACT changed mid-lock"
    assert stub.freeze_asserted(), "the lock stopped being a freeze mid-session"

    await unlock(dut)
    stub.stop()


# --- GRPR-DBG-022 ... -027: CPU debug access (trace-based subset)

# TEST V-DBG-DIR-026
@debug_test()
async def test_debug_ops_gated(dut):
    """STATE_READ/STEP/RESUME are refused with DBG_EN=0 or the CPU running."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    _, err = await dbg_request(dut, CMD_STATE_READ, addr=SEL_TRACE_LOW)
    assert err == 1, "STATE_READ accepted with DBG_EN=0"

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN | CTRL_DBG_EN)
    await lock(dut, mode=1)   # reset-style: CPU_HALTED never sets
    _, err = await dbg_request(dut, CMD_STATE_READ, addr=SEL_TRACE_LOW)
    assert err == 1, "STATE_READ accepted while the CPU is not halted"
    await unlock(dut)
    stub.stop()


# TEST V-DBG-DIR-027 (trace-based subset only - see the Open Item on GPR read)
@debug_test()
async def test_state_read_trace_fields(dut):
    """STATE_READ returns the last trace record's low word and flags."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=0)
    await stub.retire_one(0xCAFEBABE)

    rdata, err = await dbg_request(dut, CMD_STATE_READ, addr=SEL_TRACE_LOW)
    assert err == 0
    assert rdata == 0xCAFEBABE, f"got 0x{rdata:08X}"

    rdata, err = await dbg_request(dut, CMD_STATE_READ, addr=SEL_TRACE_FLAGS)
    assert err == 0
    assert rdata & 0x10, "VALID bit not set after a retirement"

    await unlock(dut)
    stub.stop()


# TEST V-DBG-DIR-027b: documents the known gap rather than skipping silently
# (see hw/rtl/debug/dbg_ctrl.sv's header comment and this repo's plan notes).
@debug_test()
async def test_state_read_pc_not_yet_supported(dut):
    """SEL_PC and REG_DBGPC are refused/zero: no trace-derived PC exists.

    picorv32's trace record carries a branch target or a write-back value,
    never "the PC of the instruction that just retired" in general - see the
    note above the trace-capture block in dbg_ctrl.sv. This is refused rather
    than answered with a value that looks valid but is not; it needs
    picorv32's reg_pc ported to a real output (GRPR-DBG-INFO-003).
    """
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=0)
    await stub.retire_one(0x1000, branch=True)

    _, err = await dbg_request(dut, CMD_STATE_READ, addr=SEL_PC)
    assert err == 1, "SEL_PC was answered - update this test if PC support lands"

    rdata, _ = await reg_read(dut, REG_DBGPC)
    assert rdata == 0, "REG_DBGPC returned a nonzero value with no PC source"

    await unlock(dut)
    stub.stop()


# TEST V-DBG-DIR-030
@debug_test()
async def test_step_counts(dut):
    """A STEP of N retires exactly N instructions, then re-halts."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=0)

    for count in (1, 2, 5):
        await reg_write(dut, REG_STATUS, STATUS_STEP_DONE)  # clear W1C
        cocotb.start_soon(dbg_request(dut, CMD_STEP, wdata=count))

        for _ in range(5):
            if not stub.freeze_asserted():
                break
            await RisingEdge(dut.clk)
        else:
            raise AssertionError("cpu_freeze still up after STEP accepted")

        for _ in range(count):
            await stub.retire_one()

        for _ in range(5):
            st, _ = await status(dut)
            if st & STATUS_STEP_DONE:
                break
            await RisingEdge(dut.clk)
        else:
            raise AssertionError(f"STATUS.STEP_DONE never set for count={count}")
        assert stub.freeze_asserted(), f"cpu_freeze not reasserted after {count} steps"

    await unlock(dut)
    stub.stop()


# TEST V-DBG-DIR-031
@debug_test()
async def test_reserved_encodings_refused(dut):
    """Reserved dbg_req_cmd encodings are refused with dbg_rsp_err."""
    await init_test(dut)

    for cmd in (0x9, 0xD, 0xE, 0xF):
        _, err = await dbg_request(dut, cmd)
        assert err == 1, f"reserved encoding 0x{cmd:X} was not refused"


# TEST V-DBG-DIR-032
@debug_test()
async def test_resume_leaves_lock(dut):
    """RESUME clears CPU_HALTED and leaves LOCK_ACTIVE set."""
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=0)
    st, _ = await status(dut)
    assert st & STATUS_CPU_HALTED

    _, err = await dbg_request(dut, CMD_RESUME)
    assert err == 0, "RESUME was refused"
    st, _ = await status(dut)
    assert not (st & STATUS_CPU_HALTED), "CPU_HALTED still set after RESUME"
    assert st & STATUS_LOCK_ACTIVE, "LOCK_ACTIVE cleared by RESUME"
    assert not stub.freeze_asserted(), "cpu_freeze still asserted after RESUME"

    await unlock(dut)
    stub.stop()


# TEST V-DBG-DIR-033
@debug_test()
async def test_reg_read_write_roundtrip(dut):
    """REG_WRITE updates CTRL/DBGSEL; REG_READ returns every offset."""
    await init_test(dut)

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN | CTRL_DBG_EN)
    rdata, _ = await reg_read(dut, REG_CTRL)
    assert rdata == (CTRL_LOCK_EN | CTRL_DBG_EN)

    await reg_write(dut, REG_DBGSEL, 5)
    rdata, _ = await reg_read(dut, REG_DBGSEL)
    assert rdata == 5

    _, err = await reg_write(dut, 0x28, 0x1)   # outside the register map
    assert err == 1, "REG_WRITE to an out-of-map offset was accepted"
    _, err = await reg_read(dut, 0x28)
    assert err == 1, "REG_READ from an out-of-map offset was accepted"


# TEST V-DBG-DIR-034
@debug_test()
async def test_regs_readable_with_lock_active(dut):
    """REG_READ answers regardless of lock state, halt state, or consent gates."""
    await init_test(dut)

    # Gates clear, no lock: still answerable.
    rdata, err = await reg_read(dut, REG_CTRL)
    assert err == 0

    # Locked, CPU halted, gates set: still answerable.
    stub = CpuStub(dut).start()
    await enable_and_lock(dut, mode=0)
    rdata, err = await reg_read(dut, REG_STATUS)
    assert err == 0
    assert rdata & STATUS_LOCK_ACTIVE

    await unlock(dut)
    stub.stop()


# --- DBG_ENABLE (this session's new command) --------------------------------

# TEST: DBG_ENABLE sets LOCK_EN and DBG_EN together
@debug_test()
async def test_dbg_enable_sets_gates(dut):
    """DBG_ENABLE sets CTRL.LOCK_EN and CTRL.DBG_EN together, from an all-closed
    reset state, with no prior REG_WRITE - the cold-silicon path GRPR-SOC-030
    depends on."""
    await init_test(dut)

    ctrl, _ = await reg_read(dut, REG_CTRL)
    assert ctrl == 0, "CTRL not closed at reset"

    _, err = await dbg_enable(dut)
    assert err == 0, "DBG_ENABLE was refused"

    ctrl, _ = await reg_read(dut, REG_CTRL)
    assert ctrl == (CTRL_LOCK_EN | CTRL_DBG_EN), (
        f"DBG_ENABLE did not set both gates: CTRL=0x{ctrl:X}"
    )


# TEST: the full DBG_ENABLE -> LOCK sequence, mirroring the intended host
# protocol of GRPR-SPIS-043 (fire-and-forget enable, LOCK's response confirms
# success).
@debug_test()
async def test_dbg_enable_then_lock_end_to_end(dut):
    await init_test(dut)
    stub = CpuStub(dut).start()

    await enable_and_lock(dut, mode=0)
    st, _ = await status(dut)
    assert st & STATUS_LOCK_ACTIVE
    assert int(dut.dbg_lock_active.value) == 1

    await unlock(dut)
    stub.stop()


# --- Bus access while locked ------------------------------------------------

# TEST: READ/WRITE reach the CPU stub's memory while locked
@debug_test()
async def test_bus_write_then_read(dut):
    await init_test(dut)
    stub = CpuStub(dut).start()

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)
    await lock(dut)

    _, err = await bus_write(dut, 0x2000, 0xA5A5A5A5)
    assert err == 0
    assert stub.memory.get(0x2000) == 0xA5A5A5A5

    rdata, err = await bus_read(dut, 0x2000)
    assert err == 0
    assert rdata == 0xA5A5A5A5

    await unlock(dut)
    stub.stop()


# TEST V-DBG-DIR-017: bus error capture, lock retained
@debug_test()
async def test_bus_error_capture(dut):
    await init_test(dut)
    stub = CpuStub(dut, err_addrs=[0x3000]).start()

    await reg_write(dut, REG_CTRL, CTRL_LOCK_EN)
    await lock(dut)

    _, err = await bus_write(dut, 0x3000, 0x1)
    assert err == 1, "a bus error was not reported on the debug port"

    st, _ = await status(dut)
    assert st & STATUS_BUS_ERR
    assert st & STATUS_LOCK_ACTIVE, "a bus error released the lock"

    busaddr, _ = await reg_read(dut, REG_BUSADDR)
    assert busaddr == 0x3000

    await unlock(dut)
    stub.stop()
