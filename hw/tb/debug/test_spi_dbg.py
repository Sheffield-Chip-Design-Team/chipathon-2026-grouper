"""SPI Slave + Debug Unit integration tests, over the real wire protocol.

DUT is hw/tb/debug/spi_dbg_top.sv: ahb_spi_s (the debug transport) wired
straight to dbg_ctrl (the Debug Unit), with only the CPU side stubbed
(hw/tb/debug/cpu_stub.py). See spi_dbg_directed.core for why this seam needs
a bench of its own -- the two block-level suites each stub out the *other*
side of it, so a response-phase timing bug between them only ever appeared at
the full SoC level, where every diagnosis loop costs a firmware boot.

What this bench is for, specifically: confirming that a BUS_STATUS/BUS_READ
response arrives on MISO intact, byte-aligned, with the last bit of the last
byte actually launched before the frame ends. That is the behaviour
hw/tb/top/test_debug.py depends on and could not isolate.

The SPI master here (hw/tb/debug/spi_wire_master.py) samples MISO at the top
of each bit period, where the slave's own launch edge has already made the
bit stable -- see that module's docstring for the timing, which is what these
tests had to pin down before the SoC-level suite could be trusted.

    fusesoc run --no-export sharc:soc_ip:spi_dbg_directed
"""

import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from hw.tb.debug.cpu_stub import CpuStub
from hw.tb.debug.spi_wire_master import SpiWireMaster

log = logging.getLogger("cocotb.spi_dbg")

CLK_PERIOD_NS = 10

# STATUS bit positions (Debug Unit.md § STATUS).
STATUS_LOCK_ACTIVE = 1 << 0
STATUS_LOCK_MODE_ACT = 1 << 1
STATUS_LOCK_PENDING = 1 << 2
STATUS_CPU_HALTED = 1 << 3


