"""Simple directed cocotb testbench for ahb_uart (hw/rtl/uart/ahb_uart.sv).

No pyuvm - just plain cocotb.test()s that drive the AHB3-Lite bus and the
uart_tx/uart_rx pins directly. For a fuller constrained-random/coverage-driven
bench built on pyuvm and reusable VIPs, see hw/dv/ahb_uart/.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.simtime import get_sim_time
from cocotb.triggers import ClockCycles, FallingEdge, First, RisingEdge, Timer

from hw.dv.ahb_uart.uart_clk_math import clk_div_for_baud
from hw.tb.tb_utils.ahb_utils import (
    HSIZE_BYTE,
    HSIZE_HALF,
    HSIZE_WORD,
    HTRANS_IDLE,
    HTRANS_NONSEQ,
    ahb_read,
    ahb_write,
)

ADDR_CTRL = 0x0
ADDR_STATUS = 0x4
ADDR_TXDATA = 0x8
ADDR_RXDATA = 0xC

CTRL_ENABLE = 1 << 0
CTRL_TX_EN = 1 << 1
CTRL_RX_EN = 1 << 2
CTRL_RX_RESYNC_EN = 1 << 3
CTRL_TX_BREAK = 1 << 4
CTRL_FLUSH_TX_FIFO = 1 << 5
CTRL_FLUSH_RX_FIFO = 1 << 6
CTRL_CLK_DIV_SHIFT = 16
CTRL_CLK_DIV_MASK = 0x3FF

STATUS_TX_EMPTY = 1 << 0
STATUS_TX_FULL = 1 << 1
STATUS_RX_EMPTY = 1 << 2
STATUS_RX_FULL = 1 << 3
STATUS_TX_ACTIVE = 1 << 4
STATUS_RX_FRAME_ERROR = 1 << 5
STATUS_RX_BREAK = 1 << 6

CLK_PERIOD_NS = 10
BAUD_RATE = 1_250_000
UART_OVERSAMPLE = 8

# hw/rtl/uart/uart.sv - both FIFOs, GRPR-UART-011
FIFO_DEPTH = 4

# CTRL reset state: RX_RESYNC_EN set, CLK_DIV all ones, everything else clear.
CTRL_RESET_VALUE = CTRL_RX_RESYNC_EN | (CTRL_CLK_DIV_MASK << CTRL_CLK_DIV_SHIFT)


def ctrl_word(clk_div, enable=True, tx_en=True, rx_en=True, rx_resync_en=True,
              tx_break=False, flush_tx=False, flush_rx=False):
    """Assemble a CTRL word. Fields per GRPR-UART-002."""
    value = (clk_div & CTRL_CLK_DIV_MASK) << CTRL_CLK_DIV_SHIFT
    for flag, bit in (
        (enable, CTRL_ENABLE),
        (tx_en, CTRL_TX_EN),
        (rx_en, CTRL_RX_EN),
        (rx_resync_en, CTRL_RX_RESYNC_EN),
        (tx_break, CTRL_TX_BREAK),
        (flush_tx, CTRL_FLUSH_TX_FIFO),
        (flush_rx, CTRL_FLUSH_RX_FIFO),
    ):
        if flag:
            value |= bit
    return value


def bit_period_ns(clk_div):
    """One UART bit is OVERSAMPLE baud ticks of (clk_div + 1) HCLK each."""
    return (clk_div + 1) * UART_OVERSAMPLE * CLK_PERIOD_NS


async def set_ctrl(dut, clk_div, **kwargs):
    """Write CTRL and assert the write was accepted."""
    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_word(clk_div, **kwargs))
    assert hresp == 0, "CTRL write reported HRESP error"


async def read_status(dut):
    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"
    return status


def describe_status(status):
    names = [
        (STATUS_TX_EMPTY, "tx_empty"),
        (STATUS_TX_FULL, "tx_full"),
        (STATUS_RX_EMPTY, "rx_empty"),
        (STATUS_RX_FULL, "rx_full"),
        (STATUS_TX_ACTIVE, "tx_active"),
        (STATUS_RX_FRAME_ERROR, "rx_frame_error"),
        (STATUS_RX_BREAK, "rx_break"),
    ]
    return ",".join(n for b, n in names if status & b) or "(none)"


async def watch_pulse(dut, signal, timeout_ns):
    """Return True if `signal` goes high within timeout_ns.

    rx_irq and rx_error_irq are single-cycle pulses, so they have to be
    watched rather than sampled.
    """
    async def wait_high():
        while True:
            await RisingEdge(dut.HCLK)
            if int(signal.value):
                return True

    async def timeout():
        await Timer(timeout_ns, "ns")
        return False

    watcher = cocotb.start_soon(wait_high())
    timer = cocotb.start_soon(timeout())
    await First(watcher, timer)

    if watcher.done():
        timer.cancel()
        return True

    watcher.cancel()
    return False


async def drive_rx_frame(dut, byte, period_ns, start_bit=0, stop_bit=1):
    """drive_rx_byte with injectable framing errors.

    start_bit/stop_bit override the levels driven for those bit slots, which
    is how the framing-error and break cases are provoked.
    """
    dut.uart_rx.value = start_bit
    await Timer(period_ns, "ns")

    for bit_idx in range(8):
        dut.uart_rx.value = (byte >> bit_idx) & 0x1
        await Timer(period_ns, "ns")

    dut.uart_rx.value = stop_bit
    await Timer(period_ns, "ns")

async def reset_dut(dut):
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
    dut.uart_rx.value = 1

    for _ in range(5):
        await RisingEdge(dut.HCLK)
    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)

async def configure_uart(dut, baud_rate=BAUD_RATE):
    """Enables TX/RX at baud_rate. Returns the resulting bit period in ns."""
    clk_div = clk_div_for_baud(baud_rate, CLK_PERIOD_NS)
    ctrl = (
        CTRL_ENABLE
        | CTRL_TX_EN
        | CTRL_RX_EN
        | CTRL_RX_RESYNC_EN
        | (clk_div << CTRL_CLK_DIV_SHIFT)
    )
    hresp = await ahb_write(dut, ADDR_CTRL, ctrl)
    assert hresp == 0, "CTRL write reported HRESP error"
    return (clk_div + 1) * UART_OVERSAMPLE * CLK_PERIOD_NS

async def capture_tx_byte(dut, bit_period_ns):
    """Waits for a start bit on uart_tx and samples an 8N1, LSB-first frame."""
    await FallingEdge(dut.uart_tx)  # start bit begins
    await Timer(bit_period_ns * 1.5, "ns")  # middle of data bit 0

    value = 0
    for bit_idx in range(8):
        value |= (int(dut.uart_tx.value) & 0x1) << bit_idx
        await Timer(bit_period_ns, "ns")

    assert int(dut.uart_tx.value) == 1, "expected stop bit high"
    return value

async def drive_rx_byte(dut, byte, bit_period_ns):
    """Bit-bangs an 8N1, LSB-first frame onto uart_rx."""
    dut.uart_rx.value = 0  # start bit
    await Timer(bit_period_ns, "ns")

    for bit_idx in range(8):
        dut.uart_rx.value = (byte >> bit_idx) & 0x1
        await Timer(bit_period_ns, "ns")

    dut.uart_rx.value = 1  # stop bit
    await Timer(bit_period_ns, "ns")

@cocotb.test()
async def test_uart_tx_byte(dut):
    """Write a byte to TXDATA and check the serial frame driven onto uart_tx."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    bit_period_ns = await configure_uart(dut)

    tx_byte = 0xA5
    capture_task = cocotb.start_soon(capture_tx_byte(dut, bit_period_ns))
    hresp = await ahb_write(dut, ADDR_TXDATA, tx_byte)
    assert hresp == 0, "TXDATA write reported HRESP error"

    captured = await capture_task
    assert captured == tx_byte, f"expected 0x{tx_byte:02x}, captured 0x{captured:02x}"

    # capture_tx_byte returns mid-stop-bit; give the DUT a full extra bit
    # period so the stop bit finishes and the TX state machine returns to idle.
    await Timer(bit_period_ns, "ns")
    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"
    assert status & STATUS_TX_EMPTY, "expected tx_empty=1 after transmission"
    assert not (status & STATUS_TX_ACTIVE), "expected tx_active=0 after transmission"

