"""Directed cocotb testbench for ahb_gpio_ctrl.

Written against `docs/hardware/design/blocks/GPIO Mux.md` before the RTL
exists, so this file is the interface contract as much as it is a test. Each
test names the requirement it covers.

Logging
-------
Two levels, both under cocotb's own verbosity control:

    fusesoc run --no-export sharc:comms_ip:ahb_gpio_ctrl_directed
    COCOTB_LOG_LEVEL=DEBUG fusesoc run --no-export sharc:comms_ip:ahb_gpio_ctrl_directed

INFO  - what is being checked, and the result of every check.
DEBUG - every register access by name, plus per-cycle bus detail from
        hw/tb/tb_utils/ahb_utils.py and the data-phase trace of error
        responses.

The bulk sweeps (test_register_readback and friends) drop their per-register
checks to DEBUG, so the default INFO run stays readable - a check per line
would be ~120 lines for one test. Their phase banners stay at INFO.

DUT port list this testbench expects
------------------------------------
    module ahb_gpio_ctrl #(
      parameter int ADDR_WIDTH = 32,
      parameter int DATA_WIDTH = 32,
      parameter int NUM_GPIO   = 16
    ) (
      input  logic                   HCLK,
      input  logic                   HRESETn,

      input  logic [ADDR_WIDTH-1:0]  HADDR,
      input  logic [2:0]             HBURST,
      input  logic                   HMASTLOCK,
      input  logic [3:0]             HPROT,
      input  logic [2:0]             HSIZE,
      input  logic [1:0]             HTRANS,
      input  logic [DATA_WIDTH-1:0]  HWDATA,
      input  logic                   HWRITE,

      output logic [DATA_WIDTH-1:0]  HRDATA,
      output logic                   HREADYOUT,
      output logic                   HRESP,

      input  logic                   HREADYIN,
      input  logic                   HSEL,

      // Mux interface - io_ss muxes these against the alternate function
      input  logic [NUM_GPIO-1:0]    mux_io_i,      // pad value in (GPIO_IN)
      output logic [NUM_GPIO-1:0]    mux_io_o,      // GPIO_OUT
      output logic [NUM_GPIO-1:0]    mux_alt_sel,   // GPIO_ALTSEL

      // Pad interface - straight through io_ss to the pads
      output logic [NUM_GPIO-1:0]    gpio_oe,
      output logic [NUM_GPIO-1:0]    gpio_sync_en_n,
      output logic [NUM_GPIO-1:0]    gpio_ie,
      output logic [NUM_GPIO-1:0]    gpio_pu,
      output logic [NUM_GPIO-1:0]    gpio_pd,
      output logic [NUM_GPIO-1:0]    gpio_cs,
      output logic [NUM_GPIO-1:0]    gpio_sl
    );

"""

import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_BYTE,
    HSIZE_HALF,
    HSIZE_WORD,
    HTRANS_IDLE,
    HTRANS_NONSEQ,
    ahb_read,
    ahb_write,
)

# A child of the "cocotb" logger, so COCOTB_LOG_LEVEL applies to it.
log = logging.getLogger("cocotb.gpio_tb")

CLK_PERIOD_NS = 10

NUM_GPIO = 16
PIN_MASK = (1 << NUM_GPIO) - 1

# Register map - docs/hardware/design/blocks/GPIO Mux.md
GPIO_OUT = 0x00
GPIO_IN = 0x04
GPIO_OE = 0x08
GPIO_ALTSEL = 0x0C
GPIO_RO_MASK = 0x10
GPIO_SYNC_EN_N = 0x14
GPIO_IE = 0x18
GPIO_PU = 0x1C
GPIO_PD = 0x20
GPIO_CS = 0x24
GPIO_SL = 0x28

RESERVED = 0x2C

REG_NAMES = {
    GPIO_OUT: "GPIO_OUT",
    GPIO_IN: "GPIO_IN",
    GPIO_OE: "GPIO_OE",
    GPIO_ALTSEL: "GPIO_ALTSEL",
    GPIO_RO_MASK: "GPIO_RO_MASK",
    GPIO_SYNC_EN_N: "GPIO_SYNC_EN_N",
    GPIO_IE: "GPIO_IE",
    GPIO_PU: "GPIO_PU",
    GPIO_PD: "GPIO_PD",
    GPIO_CS: "GPIO_CS",
    GPIO_SL: "GPIO_SL",
}