async def bring_up(dut, memory=None):
    """Clock, reset, a started CpuStub and an idle SPI master."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())

    dut.rst_n.value = 0
    dut.spi_ss.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.dbg_ready.value = 0
    dut.dbg_rdata.value = 0
    dut.dbg_bus_error.value = 0
    dut.cpu_trace_valid.value = 0
    dut.cpu_trace_data.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    stub = CpuStub(dut, memory=memory).start()
    master = SpiWireMaster(dut)
    await master.idle()
    return master, stub


async def start_session(dut, master, mode_bit=0):
    """DBG_ENABLE then BUS_LOCK -- the two-step host sequence of
    GRPR-SPIS-043. Leaves the lock held."""
    await master.dbg_enable_frame()
    await master.bus_lock_frame(mode_bit=mode_bit)
    # LOCK_ACTIVE follows the accepted LOCK by one cycle (GRPR-DBG-009 raises
    # LOCK_PENDING first); the next frame's own setup is far longer than that.
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_status_reports_lock_active(dut):
    """The headline case: BUS_STATUS over the wire reads back the STATUS the
    Debug Unit actually holds.

    A freeze-flavour lock makes STATUS 0x09 (LOCK_ACTIVE | CPU_HALTED). Both
    set bits live in the *last* of the four response bytes, which is what
    makes this frame a good check of response alignment: a response shifted
    by one bit position, or one whose final bit never gets launched before
    the frame ends, turns 0x09 into 0x04 or 0x08 rather than into something
    obviously wrong.
    """
    master, _ = await bring_up(dut)
    await start_session(dut, master, mode_bit=0)

    status = await master.status_frame()
    log.info("STATUS = 0x%08X", status)

    assert status & STATUS_LOCK_ACTIVE, (
        f"STATUS.LOCK_ACTIVE clear: 0x{status:08X} "
        f"(dbg_lock_active={int(dut.dbg_lock_active.value)})"
    )
    assert status & STATUS_CPU_HALTED, f"STATUS.CPU_HALTED clear: 0x{status:08X}"
    assert status == 0x0000_0009, f"STATUS = 0x{status:08X}, expected 0x00000009"


@cocotb.test()
async def test_status_is_stable_across_repeated_reads(dut):
    """Back-to-back BUS_STATUS frames each return the same live value.

    hw/tb/top/test_debug.py polls STATUS in a retry loop, so a response that
    is only correct on the first frame of a session -- or one that goes stale
    because a previous frame left a byte behind -- would strand that loop.
    """
    master, _ = await bring_up(dut)
    await start_session(dut, master, mode_bit=0)

    seen = [await master.status_frame() for _ in range(4)]
    log.info("STATUS x4 = %s", [f"0x{s:08X}" for s in seen])

    assert all(s == 0x0000_0009 for s in seen), (
        f"STATUS not stable across frames: {[f'0x{s:08X}' for s in seen]}"
    )


@cocotb.test()
async def test_status_before_lock_has_no_lock_bits(dut):
    """STATUS is readable without a lock, and reports one.

    Guards against a test that would pass on a response stuck at a constant:
    the same frame that returns 0x09 under a lock must return neither
    LOCK_ACTIVE nor CPU_HALTED before one is taken.

    MISO is driven here because this bench drives spi_miso directly rather
    than through io_ss, whose pad output-enable follows dbg_lock_active
    (GRPR-GPIO-016) -- at the SoC level this same read reaches the pad only
    while a lock is held.
    """
    master, _ = await bring_up(dut)
    await master.dbg_enable_frame()

    status = await master.status_frame()
    log.info("STATUS (no lock) = 0x%08X", status)

    assert not (status & STATUS_LOCK_ACTIVE), (
        f"STATUS.LOCK_ACTIVE set before any BUS_LOCK: 0x{status:08X}"
    )
    assert not (status & STATUS_CPU_HALTED), (
        f"STATUS.CPU_HALTED set before any BUS_LOCK: 0x{status:08X}"
    )


@cocotb.test()
async def test_bus_read_returns_written_bytes(dut):
    """BUS_WRITE then BUS_READ of the same address, both over the wire.

    The payload has bit 7 set in every byte: a response shifted by one bit
    position, or a byte-boundary handoff that drops an MSB, both corrupt
    this where a payload like 0x12345678 would survive unnoticed.
    """
    master, stub = await bring_up(dut)
    await start_session(dut, master, mode_bit=0)

    address = 0x0000_0200
    payload = [0xDE, 0xAD, 0xBE, 0xEF]

    await master.write_frame(address, payload)
    got = await master.read_frame(address, len(payload))
    log.info("read back %s", [hex(b) for b in got])

    assert got == payload, (
        f"BUS_READ at 0x{address:08X} returned {[hex(b) for b in got]}, "
        f"expected {[hex(b) for b in payload]}"
    )


@cocotb.test()
async def test_bus_read_of_stub_memory(dut):
    """A BUS_READ of a location the CPU-side stub was primed with.

    Distinct from the write/read pair above: this proves the read path
    carries data that came from the far side of dbg_ctrl, not just data this
    frame's own write left behind in the transport.
    """
    address = 0x0000_0300
    master, _ = await bring_up(dut, memory={address: 0xA5})
    await start_session(dut, master, mode_bit=0)

    got = await master.read_frame(address, 1)
    log.info("read %s", [hex(b) for b in got])

    assert got == [0xA5], f"BUS_READ returned {[hex(b) for b in got]}, expected [0xa5]"


@cocotb.test()
async def test_resume_clears_cpu_halted(dut):
    """DBG_RESUME clears CPU_HALTED but leaves LOCK_ACTIVE set.

    Resuming and releasing the bus are separate operations (GRPR-DBG-027),
    and both halves of that are read back over the wire.
    """
    master, _ = await bring_up(dut)
    await start_session(dut, master, mode_bit=0)

    before = await master.status_frame()
    assert before & STATUS_CPU_HALTED, f"CPU_HALTED clear under lock: 0x{before:08X}"

    await master.resume_frame()
    await ClockCycles(dut.clk, 4)

    after = await master.status_frame()
    log.info("STATUS before=0x%08X after=0x%08X", before, after)

    assert not (after & STATUS_CPU_HALTED), (
        f"STATUS.CPU_HALTED still set after DBG_RESUME: 0x{after:08X}"
    )
    assert after & STATUS_LOCK_ACTIVE, (
        f"DBG_RESUME released the lock as well: 0x{after:08X}"
    )


@cocotb.test()
async def test_unlock_clears_lock_active(dut):
    """BUS_UNLOCK returns the bus, observed over the wire.

    Framed as a STATUS read *before* the unlock and a second one after, since
    the point is that the same frame reports both states.
    """
    master, _ = await bring_up(dut)
    await start_session(dut, master, mode_bit=0)

    assert (await master.status_frame()) & STATUS_LOCK_ACTIVE

    await master.bus_unlock_frame()
    await ClockCycles(dut.clk, 4)

    after = await master.status_frame()
    log.info("STATUS after unlock = 0x%08X", after)

    assert not (after & STATUS_LOCK_ACTIVE), (
        f"STATUS.LOCK_ACTIVE still set after BUS_UNLOCK: 0x{after:08X}"
    )