@cocotb.test()
async def test_uart_rx_byte(dut):
    """Bit-bang a byte onto uart_rx and read it back through RXDATA."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    bit_period_ns = await configure_uart(dut)

    rx_byte = 0x3C
    await drive_rx_byte(dut, rx_byte, bit_period_ns)

    for _ in range(20):
        status, hresp = await ahb_read(dut, ADDR_STATUS)
        assert hresp == 0, "STATUS read reported HRESP error"
        if not (status & STATUS_RX_EMPTY):
            break
        await ClockCycles(dut.HCLK, 4)
    else:
        assert False, "timed out waiting for rx_empty to clear"

    # This is also the *last* byte in the FIFO, so it is the regression guard
    # for the read-validity phasing: rx_read pops during the address phase, so
    # status_rx_empty is high by the data phase. Deciding the error there
    # would flag this legitimate read.
    data, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 0, "reading the last byte in the RX FIFO must not error"
    assert data == rx_byte, f"expected 0x{rx_byte:02x}, read 0x{data:02x}"

    # And now the FIFO really is empty, so the next read must error.
    _, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 1, "reading an empty RX FIFO should raise an error response"


async def drive_error_access(dut, addr, write=False, data=0, max_cycles=8):
    """Drive one access expected to error, holding the address phase.

    Unlike ahb_utils, this keeps HTRANS/HSEL asserted for as long as the slave
    stalls, the way a real master must. That makes it a check on the DUT too:
    while HREADYOUT is low it must not re-sample the held address phase, or
    the transfer lands twice.

    Returns the per-cycle [(HREADYOUT, HRESP), ...] trace of the data phase.
    """
    await RisingEdge(dut.HCLK)
    dut.HADDR.value = addr
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 1 if write else 0
    dut.HWDATA.value = data
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)  # data phase begins, address phase still held

    trace = []
    for _ in range(max_cycles):
        await FallingEdge(dut.HCLK)
        ready = int(dut.HREADYOUT.value)
        trace.append((ready, int(dut.HRESP.value)))
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
        raise AssertionError(f"slave never became ready; trace={trace}")

    await RisingEdge(dut.HCLK)
    dut.HREADYIN.value = 1
    return trace


def assert_two_cycle_error(trace, what):
    """AHB-Lite ERROR is two cycles: HREADYOUT low then high, HRESP high both.

    A single-cycle HRESP - what ahb_uart did before it grew a proper response
    - fails here.
    """
    assert trace == [(0, 1), (1, 1)], (
        f"{what}: expected [(0,1),(1,1)] for a two-cycle ERROR, got {trace}"
    )


@cocotb.test()
async def test_read_empty_rxdata_errors(dut):
    """Reading an empty RX FIFO raises a proper two-cycle error response."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    await configure_uart(dut)

    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0
    assert status & STATUS_RX_EMPTY, "RX FIFO should be empty after reset"

    trace = await drive_error_access(dut, ADDR_RXDATA)
    assert_two_cycle_error(trace, "read of empty RXDATA")