# Every read/write register, with the CSR output port it drives. GPIO_OUT and
# GPIO_OE are listed first because the mux in io_ss consumes them.
RW_REGS = [
    ("GPIO_OUT", GPIO_OUT, "mux_io_o"),
    ("GPIO_OE", GPIO_OE, "gpio_oe"),
    ("GPIO_ALTSEL", GPIO_ALTSEL, "mux_alt_sel"),
    ("GPIO_RO_MASK", GPIO_RO_MASK, None),  # internal only, no port
    ("GPIO_SYNC_EN_N", GPIO_SYNC_EN_N, "gpio_sync_en_n"),
    ("GPIO_IE", GPIO_IE, "gpio_ie"),
    ("GPIO_PU", GPIO_PU, "gpio_pu"),
    ("GPIO_PD", GPIO_PD, "gpio_pd"),
    ("GPIO_CS", GPIO_CS, "gpio_cs"),
    ("GPIO_SL", GPIO_SL, "gpio_sl"),
]


def reg_name(addr):
    """Register name for an address, tolerating byte/halfword sub-offsets."""
    word = addr & ~0x3
    name = REG_NAMES.get(word)
    if name is None:
        return f"RESERVED[{word:#04x}]"
    lane = addr & 0x3
    return name if lane == 0 else f"{name}+{lane}"


# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------

def phase(msg, *args):
    """INFO banner naming what is about to be checked."""
    log.info(msg, *args)


def check_eq(actual, expected, what, level=logging.INFO):
    """Log the comparison, then assert it. A mismatch always logs at ERROR."""
    ok = actual == expected
    log.log(
        level if ok else logging.ERROR,
        "CHECK %-44s got 0x%04x  expected 0x%04x  %s",
        what, actual, expected, "ok" if ok else "MISMATCH",
    )
    assert ok, f"{what}: got {actual:#06x}, expected {expected:#06x}"


def check_true(cond, what, level=logging.INFO):
    """Log a boolean check, then assert it."""
    log.log(
        level if cond else logging.ERROR,
        "CHECK %-44s %s", what, "ok" if cond else "FAILED",
    )
    assert cond, what


# --------------------------------------------------------------------------
# Bus helpers
# --------------------------------------------------------------------------