@cocotb.test()
async def test_write_to_read_only_errors(dut):
    """STATUS and RXDATA are read-only; writing either errors."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    await configure_uart(dut)

    for name, addr in (("STATUS", ADDR_STATUS), ("RXDATA", ADDR_RXDATA)):
        trace = await drive_error_access(dut, addr, write=True, data=0xFFFF_FFFF)
        assert_two_cycle_error(trace, f"write to {name}")


@cocotb.test()
async def test_access_after_error(dut):
    """A normal access straight after an errored one still works.

    The pipeline-hold check. ahb_uart's two-cycle error response inserts a
    wait state, and the address->data capture has to be held while HREADYOUT
    is low - otherwise the transfer following an error is swallowed, or the
    errored one is applied twice.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    bit_period_ns = await configure_uart(dut)

    trace = await drive_error_access(dut, ADDR_RXDATA)
    assert_two_cycle_error(trace, "read of empty RXDATA")

    # A read straight after the error.
    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read straight after an error reported HRESP"
    assert status & STATUS_RX_EMPTY, "RX FIFO should still be empty"

    # Then a write, checked on the wire rather than through STATUS: tx_empty
    # tracks the FIFO, and the transmitter pops it into the shift register
    # within a few cycles, so an unsent byte still reads as empty.
    capture_task = cocotb.start_soon(capture_tx_byte(dut, bit_period_ns))
    hresp = await ahb_write(dut, ADDR_TXDATA, 0x5A)
    assert hresp == 0, "TXDATA write straight after an error reported HRESP"

    captured = await capture_task
    assert captured == 0x5A, f"expected 0x5a on uart_tx, captured 0x{captured:02x}"

    # And exactly one byte: a re-captured address phase would have pushed it
    # twice, leaving the transmitter busy with a second frame.
    await Timer(bit_period_ns * 2, "ns")
    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0
    assert status & STATUS_TX_EMPTY and not (status & STATUS_TX_ACTIVE), (
        "transmitter still busy - the write was applied twice"
    )


# ==========================================================================
# GRPR-UART-001 - register map
# ==========================================================================

@cocotb.test()
async def test_register_decode(dut):
    """V-UART-DIR-001: the four offsets address four distinct registers.

    Also pins down that the block aliases every 16 bytes: word_address is
    HADDR[3:2], so 0x10 is CTRL again and the map repeats through the whole
    4 KiB window. That is normal for a decode this small, but it is worth
    stating rather than discovering.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    await set_ctrl(dut, clk_div)

    ctrl, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0
    assert ctrl == ctrl_word(clk_div), f"CTRL read back 0x{ctrl:08x}"

    # STATUS is a different register - it cannot return the CTRL value.
    status = await read_status(dut)
    assert status != ctrl, "STATUS aliases CTRL"

    # TXDATA is write-only; reads return 0 rather than erroring.
    txdata, hresp = await ahb_read(dut, ADDR_TXDATA)
    assert hresp == 0, "reading write-only TXDATA should not error"
    assert txdata == 0, f"TXDATA read returned 0x{txdata:08x}, expected 0"

    # Documented aliasing: 0x10 decodes to CTRL.
    aliased, hresp = await ahb_read(dut, 0x10)
    assert hresp == 0
    assert aliased == ctrl, (
        "0x10 should alias CTRL - the decode uses HADDR[3:2] only"
    )


@cocotb.test()
async def test_access_widths(dut):
    """V-UART-DIR-002: byte/halfword/word accesses (GRPR-UART-001)."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    await set_ctrl(dut, clk_div)

    # Word reads at each size return the register contents; the DUT does not
    # narrow read data by HSIZE, the master is expected to extract its lane.
    for size, name in ((HSIZE_BYTE, "byte"), (HSIZE_HALF, "half"), (HSIZE_WORD, "word")):
        value, hresp = await ahb_read(dut, ADDR_CTRL, size=size)
        assert hresp == 0, f"{name} read of CTRL errored"
        assert value == ctrl_word(clk_div), f"{name} read gave 0x{value:08x}"

    # TXDATA takes a byte write - the payload is 8 bits, and the RTL requires
    # only the lanes covering it (byte_select_r[0]).
    bp = bit_period_ns(clk_div)
    capture = cocotb.start_soon(capture_tx_byte(dut, bp))
    hresp = await ahb_write(dut, ADDR_TXDATA, 0x7E, size=HSIZE_BYTE)
    assert hresp == 0, "byte write to TXDATA errored"
    assert await capture == 0x7E, "byte write to TXDATA did not transmit"


@cocotb.test(expect_fail=True)
async def test_ctrl_byte_write_lane_isolation(dut):
    """V-UART-DIR-002a: a byte write to CTRL should touch only byte 0.

    EXPECTED TO FAIL - known RTL limitation, kept as executable documentation.

    GRPR-UART-001 promises byte/halfword/word access "via HSIZE + byte-select",
    but ahb_uart.sv gates the whole CTRL write on byte_select_r[0] and then
    assigns *every* field from HWDATA, including CLK_DIV[25:16]. So a byte
    write to CTRL+0 silently clobbers the baud divider with whatever the
    master happened to drive on the upper lanes.

    Latent today because firmware always writes CTRL as a word
    (sw/src/uart/uart.c). If the RTL is fixed to mask per lane, this test
    starts passing and cocotb will flag it as an unexpected pass.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    await set_ctrl(dut, clk_div)

    # Byte write to lane 0 only, with the upper lanes zero.
    hresp = await ahb_write(dut, ADDR_CTRL, CTRL_ENABLE, size=HSIZE_BYTE)
    assert hresp == 0

    ctrl, _ = await ahb_read(dut, ADDR_CTRL)
    got_div = (ctrl >> CTRL_CLK_DIV_SHIFT) & CTRL_CLK_DIV_MASK
    assert got_div == clk_div, (
        f"a byte write to CTRL byte 0 clobbered CLK_DIV: {clk_div} -> {got_div}"
    )


@cocotb.test()
async def test_reserved_bits_read_zero(dut):
    """V-UART-DIR-003: unimplemented bits read 0 (GRPR-UART-001)."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    # Write all ones; only the implemented fields may come back.
    hresp = await ahb_write(dut, ADDR_CTRL, 0xFFFF_FFFF)
    assert hresp == 0

    ctrl, _ = await ahb_read(dut, ADDR_CTRL)
    ctrl_implemented = (
        CTRL_ENABLE | CTRL_TX_EN | CTRL_RX_EN | CTRL_RX_RESYNC_EN | CTRL_TX_BREAK
        | (CTRL_CLK_DIV_MASK << CTRL_CLK_DIV_SHIFT)
    )
    assert ctrl & ~ctrl_implemented == 0, (
        f"CTRL reserved bits set: 0x{ctrl & ~ctrl_implemented:08x}. Note the "
        f"flush bits 5/6 are write-one-shot and must read 0."
    )

    status = await read_status(dut)
    status_implemented = 0x7F
    assert status & ~status_implemented == 0, (
        f"STATUS bits above 6 set: 0x{status & ~status_implemented:08x}"
    )


# ==========================================================================
# GRPR-UART-002 - CTRL fields
# ==========================================================================

@cocotb.test()
async def test_ctrl_reset_values(dut):
    """V-UART-DIR-004: RX_RESYNC_EN=1, CLK_DIV=all ones, rest 0."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    ctrl, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0
    assert ctrl == CTRL_RESET_VALUE, (
        f"CTRL reset value is 0x{ctrl:08x}, expected 0x{CTRL_RESET_VALUE:08x}"
    )


@cocotb.test()
async def test_ctrl_bit_readback(dut):
    """V-UART-DIR-005: every CTRL field is independently writable."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    fields = ("enable", "tx_en", "rx_en", "rx_resync_en", "tx_break")

    for field in fields:
        # Only this field set, everything else clear.
        kwargs = {f: (f == field) for f in fields}
        expected = ctrl_word(0, **kwargs)
        hresp = await ahb_write(dut, ADDR_CTRL, expected)
        assert hresp == 0

        ctrl, _ = await ahb_read(dut, ADDR_CTRL)
        assert ctrl == expected, (
            f"CTRL with only {field} set read back 0x{ctrl:08x}, "
            f"expected 0x{expected:08x}"
        )

    for clk_div in (0, 1, 0x155, CTRL_CLK_DIV_MASK):
        await set_ctrl(dut, clk_div, enable=False, tx_en=False, rx_en=False,
                       rx_resync_en=False)
        ctrl, _ = await ahb_read(dut, ADDR_CTRL)
        got = (ctrl >> CTRL_CLK_DIV_SHIFT) & CTRL_CLK_DIV_MASK
        assert got == clk_div, f"CLK_DIV wrote {clk_div}, read {got}"