async def start_dut(dut):
    """Start the clock and take the DUT through reset."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())

    dut.HRESETn.value = 0
    dut.HADDR.value = 0
    dut.HBURST.value = 0
    dut.HMASTLOCK.value = 0
    dut.HPROT.value = 0
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_IDLE
    dut.HWDATA.value = 0
    dut.HWRITE.value = 0
    dut.HSEL.value = 0
    dut.HREADYIN.value = 1
    dut.mux_io_i.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)
    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)
    log.debug("reset released")


def port(dut, name):
    """Read a CSR output port as an int."""
    return int(getattr(dut, name).value) & PIN_MASK


async def write_ok(dut, addr, data, size=HSIZE_WORD, what=""):
    """Write, asserting the transfer is accepted without an error response."""
    name = what or reg_name(addr)
    log.debug("wr %-16s <= 0x%08x", name, data)

    hresp = await ahb_write(dut, addr, data, size=size)
    assert hresp == 0, f"{name}: unexpected HRESP on write of {data:#x}"


async def read_ok(dut, addr, what=""):
    """Read, asserting the transfer is accepted without an error response."""
    name = what or reg_name(addr)

    data, hresp = await ahb_read(dut, addr)
    assert hresp == 0, f"{name}: unexpected HRESP on read"

    log.debug("rd %-16s => 0x%08x", name, data)
    return data


async def drive_pads(dut, value):
    """Drive the pad inputs and let them settle."""
    log.debug("pads <= 0x%04x", value)
    dut.mux_io_i.value = value
    await RisingEdge(dut.HCLK)


async def drive_error_write(dut, addr, data, max_cycles=8):
    """Drive a write that is expected to error, holding the address phase.

    Unlike ahb_utils.ahb_write(), this keeps HTRANS/HSEL asserted for as long
    as the slave stalls, which is what a real master does. That makes it a
    check on the DUT as well: while HREADYOUT is low it must not re-sample the
    held address phase, or the transfer lands twice.

    Returns the per-cycle [(HREADYOUT, HRESP), ...] trace of the data phase.
    """
    log.info("expecting ERROR: write %s <= 0x%08x", reg_name(addr), data)

    await RisingEdge(dut.HCLK)
    dut.HADDR.value = addr
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 1
    dut.HWDATA.value = data
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)  # data phase begins, address phase still held

    trace = []
    for _ in range(max_cycles):
        await FallingEdge(dut.HCLK)
        ready = int(dut.HREADYOUT.value)
        resp = int(dut.HRESP.value)
        trace.append((ready, resp))
        log.debug(
            "  data-phase cycle %d: HREADYOUT=%d HRESP=%d", len(trace), ready, resp
        )
        dut.HREADYIN.value = ready
        if ready:
            # Release before the next rising edge, so the slave samples IDLE
            # rather than capturing this transfer a second time.
            dut.HTRANS.value = HTRANS_IDLE
            dut.HSEL.value = 0
            dut.HWRITE.value = 0
            break
        await RisingEdge(dut.HCLK)
    else:
        raise AssertionError(
            f"slave never became ready within {max_cycles} cycles; trace={trace}"
        )

    await RisingEdge(dut.HCLK)
    dut.HREADYIN.value = 1
    return trace


def assert_two_cycle_error(trace, what):
    """Check a data-phase trace is the AHB-Lite two-cycle ERROR response.

    Cycle 1: HREADYOUT low, HRESP high. Cycle 2: HREADYOUT high, HRESP high.
    A single-cycle HRESP - what every other slave in this repo currently does
    - fails here, which is the point of GRPR-GPIO-010.
    """
    shown = " ".join(f"(rdy={r},resp={p})" for r, p in trace)

    check_true(
        len(trace) == 2 and trace[0] == (0, 1) and trace[1] == (1, 1),
        f"two-cycle ERROR on {what} [{shown}]",
    )


# --------------------------------------------------------------------------
# GRPR-GPIO-012 - reset state
# --------------------------------------------------------------------------

@cocotb.test()
async def test_reset_values(dut):
    """Every register resets to 0, and no pad is driven or claimed."""
    await start_dut(dut)

    phase("reset state: all registers zero (GRPR-GPIO-012)")
    for name, addr, _ in RW_REGS:
        value = await read_ok(dut, addr, name)
        check_eq(value, 0, f"{name} reset value")

    phase("reset state: no pad driven, no peripheral connected, inputs off")
    for _, _, port_name in RW_REGS:
        if port_name is not None:
            check_eq(port(dut, port_name), 0, f"{port_name} out of reset")


# --------------------------------------------------------------------------
# GRPR-GPIO-002, -005, -006 - register access and CSR outputs
# --------------------------------------------------------------------------

@cocotb.test()
async def test_register_readback(dut):
    """Each RW register reads back what was written and drives its port."""
    await start_dut(dut)

    for pattern in (0xA5A5, 0x5A5A, 0xFFFF, 0x0001, 0x8000, 0x0000):
        phase("readback sweep with pattern 0x%04x across %d registers",
              pattern, len(RW_REGS))

        for name, addr, port_name in RW_REGS:
            # GPIO_RO_MASK persists between iterations, and a mask left over
            # from the previous pattern would - correctly - reject the next
            # GPIO_OUT write. Clear it first; the mask itself is covered by
            # the test_ro_mask_* tests below.
            await write_ok(dut, GPIO_RO_MASK, 0x0000, what="GPIO_RO_MASK")

            await write_ok(dut, addr, pattern, what=name)

            value = await read_ok(dut, addr, name)
            check_eq(value, pattern, f"{name} readback", level=logging.DEBUG)

            if port_name is not None:
                check_eq(port(dut, port_name), pattern, f"{name} -> {port_name}",
                         level=logging.DEBUG)


@cocotb.test()
async def test_upper_bits_are_reserved(dut):
    """Bits 31:16 read 0 and writing them changes nothing."""
    await start_dut(dut)

    phase("reserved bits 31:16 ignore writes and read back zero")
    for name, addr, _ in RW_REGS:
        await write_ok(dut, addr, 0xFFFF_FFFF, what=name)
        value = await read_ok(dut, addr, name)
        check_eq(value, 0x0000_FFFF, f"{name} after writing 0xffffffff",
                 level=logging.DEBUG)


@cocotb.test()
async def test_registers_are_independent(dut):
    """A write to one register does not disturb any other.

    Cheap to check and worth doing: a decode typo that aliases two offsets
    passes every single-register test above.
    """
    await start_dut(dut)

    phase("writing a distinct value to each register, then re-reading all")

    expected = {}
    for i, (name, addr, _) in enumerate(RW_REGS):
        value = (0x1000 + i) & PIN_MASK
        await write_ok(dut, addr, value, what=name)
        expected[name] = value

    for name, addr, _ in RW_REGS:
        value = await read_ok(dut, addr, name)
        check_eq(value, expected[name], f"{name} undisturbed (decode aliasing?)",
                 level=logging.DEBUG)


# --------------------------------------------------------------------------
# GRPR-GPIO-004 - every pad readable, always
# --------------------------------------------------------------------------

@cocotb.test()
async def test_gpio_in_tracks_pads(dut):
    """GPIO_IN reflects the pad value."""
    await start_dut(dut)

    phase("GPIO_IN follows the pad inputs (GRPR-GPIO-004)")
    for pattern in (0x0000, 0xFFFF, 0xA5A5, 0x1234):
        await drive_pads(dut, pattern)
        value = await read_ok(dut, GPIO_IN, "GPIO_IN")
        check_eq(value, pattern, f"GPIO_IN with 0x{pattern:04x} on the pads")


@cocotb.test()
async def test_gpio_in_readable_when_muxed_away(dut):
    """GPIO_IN still reads the pad with ALTSEL set - GRPR-GPIO-004.

    This is the requirement most likely to be lost in implementation: it is
    tempting to gate GPIO_IN with ALTSEL, but a pad handed to the SPI slave
    must stay observable for debug.
    """
    await start_dut(dut)

    phase("GPIO_IN stays readable with every pad muxed to its alt function")
    await write_ok(dut, GPIO_ALTSEL, 0xFFFF, what="GPIO_ALTSEL")
    await write_ok(dut, GPIO_OE, 0xFFFF, what="GPIO_OE")

    await drive_pads(dut, 0xBEEF)

    value = await read_ok(dut, GPIO_IN, "GPIO_IN")
    check_eq(value, 0xBEEF, "GPIO_IN with ALTSEL=0xffff and OE=0xffff")


@cocotb.test()
async def test_gpio_in_ignores_ie(dut):
    """GPIO_IN is not masked by GPIO_IE inside the block.

    The input enable disables the pad's input buffer out in the pad ring, so
    `mux_io_i` is already 0 for a disabled pad.
    """
    await start_dut(dut)

    phase("GPIO_IN is not masked by GPIO_IE - that gating is the pad cell's")
    await write_ok(dut, GPIO_IE, 0x0000, what="GPIO_IE")
    await drive_pads(dut, 0xCAFE)

    value = await read_ok(dut, GPIO_IN, "GPIO_IN")
    check_eq(value, 0xCAFE, "GPIO_IN with GPIO_IE=0x0000")


@cocotb.test()
async def test_reads_never_error(dut):
    """No read raises an error response - GRPR-GPIO-004."""
    await start_dut(dut)

    phase("sweeping reads across the whole 16-word decode, including reserved")
    for addr in range(0x00, 0x40, 4):
        _, hresp = await ahb_read(dut, addr)
        check_true(hresp == 0, f"read {reg_name(addr)} does not error",
                   level=logging.DEBUG)

    phase("all 16 word offsets read without an error response")


# --------------------------------------------------------------------------
# GRPR-GPIO-009 - byte and halfword writes
# --------------------------------------------------------------------------

@cocotb.test()
async def test_byte_write_touches_one_lane(dut):
    """A byte write updates only its own byte lane."""
    await start_dut(dut)

    phase("byte writes to GPIO_OUT stay within their lane (GRPR-GPIO-009)")
    await write_ok(dut, GPIO_OUT, 0x0000, what="GPIO_OUT")

    # Byte 0 -> bits 7:0
    await write_ok(dut, GPIO_OUT + 0, 0xAA, size=HSIZE_BYTE)
    check_eq(await read_ok(dut, GPIO_OUT), 0x00AA, "GPIO_OUT after byte-0 write")

    # Byte 1 -> bits 15:8. HWDATA is placed in the addressed lane.
    await write_ok(dut, GPIO_OUT + 1, 0xBB << 8, size=HSIZE_BYTE)
    check_eq(await read_ok(dut, GPIO_OUT), 0xBBAA, "GPIO_OUT after byte-1 write")

    # Bytes 2 and 3 land in the reserved half and must change nothing.
    await write_ok(dut, GPIO_OUT + 2, 0xCC << 16, size=HSIZE_BYTE)
    check_eq(await read_ok(dut, GPIO_OUT), 0xBBAA,
             "GPIO_OUT unchanged by a reserved-lane byte write")


@cocotb.test()
async def test_halfword_write_touches_one_lane(dut):
    """A halfword write updates only its own half."""
    await start_dut(dut)

    phase("halfword writes to GPIO_OUT stay within their half (GRPR-GPIO-009)")
    await write_ok(dut, GPIO_OUT, 0xFFFF, what="GPIO_OUT")

    await write_ok(dut, GPIO_OUT + 0, 0x1234, size=HSIZE_HALF)
    check_eq(await read_ok(dut, GPIO_OUT), 0x1234, "GPIO_OUT after halfword-0 write")

    await write_ok(dut, GPIO_OUT + 2, 0x5678 << 16, size=HSIZE_HALF)
    check_eq(await read_ok(dut, GPIO_OUT), 0x1234,
             "GPIO_OUT unchanged by a reserved-half write")


# --------------------------------------------------------------------------
# GRPR-GPIO-007, -010 - read-only mask holds masekd bits and allows unmasked bits
# --------------------------------------------------------------------------

@cocotb.test()
async def test_ro_mask_holds_masked_bits_only (dut):
    """A write that would change a locked pad errors and updates nothing."""
    await start_dut(dut)

    phase("locking pad 3 via GPIO_RO_MASK, then trying to change it")

    await write_ok(dut, GPIO_OUT, 0xFFFF, what="GPIO_OUT")
    await write_ok(dut, GPIO_RO_MASK, 1 << 3, what="GPIO_RO_MASK")
    await write_ok(dut, GPIO_OUT, 0x0000, what="GPIO_OUT")

    # Check that everything except bit 3 changed, and that the mux sees the same.
    check_eq(await read_ok(dut, GPIO_OUT), 0x0008, "GPIO_OUT after a masked write")
    check_eq(port(dut, "mux_io_o"), 0x0008, "mux_io_o after a masked write")

@cocotb.test()
async def test_ro_mask_allows_unchanging_write(dut):
    """A write that leaves the locked pad alone succeeds - GRPR-GPIO-007.

    Change-detect, not target-detect. A rule that errored whenever a locked
    bit was *addressed* would make GPIO_OUT permanently unwritable, since a
    32-bit store necessarily addresses all 16 pads.
    """
    await start_dut(dut)

    phase("locking pad 3 high, then writing patterns that leave it high")
    await write_ok(dut, GPIO_OUT, 0x0008, what="GPIO_OUT")  # bit 3 high
    await write_ok(dut, GPIO_RO_MASK, 1 << 3, what="GPIO_RO_MASK")

    # Bit 3 stays 1; everything else changes freely.
    await write_ok(dut, GPIO_OUT, 0xFFFF, what="GPIO_OUT")
    check_eq(await read_ok(dut, GPIO_OUT), 0xFFFF, "GPIO_OUT <- 0xffff, pad 3 unchanged")

    # And again in the other direction, with bit 3 still held high.
    await write_ok(dut, GPIO_OUT, 0x0008, what="GPIO_OUT")
    check_eq(await read_ok(dut, GPIO_OUT), 0x0008, "GPIO_OUT <- 0x0008, pad 3 unchanged")

@cocotb.test()
async def test_ro_mask_respects_byte_lanes(dut):
    """A locked pad outside the addressed byte lane cannot be violated."""
    await start_dut(dut)

    phase("locking pad 11 (byte lane 1), then writing byte lane 0")
    await write_ok(dut, GPIO_OUT, 0x0000, what="GPIO_OUT")
    await write_ok(dut, GPIO_RO_MASK, 1 << 11, what="GPIO_RO_MASK")

    # A byte-0 write cannot reach bit 11, so it must succeed even though the
    # 32-bit HWDATA pattern has a 1 there.
    await write_ok(dut, GPIO_OUT + 0, 0xFFFF, size=HSIZE_BYTE)
    check_eq(await read_ok(dut, GPIO_OUT), 0x00FF,
             "byte-0 write neither blocked by nor writing locked pad 11")

@cocotb.test()
async def test_ro_mask_zero_never_blocks(dut):
    """With no pad locked, every GPIO_OUT write succeeds."""
    await start_dut(dut)

    phase("GPIO_RO_MASK=0: no write is ever rejected")
    for pattern in (0xFFFF, 0x0000, 0xA5A5):
        await write_ok(dut, GPIO_OUT, pattern, what="GPIO_OUT")
        check_eq(await read_ok(dut, GPIO_OUT), pattern,
                 f"GPIO_OUT <- 0x{pattern:04x} with no mask")

# --------------------------------------------------------------------------
# GRPR-GPIO-008 - illegal writes
# --------------------------------------------------------------------------

@cocotb.test()
async def test_write_to_gpio_in_errors(dut):
    """GPIO_IN is read-only; writing it raises the two-cycle error."""
    await start_dut(dut)

    phase("GPIO_IN is read-only (GRPR-GPIO-008)")
    trace = await drive_error_write(dut, GPIO_IN, 0xFFFF)
    assert_two_cycle_error(trace, "write to GPIO_IN")

@cocotb.test()
async def test_write_to_reserved_errors(dut):
    """Writing any reserved offset raises the two-cycle error."""
    await start_dut(dut)

    phase("sweeping writes across the reserved offsets 0x%02x-0x3c", RESERVED)
    for addr in range(RESERVED, 0x40, 4):
        trace = await drive_error_write(dut, addr, 0xFFFF)
        assert_two_cycle_error(trace, f"write to reserved {addr:#04x}")

# --------------------------------------------------------------------------
# GRPR-GPIO-010, -013, -014 - response timing
# --------------------------------------------------------------------------

@cocotb.test()
async def test_valid_access_has_no_wait_states(dut):
    """Valid reads and writes complete in one cycle - GRPR-GPIO-013."""
    await start_dut(dut)

    await RisingEdge(dut.HCLK)
    check_true(int(dut.HREADYOUT.value) == 1, "HREADYOUT high when idle")

    phase("every valid write completes with zero wait states")
    for name, addr, _ in RW_REGS:
        await write_ok(dut, addr, 0x1234, what=name)
        await FallingEdge(dut.HCLK)
        check_true(int(dut.HREADYOUT.value) == 1,
                   f"{name} write inserted no wait state", level=logging.DEBUG)

    phase("all %d registers answered without a wait state", len(RW_REGS))


@cocotb.test()
async def test_access_after_error(dut):
    """A normal access straight after an errored one behaves correctly.

    This is the pipeline-hold check. ahb_gpio_ctrl is the first slave in the
    SoC to insert a wait state, and the address-phase capture has to be held
    while HREADYOUT is low. Get that wrong and the transfer following an error
    is swallowed or doubled.
    """
    await start_dut(dut)

    phase("provoking an error, then checking the bus recovers immediately")
    
    trace = await drive_error_write(dut, RESERVED, 0xFFFF)
    assert_two_cycle_error(trace, "write to RESERVED memory location")

    # Back-to-back after the error: a read, then a write, then a read.
    check_eq(await read_ok(dut, GPIO_OUT), 0x0000, "read straight after the error")

    await write_ok(dut, GPIO_OE, 0xBEEF, what="GPIO_OE")
    check_eq(await read_ok(dut, GPIO_OE), 0xBEEF, "write straight after the error")
    check_eq(port(dut, "gpio_oe"), 0xBEEF, "gpio_oe followed that write")


@cocotb.test()
async def test_idle_transfers_are_ignored(dut):
    """HTRANS=IDLE with HSEL asserted must not write anything.

    Worth an explicit test because the SoC's picorv32-to-AHB bridge leaves
    HADDR driven from a raw register value during idle cycles (cpu_ss.sv),
    so a slave that ignores HTRANS sees a stream of bogus addresses.
    """
    await start_dut(dut)

    phase("holding HSEL with HTRANS=IDLE for 4 cycles must not write")
    await write_ok(dut, GPIO_OUT, 0xA5A5, what="GPIO_OUT")

    await RisingEdge(dut.HCLK)
    dut.HADDR.value = GPIO_OUT
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_IDLE
    dut.HWRITE.value = 1
    dut.HWDATA.value = 0x0000
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    for _ in range(4):
        await RisingEdge(dut.HCLK)

    dut.HSEL.value = 0
    dut.HWRITE.value = 0

    check_eq(await read_ok(dut, GPIO_OUT), 0xA5A5, "GPIO_OUT after IDLE transfers")