@cocotb.test()
async def test_ctrl_flush_self_clear(dut):
    """V-UART-DIR-006: the flush bits are write-one-shot and read back 0."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    await set_ctrl(dut, clk_div, flush_tx=True, flush_rx=True)

    ctrl, _ = await ahb_read(dut, ADDR_CTRL)
    assert ctrl & (CTRL_FLUSH_TX_FIFO | CTRL_FLUSH_RX_FIFO) == 0, (
        f"flush bits still set in CTRL readback 0x{ctrl:08x}"
    )
    # The rest of the write must have landed normally.
    assert ctrl == ctrl_word(clk_div), f"CTRL is 0x{ctrl:08x} after a flush write"


@cocotb.test()
async def test_ctrl_flush_empties_fifo(dut):
    """V-UART-DIR-007: flushing actually discards queued data."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)

    # TX: freeze the transmitter with tx_en=0 so the FIFO cannot drain, queue
    # two bytes, then flush.
    await set_ctrl(dut, clk_div, tx_en=False)
    for byte in (0x11, 0x22):
        assert await ahb_write(dut, ADDR_TXDATA, byte) == 0

    status = await read_status(dut)
    assert not (status & STATUS_TX_EMPTY), "TX FIFO should hold the queued bytes"

    await set_ctrl(dut, clk_div, tx_en=False, flush_tx=True)
    status = await read_status(dut)
    assert status & STATUS_TX_EMPTY, (
        f"FLUSH_TX_FIFO did not empty the FIFO ({describe_status(status)})"
    )

    # RX: receive two bytes, then flush.
    await set_ctrl(dut, clk_div, tx_en=False)
    for byte in (0x33, 0x44):
        await drive_rx_frame(dut, byte, bp)

    status = await read_status(dut)
    assert not (status & STATUS_RX_EMPTY), "RX FIFO should hold the received bytes"

    await set_ctrl(dut, clk_div, tx_en=False, flush_rx=True)
    status = await read_status(dut)
    assert status & STATUS_RX_EMPTY, (
        f"FLUSH_RX_FIFO did not empty the FIFO ({describe_status(status)})"
    )

    # And nothing stale reappears - a read now must error.
    _, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 1, "RXDATA read after a flush should error, the FIFO is empty"

# ==========================================================================
# GRPR-UART-003 - STATUS fields
# ==========================================================================

@cocotb.test()
async def test_status_bits_toggle(dut):
    """V-UART-DIR-008: every FIFO status bit seen both set and clear."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)

    # Freeze the transmitter so the TX FIFO fills instead of draining.
    await set_ctrl(dut, clk_div, tx_en=False)

    status = await read_status(dut)
    assert status & STATUS_TX_EMPTY, "tx_empty should be set when idle"
    assert not (status & STATUS_TX_FULL), "tx_full should be clear when idle"
    assert status & STATUS_RX_EMPTY, "rx_empty should be set when idle"
    assert not (status & STATUS_RX_FULL), "rx_full should be clear when idle"

    for byte in range(FIFO_DEPTH):
        assert await ahb_write(dut, ADDR_TXDATA, 0xC0 | byte) == 0

    status = await read_status(dut)
    assert not (status & STATUS_TX_EMPTY), "tx_empty still set with 4 bytes queued"
    assert status & STATUS_TX_FULL, f"tx_full not set ({describe_status(status)})"

    await set_ctrl(dut, clk_div, tx_en=False, flush_tx=True)
    status = await read_status(dut)
    assert status & STATUS_TX_EMPTY and not (status & STATUS_TX_FULL)

    # RX side.
    for byte in range(FIFO_DEPTH):
        await drive_rx_frame(dut, 0xD0 | byte, bp)

    status = await read_status(dut)
    assert not (status & STATUS_RX_EMPTY), "rx_empty still set with 4 bytes received"
    assert status & STATUS_RX_FULL, f"rx_full not set ({describe_status(status)})"

    for _ in range(FIFO_DEPTH):
        _, hresp = await ahb_read(dut, ADDR_RXDATA)
        assert hresp == 0

    status = await read_status(dut)
    assert status & STATUS_RX_EMPTY and not (status & STATUS_RX_FULL)


@cocotb.test()
async def test_status_tx_active(dut):
    """V-UART-DIR-009: TX_ACTIVE tracks the frame."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    bp = await configure_uart(dut)

    assert not (await read_status(dut) & STATUS_TX_ACTIVE), "tx_active set while idle"

    assert await ahb_write(dut, ADDR_TXDATA, 0x5A) == 0

    # Sample mid-frame, comfortably inside the 10 bit periods.
    await Timer(bp * 4, "ns")
    status = await read_status(dut)
    assert status & STATUS_TX_ACTIVE, (
        f"tx_active clear mid-frame ({describe_status(status)})"
    )

    # And clear again once the frame and its stop bit are done.
    await Timer(bp * 8, "ns")
    status = await read_status(dut)
    assert not (status & STATUS_TX_ACTIVE), (
        f"tx_active still set after the frame ({describe_status(status)})"
    )


@cocotb.test()
async def test_status_sticky_read_clear(dut):
    """V-UART-DIR-010: RX_FRAME_ERROR and RX_BREAK are sticky, both read-clear.

    Settles the question the design doc raised as an open item: the RTL clears
    *both* sticky bits on a STATUS read, not just RX_FRAME_ERROR.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    # Frame error: a stop bit driven low. Data is 0xFF so break_detect clears
    # and this is a plain framing error rather than a break.
    await drive_rx_frame(dut, 0xFF, bp, stop_bit=0)
    dut.uart_rx.value = 1
    await Timer(bp * 2, "ns")

    status = await read_status(dut)
    assert status & STATUS_RX_FRAME_ERROR, (
        f"rx_frame_error not sticky ({describe_status(status)})"
    )

    status = await read_status(dut)
    assert not (status & STATUS_RX_FRAME_ERROR), (
        "rx_frame_error did not clear on a STATUS read"
    )

    # Break: the line held low for a whole frame.
    dut.uart_rx.value = 0
    await Timer(bp * 12, "ns")
    dut.uart_rx.value = 1
    await Timer(bp * 2, "ns")

    status = await read_status(dut)
    assert status & STATUS_RX_BREAK, (
        f"rx_break not sticky ({describe_status(status)})"
    )

    status = await read_status(dut)
    assert not (status & STATUS_RX_BREAK), (
        "rx_break did not clear on a STATUS read - the design doc's open item "
        "claimed this; the RTL does clear it"
    )


# ==========================================================================
# GRPR-UART-004 / -005 / -011 - FIFOs
# ==========================================================================

@cocotb.test()
async def test_tx_fifo_full_write_errors(dut):
    """V-UART-DIR-012: a write to a full TX FIFO errors and loses nothing."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)

    await set_ctrl(dut, clk_div, tx_en=False)

    queued = [0x10, 0x20, 0x30, 0x40]
    for byte in queued:
        assert await ahb_write(dut, ADDR_TXDATA, byte) == 0

    assert await read_status(dut) & STATUS_TX_FULL, "FIFO should be full"

    trace = await drive_error_access(dut, ADDR_TXDATA, write=True, data=0xEE)
    assert_two_cycle_error(trace, "write to a full TXDATA")

    # The rejected byte must not have displaced anything: release the
    # transmitter and confirm the original four come out in order.
    await set_ctrl(dut, clk_div)
    for expected in queued:
        got = await capture_tx_byte(dut, bp)
        assert got == expected, f"expected 0x{expected:02x}, captured 0x{got:02x}"


@cocotb.test()
async def test_tx_byte_order(dut):
    """V-UART-DIR-013: a burst leaves the FIFO in the order written."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)

    await set_ctrl(dut, clk_div, tx_en=False)
    payload = [0x01, 0x02, 0x04, 0x08]
    for byte in payload:
        assert await ahb_write(dut, ADDR_TXDATA, byte) == 0

    await set_ctrl(dut, clk_div)
    for expected in payload:
        got = await capture_tx_byte(dut, bp)
        assert got == expected, f"expected 0x{expected:02x}, captured 0x{got:02x}"


@cocotb.test()
async def test_errored_read_does_not_pop(dut):
    """V-UART-DIR-016: an errored RXDATA read leaves the FIFO undisturbed."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    # Read while empty - errors, and must not move the read pointer.
    _, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 1, "read of an empty RX FIFO should error"

    # A byte arriving afterwards must still be readable, and be the right one.
    await drive_rx_frame(dut, 0x9B, bp)
    data, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 0, "read after the errored read should succeed"
    assert data == 0x9B, (
        f"read 0x{data:02x} - the errored read disturbed the FIFO pointers"
    )


@cocotb.test()
async def test_fifo_depth_boundaries(dut):
    """V-UART-DIR-026: flags flip at exactly the 4th entry (GRPR-UART-011)."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div, tx_en=False)

    for n in range(1, FIFO_DEPTH + 1):
        assert await ahb_write(dut, ADDR_TXDATA, 0xA0 | n) == 0
        status = await read_status(dut)
        assert not (status & STATUS_TX_EMPTY), f"tx_empty set with {n} queued"
        assert bool(status & STATUS_TX_FULL) == (n == FIFO_DEPTH), (
            f"tx_full is {bool(status & STATUS_TX_FULL)} with {n}/{FIFO_DEPTH} queued"
        )

    await set_ctrl(dut, clk_div, tx_en=False, flush_tx=True)

    for n in range(1, FIFO_DEPTH + 1):
        await drive_rx_frame(dut, 0xB0 | n, bp)
        status = await read_status(dut)
        assert not (status & STATUS_RX_EMPTY), f"rx_empty set with {n} received"
        assert bool(status & STATUS_RX_FULL) == (n == FIFO_DEPTH), (
            f"rx_full is {bool(status & STATUS_RX_FULL)} with {n}/{FIFO_DEPTH} received"
        )

    for n in range(FIFO_DEPTH, 0, -1):
        data, hresp = await ahb_read(dut, ADDR_RXDATA)
        assert hresp == 0
        assert data == (0xB0 | (FIFO_DEPTH - n + 1)), f"out of order at {n} left"
        status = await read_status(dut)
        assert not (status & STATUS_RX_FULL), "rx_full still set after a pop"
        assert bool(status & STATUS_RX_EMPTY) == (n == 1), (
            f"rx_empty is {bool(status & STATUS_RX_EMPTY)} with {n - 1} left"
        )


@cocotb.test()
async def test_full_duplex_traffic(dut):
    """V-UART-DIR-027: simultaneous TX and RX do not disturb each other."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    tx_payload = [0x3A, 0xC5]
    rx_payload = [0x71, 0x8E]

    async def receive_side():
        for byte in rx_payload:
            await drive_rx_frame(dut, byte, bp)

    async def transmit_side():
        return [await capture_tx_byte(dut, bp) for _ in tx_payload]

    capture = cocotb.start_soon(transmit_side())
    driver = cocotb.start_soon(receive_side())

    for byte in tx_payload:
        assert await ahb_write(dut, ADDR_TXDATA, byte) == 0

    assert await capture == tx_payload, "transmitted bytes corrupted by RX traffic"
    await driver

    got = []
    for _ in rx_payload:
        data, hresp = await ahb_read(dut, ADDR_RXDATA)
        assert hresp == 0
        got.append(data)
    assert got == rx_payload, f"received {got}, expected {rx_payload}"

# ==========================================================================
# GRPR-UART-007 - framing errors and break detection
# ==========================================================================

@cocotb.test()
async def test_rx_bad_start_bit(dut):
    """V-UART-DIR-018: a start bit that is high at the mid-bit sample errors.

    uart_rx.sv enters ST_START_BIT on the 1->0 edge and checks the line again
    at sample 4 of 8. A low pulse shorter than half a bit therefore looks like
    a false start.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    dut.uart_rx.value = 0
    await Timer(bp / 4, "ns")      # too short to survive the mid-bit sample
    dut.uart_rx.value = 1
    await Timer(bp * 3, "ns")

    status = await read_status(dut)
    assert status & STATUS_RX_FRAME_ERROR, (
        f"no frame error for a short start bit ({describe_status(status)})"
    )
    assert status & STATUS_RX_EMPTY, "a false start should not queue a byte"


@cocotb.test()
async def test_rx_bad_stop_bit(dut):
    """V-UART-DIR-019: a stop bit driven low errors, without a break."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    # 0xFF data keeps break_detect clear, so this is a framing error only.
    await drive_rx_frame(dut, 0xFF, bp, stop_bit=0)
    dut.uart_rx.value = 1
    await Timer(bp * 2, "ns")

    status = await read_status(dut)
    assert status & STATUS_RX_FRAME_ERROR, (
        f"no frame error for a low stop bit ({describe_status(status)})"
    )
    assert not (status & STATUS_RX_BREAK), (
        "a framing error with high data bits must not be reported as a break"
    )
    assert status & STATUS_RX_EMPTY, "a bad frame should not be queued"


@cocotb.test()
async def test_rx_break_detect(dut):
    """V-UART-DIR-020: the line low through a whole frame is a break.

    break_detect is armed at the start bit and AND-accumulated with the
    inverted line every baud tick, so it survives only if the line never went
    high - i.e. an all-zero frame with a low stop bit.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    dut.uart_rx.value = 0
    await Timer(bp * 12, "ns")     # start + 8 data + stop, all low
    dut.uart_rx.value = 1
    await Timer(bp * 2, "ns")

    status = await read_status(dut)
    assert status & STATUS_RX_BREAK, (
        f"no break detected ({describe_status(status)})"
    )
    assert status & STATUS_RX_EMPTY, "a break should not queue a byte"


@cocotb.test()
async def test_rx_error_irq_pulses(dut):
    """V-UART-DIR-021: rx_irq on a good byte, rx_error_irq on a bad frame."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)
    await set_ctrl(dut, clk_div)

    # Good frame -> rx_irq, no rx_error_irq.
    rx_watch = cocotb.start_soon(watch_pulse(dut, dut.rx_irq, bp * 14))
    err_watch = cocotb.start_soon(watch_pulse(dut, dut.rx_error_irq, bp * 14))
    await drive_rx_frame(dut, 0x5C, bp)
    await Timer(bp * 2, "ns")

    assert await rx_watch, "rx_irq did not pulse for a good byte"
    assert not await err_watch, "rx_error_irq pulsed for a good byte"

    # Bad frame -> rx_error_irq.
    err_watch = cocotb.start_soon(watch_pulse(dut, dut.rx_error_irq, bp * 14))
    await drive_rx_frame(dut, 0xFF, bp, stop_bit=0)
    dut.uart_rx.value = 1
    await Timer(bp * 2, "ns")

    assert await err_watch, "rx_error_irq did not pulse for a framing error"


# ==========================================================================
# GRPR-UART-008 - TX_BREAK
# ==========================================================================

@cocotb.test()
async def test_tx_break_from_idle(dut):
    """V-UART-DIR-022: TX_BREAK holds uart_tx low, and releases it."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)

    await set_ctrl(dut, clk_div)
    await Timer(bp, "ns")
    assert int(dut.uart_tx.value) == 1, "uart_tx should idle high"

    await set_ctrl(dut, clk_div, tx_break=True)
    await Timer(bp * 2, "ns")

    # Held low continuously, not just for one bit.
    for _ in range(4):
        await Timer(bp, "ns")
        assert int(dut.uart_tx.value) == 0, "uart_tx not held low during TX_BREAK"

    await set_ctrl(dut, clk_div)
    await Timer(bp * 2, "ns")
    assert int(dut.uart_tx.value) == 1, "uart_tx did not return high after TX_BREAK"


@cocotb.test()
async def test_tx_break_overrides_fifo(dut):
    """V-UART-DIR-023: TX_BREAK suppresses FIFO-driven transmission.

    Note on the RTL's timing: uart_tx.sv only samples tx_break in ST_IDLE and
    ST_STOP_BIT, so a break asserted mid-frame lets the current frame finish
    and takes effect at the frame boundary. It is not a mid-character abort.
    """
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    clk_div = clk_div_for_baud(BAUD_RATE, CLK_PERIOD_NS)
    bp = bit_period_ns(clk_div)

    # Break asserted, then a byte queued: it must not go out.
    await set_ctrl(dut, clk_div, tx_break=True)
    await Timer(bp * 2, "ns")
    assert await ahb_write(dut, ADDR_TXDATA, 0x96) == 0

    for _ in range(12):
        await Timer(bp, "ns")
        assert int(dut.uart_tx.value) == 0, (
            "uart_tx left the break state - a queued byte was transmitted"
        )

    assert not (await read_status(dut) & STATUS_TX_EMPTY), (
        "the queued byte should still be in the FIFO"
    )

    # Clearing the break lets it out.
    capture = cocotb.start_soon(capture_tx_byte(dut, bp))
    await set_ctrl(dut, clk_div)
    got = await capture
    assert got == 0x96, f"expected 0x96 after clearing TX_BREAK, captured 0x{got:02x}"


# ==========================================================================
# GRPR-UART-010 - baud divider
# ==========================================================================

# clk_div=1023 is the field maximum; one frame at that setting is ~0.8 ms of
# simulated time, which is why the sweep measures the start bit rather than
# waiting out whole frames.
CLK_DIV_CORNERS = (0, 9, 63, CTRL_CLK_DIV_MASK)


@cocotb.test()
async def test_baud_sweep_tx(dut):
    """V-UART-DIR-024: the TX bit period matches HCLK / (8 x (CLK_DIV+1))."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    for clk_div in CLK_DIV_CORNERS:
        await reset_dut(dut)
        await set_ctrl(dut, clk_div)

        expected = bit_period_ns(clk_div)

        # 0xFF has every data bit high, so the only low interval is the start
        # bit - exactly one bit period, measurable from two edges.
        assert await ahb_write(dut, ADDR_TXDATA, 0xFF) == 0

        await FallingEdge(dut.uart_tx)
        start = get_sim_time("ns")
        await RisingEdge(dut.uart_tx)
        measured = get_sim_time("ns") - start

        # One HCLK of tolerance for the sampling grid.
        assert abs(measured - expected) <= CLK_PERIOD_NS, (
            f"clk_div={clk_div}: start bit measured {measured} ns, "
            f"expected {expected} ns"
        )

        # Let the frame finish before reconfiguring.
        await Timer(expected * 10, "ns")


@cocotb.test()
async def test_baud_sweep_rx(dut):
    """V-UART-DIR-025: reception works at the same divider corners."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    for clk_div in CLK_DIV_CORNERS:
        await reset_dut(dut)
        await set_ctrl(dut, clk_div)

        bp = bit_period_ns(clk_div)
        payload = 0x6D

        await drive_rx_frame(dut, payload, bp)
        await Timer(bp, "ns")

        data, hresp = await ahb_read(dut, ADDR_RXDATA)
        assert hresp == 0, f"clk_div={clk_div}: RXDATA read errored"
        assert data == payload, (
            f"clk_div={clk_div}: read 0x{data:02x}, expected 0x{payload:02x}"
        )
