"""Simple directed cocotb testbench for ahb_spi_s
"""

import functools
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import (
    FallingEdge,
    RisingEdge,
    SimTimeoutError,
    with_timeout,
)

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_BYTE,
    HSIZE_HALF,
    HSIZE_WORD,
    HTRANS_IDLE,
    ahb_read,
    ahb_write,
)
from hw.tb.spi_s.spi_s_utils import (
    ADDR_IRQ_EN,
    ADDR_IRQ_STATUS,
    CTRL_CPHA,
    CTRL_CPOL,
    FIFO_DEPTH,
    IRQ_OVERFLOW,
    IRQ_OVERRUN,
    IRQ_RX_VALID,
    IRQ_UNDERFLOW,
    IRQ_UNDERRUN,
    OP_FAST_READ,
    OP_SPI_READ,
    OP_SPI_WRITE,
    STATUS_RX_EMPTY,
    STATUS_RX_FULL,
    STATUS_TX_EMPTY,
    STATUS_TX_FULL,
    rx_level,
    spi_frame,
    spi_read_frame,
    spi_write_frame,
)

log = logging.getLogger("cocotb.spi_s")

ADDR_CTRL = 0x0
ADDR_STATUS = 0x4
ADDR_TXDATA = 0x8
ADDR_RXDATA = 0xC

CTRL_ENABLE = 1 << 0
CTRL_SOFT_RESET = 1 << 1

STATUS_BUSY = 1 << 0
STATUS_RX_VALID = 1 << 1
STATUS_TX_READY = 1 << 2

CLK_PERIOD_NS = 10


async def settle(dut):
    """Advance to a clock edge before letting the test end.

    A test that returns immediately after a value read leaves the simulator
    mid-cycle, and Verilator's VPI teardown then walks a partially updated
    model - which comes back as a bare exit -11 (SIGSEGV) after the regression
    summary has already printed every test as passing. Ending on a clock edge
    lets the cycle complete first. Same helper as spi_m_test().
    """
    try:
        await with_timeout(RisingEdge(dut.HCLK), 10 * CLK_PERIOD_NS, "ns")
    except SimTimeoutError:
        log.debug("settle: no clock edge - ending without one")
    except Exception as exc:                      # noqa: BLE001
        log.debug("settle: %s", exc)


def spi_s_test(**kwargs):
    """cocotb.test that always ends its test on a clock edge. See settle()."""
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


async def init_test(dut):
    """Start the clock and release reset. Returns with the DUT idle."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)


async def enable(dut, extra=0):
    """Enable the block, plus any extra CTRL bits."""
    hresp = await ahb_write(dut, ADDR_CTRL, CTRL_ENABLE | extra)
    assert hresp == 0, "CTRL write reported HRESP error"


async def count_waits_task(dut, counter):
    """Count HREADYOUT-low cycles. ahb_read/ahb_write compute the wait count
    but do not return it, so a concurrent sampler is the only way to see it."""
    while True:
        await FallingEdge(dut.HCLK)
        if int(dut.HREADYOUT.value) == 0:
            counter[0] += 1

# keeping this from UART
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

    dut.spi_s_ss.value = 1
    dut.spi_s_sck.value = 0
    dut.spi_s_mosi.value = 0

    # Debug port: no unit connected by default, so requests are never accepted
    # and the FIFO path is what runs.
    dut.dbg_req_ready.value = 0
    dut.dbg_rsp_valid.value = 0
    dut.dbg_rsp_rdata.value = 0
    dut.dbg_rsp_err.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)

    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)


async def spi_send_byte(dut, data):
    """Send one byte over the SPI interface (MSB first)."""

    dut.spi_s_ss.value = 0

    for i in range(7, -1, -1):
        dut.spi_s_mosi.value = (data >> i) & 1

        await RisingEdge(dut.HCLK)

        dut.spi_s_sck.value = 1
        await RisingEdge(dut.HCLK)

        dut.spi_s_sck.value = 0
        await RisingEdge(dut.HCLK)

    dut.spi_s_ss.value = 1

# TEST 1
@spi_s_test()
async def test_ctrl_rw(dut):
    """Test read/write access to the CTRL register."""

    await init_test(dut)

    # test ENABLE bit
    ctrl_value = CTRL_ENABLE

    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_value)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"

    assert value == ctrl_value, \
        f"Expected 0x{ctrl_value:08X}, got 0x{value:08X}"

    # SOFT_RESET is a strobe, not a mode: it self-clears in the cycle it acts
    # (SPIS-SPEC-006), so it never reads back set. ENABLE survives it because
    # the reset only touches transfer state.
    hresp = await ahb_write(dut, ADDR_CTRL, CTRL_ENABLE | CTRL_SOFT_RESET)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"

    assert value == CTRL_ENABLE, \
        f"Expected 0x{CTRL_ENABLE:08X} (SOFT_RESET self-cleared), got 0x{value:08X}"

    # CPOL/CPHA are now implemented and must read back (SPIS-SPEC-005).
    ctrl_value = CTRL_ENABLE | CTRL_CPOL | CTRL_CPHA
    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_value)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"
    assert value == ctrl_value, \
        f"Expected 0x{ctrl_value:08X}, got 0x{value:08X}"

# TEST 2
@spi_s_test()
async def test_status_ro(dut):
    """Test that STATUS is read-only."""

    await init_test(dut)

    # read STATUS after reset
    value, hresp = await ahb_read(dut, ADDR_STATUS)

    assert hresp == 0, \
        "STATUS read reported HRESP error"

    # Reset value is TX_READY | RX_EMPTY | TX_EMPTY: both FIFOs start empty,
    # and TX_READY now reads !TX_FULL rather than a single-byte handshake.
    expected = STATUS_TX_READY | STATUS_RX_EMPTY | STATUS_TX_EMPTY
    assert value == expected, \
        f"Expected STATUS = 0x{expected:08X}, got 0x{value:08X}"

    # try to write STATUS
    hresp = await ahb_write(
        dut,
        ADDR_STATUS,
        0xFFFFFFFF
    )

    assert hresp == 1, \
        "Expected HRESP error when writing STATUS"

    # STATUS should be the same
    value, hresp = await ahb_read(dut, ADDR_STATUS)

    assert hresp == 0, \
        "STATUS read reported HRESP error"

    assert value == expected, \
        f"STATUS changed after write: 0x{value:08X}"

# TEST 3
@spi_s_test()
async def test_txdata_wo(dut):
    """Test that TXDATA is write-only."""

    await init_test(dut)

    # write a byte to TXDATA
    hresp = await ahb_write(
        dut,
        ADDR_TXDATA,
        0xA5
    )
    assert hresp == 0, \
        "TXDATA write reported HRESP error"

    # read TXDATA back
    value, hresp = await ahb_read(
        dut,
        ADDR_TXDATA
    )

    assert hresp == 0, \
        "TXDATA read reported HRESP error"

    # TXDATA is write only (reads return zero for now)
    assert value == 0, \
        f"Expected TXDATA read to return 0x00000000, got 0x{value:08X}"

# TEST 4
@spi_s_test()
async def test_rxdata_ro(dut):
    """Test that RXDATA is read-only."""

    await init_test(dut)

    # reading RXDATA should be allowed
    value, hresp = await ahb_read(
        dut,
        ADDR_RXDATA
    )

    assert hresp == 0, \
        "RXDATA read reported HRESP error"

    # try to write RXDATA (should give an error)
    hresp = await ahb_write(
        dut,
        ADDR_RXDATA,
        0x55
    )
    assert hresp == 1, \
        "Expected HRESP error when writing RXDATA"

    # reading RXDATA should still work
    value, hresp = await ahb_read(
        dut,
        ADDR_RXDATA
    )

    assert hresp == 0, \
        "RXDATA read reported HRESP error"


# TEST 5
@spi_s_test()
async def test_spi_receive_byte(dut):
    """A payload byte reaches RXDATA through a SPI_WRITE frame.

    The opcode is no longer treated as receive data (GRPR-SPIS-025 covers
    payload bytes only), so this drives a full frame - opcode, 24-bit address,
    then payload - rather than a lone byte. That also makes it the first test
    to reach FSM_WRITE_DATA at all.
    """
    await init_test(dut)
    await enable(dut)

    TEST_BYTE = 0xA5
    await spi_write_frame(dut, [TEST_BYTE], address=0x123456)

    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"
    assert status & STATUS_RX_VALID, "STATUS_RX_VALID was not set"

    value, hresp = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
    assert hresp == 0, "RXDATA read reported HRESP error"
    assert value == TEST_BYTE, \
        f"Expected 0x{TEST_BYTE:02X}, got 0x{value:02X}"


# TEST 6
@spi_s_test()
async def test_rx_valid_clears_after_read(dut):
    """RX_VALID tracks FIFO occupancy: set on arrival, clear once drained."""
    await init_test(dut)
    await enable(dut)

    await spi_write_frame(dut, [0xA5], address=0x000010)

    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"
    assert status & STATUS_RX_VALID, \
        "RX_VALID was not set after receiving a byte"

    data, hresp = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
    assert hresp == 0, "RXDATA read reported HRESP error"
    assert data == 0xA5, f"Expected RXDATA = 0xA5, got 0x{data:02X}"

    status, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"
    assert (status & STATUS_RX_VALID) == 0, \
        "RX_VALID did not clear once the FIFO was drained"


# TEST 7
@spi_s_test()
async def test_txdata_multiple_writes(dut):
    """Test that multiple TXDATA writes are accepted."""

    await init_test(dut)

    # enable the SPI
    hresp = await ahb_write(
        dut,
        ADDR_CTRL,
        CTRL_ENABLE
    )

    assert hresp == 0, \
        "CTRL write reported HRESP error"

    # write many different bytes
    test_values = [
        0x00,
        0x55,
        0xA5,
        0xFF,
    ]
    for value in test_values:
        hresp = await ahb_write(
            dut,
            ADDR_TXDATA,
            value
        )
        assert hresp == 0, \
            f"TXDATA write failed for 0x{value:02X}"
    # (actual MISO transmission is not checked yet. will test once SPI TX logic is finished)


# TEST 8
@spi_s_test()
async def test_spi_transmit_byte(dut):
    """A byte queued in TXDATA is transmitted on MISO during a read frame.

    A TXDATA write used to load the shift register directly, so bit-banging
    SCK straight afterwards returned the byte. With a TX FIFO the byte waits
    until a SPI_READ frame reaches FSM_READ_DATA, which is what a real host
    would drive - so this now sends opcode + address before clocking data.
    """
    await init_test(dut)
    await enable(dut)

    test_byte = 0xA5
    hresp = await ahb_write(dut, ADDR_TXDATA, test_byte, size=HSIZE_BYTE)
    assert hresp == 0, "TXDATA write reported HRESP error"

    got = await spi_read_frame(dut, 1, address=0x000000)

    assert got[0] == test_byte, \
        f"Expected MISO = 0x{test_byte:02X}, got 0x{got[0]:02X}"


# TEST 8b
@spi_s_test()
async def test_fast_read_consumes_wait_byte(dut):
    """FAST_READ inserts the APS6404L's wait cycles before its data phase.

    0x0B differs from 0x03 (READ) by exactly the 8 wait cycles the datasheet's
    section 8.5 table gives it - one byte on this 8-bit-framed wire - between
    the address phase and the first data bit (GRPR-SPIS-003/-005;
    hw/tb/models/aps6404l.py models the same 8 as FAST_READ_WAIT).

    An earlier decode treated FAST_READ as a bare synonym for READ and
    consumed no wait byte at all. That is worse than refusing the opcode: a
    host already speaking the PSRAM protocol - the entire reason this command
    set is APS6404L-compatible - clocks its wait byte, gets a data byte for
    it, and reads a whole response shifted one byte late without any error to
    notice.
    """
    await init_test(dut)
    await enable(dut)

    payload = [0xDE, 0xAD]
    for byte in payload:
        assert await ahb_write(dut, ADDR_TXDATA, byte, size=HSIZE_BYTE) == 0

    got = await spi_read_frame(dut, len(payload), address=0x000000,
                               opcode=OP_FAST_READ)

    assert got == payload, (
        f"FAST_READ returned {[hex(b) for b in got]}, expected "
        f"{[hex(b) for b in payload]} - the wait byte is not being consumed"
    )


# TEST 8c
@spi_s_test()
async def test_fast_read_and_read_differ_by_one_byte(dut):
    """The wait byte is real: framing FAST_READ without it shifts the data.

    Deliberately frames FAST_READ with no wait byte (dummy=0, i.e. exactly
    how a READ is framed) and confirms the first byte back is *not* the
    queued one. Without this the test above would still pass if the RTL
    ignored the wait byte and the helper simply never sent it, so this is
    what makes the pair meaningful rather than self-consistent.
    """
    await init_test(dut)
    await enable(dut)

    test_byte = 0xA5
    assert await ahb_write(dut, ADDR_TXDATA, test_byte, size=HSIZE_BYTE) == 0

    got = await spi_read_frame(dut, 1, address=0x000000,
                               opcode=OP_FAST_READ, dummy=0)

    assert got[0] != test_byte, (
        f"FAST_READ framed with no wait byte still returned 0x{test_byte:02X} "
        f"- the wait byte is not being consumed, so FAST_READ is behaving as "
        f"a synonym for READ"
    )


# --------------------------------------------------------------------------
# FIFOs, packed access, interrupts  (GRPR-SPIS-023 .. -029)
# --------------------------------------------------------------------------


# TEST 9
@spi_s_test()
async def test_rx_fifo_depth(dut):
    """FIFO_DEPTH payload bytes queue and read back in arrival order."""
    await init_test(dut)
    await enable(dut)

    payload = [0x11, 0x22, 0x33, 0x44][:FIFO_DEPTH]
    await spi_write_frame(dut, payload, address=0x001000)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert rx_level(status) == FIFO_DEPTH, \
        f"RX_LEVEL {rx_level(status)}, expected {FIFO_DEPTH}"
    assert status & STATUS_RX_FULL, "RX_FULL not set with the FIFO full"

    for expected in payload:
        got, hresp = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
        assert hresp == 0, "RXDATA read reported HRESP error"
        assert got == expected, f"Expected 0x{expected:02X}, got 0x{got:02X}"

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert status & STATUS_RX_EMPTY, "RX_EMPTY not set after draining"


# TEST 10
@spi_s_test()
async def test_rx_overrun_sets_wire_side_flag(dut):
    """A byte arriving with the RX FIFO full sets OVERRUN, not UNDERFLOW.

    OVERRUN is the in-transfer event - the external host outran firmware.
    UNDERFLOW is the bus-side error. Keeping them apart is the point of the
    split in GRPR-SPIS-028.
    """
    await init_test(dut)
    await enable(dut)

    await spi_write_frame(dut, [0x11, 0x22, 0x33, 0x44, 0x55], address=0x10)

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_OVERRUN, "OVERRUN not set when a byte arrived with RX full"
    assert not (irq & IRQ_UNDERFLOW), \
        "a wire-side overrun must not set the bus-side UNDERFLOW"


# TEST 11
@spi_s_test()
async def test_rxdata_word_read_packs_bytes(dut):
    """A 32-bit RXDATA read returns four received bytes, oldest in bits 7:0."""
    await init_test(dut)
    await enable(dut)

    payload = [0xAA, 0xBB, 0xCC, 0xDD]
    await spi_write_frame(dut, payload, address=0x002000)

    value, hresp = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_WORD)
    assert hresp == 0, "RXDATA word read reported HRESP error"

    expected = (payload[0] | (payload[1] << 8) |
                (payload[2] << 16) | (payload[3] << 24))
    assert value == expected, \
        f"Expected 0x{expected:08X}, got 0x{value:08X}"


# TEST 12
@spi_s_test()
async def test_rxdata_short_word_read(dut):
    """A word read with fewer bytes queued zero-fills and sets UNDERFLOW.

    This is what makes a short read unambiguous: without it firmware could not
    tell a received zero byte from a lane that was never filled.
    """
    await init_test(dut)
    await enable(dut)

    await spi_write_frame(dut, [0x5A, 0xA5], address=0x30)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert rx_level(status) == 2, "expected exactly 2 bytes queued"

    value, hresp = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_WORD)
    assert hresp == 0, "RXDATA word read reported HRESP error"
    assert value == 0x0000A55A, \
        f"Expected 0x0000A55A (upper lanes zeroed), got 0x{value:08X}"

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_UNDERFLOW, "UNDERFLOW not set on a short word read"


# TEST 13
@spi_s_test()
async def test_txdata_word_write_queues_bytes(dut):
    """One 32-bit TXDATA store queues four bytes, sent low lane first."""
    await init_test(dut)
    await enable(dut)

    payload = [0xDE, 0xAD, 0xBE, 0xEF]
    word = (payload[0] | (payload[1] << 8) |
            (payload[2] << 16) | (payload[3] << 24))

    hresp = await ahb_write(dut, ADDR_TXDATA, word, size=HSIZE_WORD)
    assert hresp == 0, "TXDATA word write reported HRESP error"

    # Not asserting TX_FULL here: the holding register that feeds the shifter
    # takes the first byte straight out of the FIFO, so a 4-byte store leaves
    # 3 queued. Capacity is FIFO_DEPTH + 1.
    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert not (status & STATUS_TX_EMPTY), "TX path empty after queueing 4 bytes"

    got = await spi_read_frame(dut, 4, address=0x000000)
    assert got == payload, \
        f"Expected MISO {[hex(b) for b in payload]}, got {[hex(b) for b in got]}"


# TEST 14
@spi_s_test()
async def test_word_access_wait_states(dut):
    """A word access takes 3 wait states, a half-word 1 (GRPR-SPIS-027)."""
    await init_test(dut)
    await enable(dut)

    counter = [0]
    task = cocotb.start_soon(count_waits_task(dut, counter))
    await ahb_write(dut, ADDR_TXDATA, 0xDDCCBBAA, size=HSIZE_WORD)
    task.kill()
    assert counter[0] == 3, \
        f"word TXDATA write took {counter[0]} wait states, expected 3"

    # Drain, then check the half-word case.
    await spi_read_frame(dut, 4, address=0)

    counter = [0]
    task = cocotb.start_soon(count_waits_task(dut, counter))
    await ahb_write(dut, ADDR_TXDATA, 0xBBAA, size=HSIZE_HALF)
    task.kill()
    assert counter[0] == 1, \
        f"half-word TXDATA write took {counter[0]} wait states, expected 1"


# TEST 15
@spi_s_test()
async def test_byte_access_is_zero_wait(dut):
    """Byte accesses stay zero-wait, so byte-at-a-time firmware is unslowed."""
    await init_test(dut)
    await enable(dut)

    counter = [0]
    task = cocotb.start_soon(count_waits_task(dut, counter))
    await ahb_write(dut, ADDR_TXDATA, 0x5A, size=HSIZE_BYTE)
    await ahb_write(dut, ADDR_TXDATA, 0xA5, size=HSIZE_BYTE)
    task.kill()

    assert counter[0] == 0, \
        f"byte TXDATA writes took {counter[0]} wait states, expected none"


# TEST 16
@spi_s_test()
async def test_txdata_overflow_not_wire_paced(dut):
    """A write to a full TX FIFO retires immediately and sets OVERFLOW.

    This is the anti-deadlock property: cpu_ss is single-master, so a stall
    that waited for an external host to drain the FIFO would block instruction
    fetch and the CPU could never run the loop that services it.
    """
    await init_test(dut)
    await enable(dut)

    # FIFO_DEPTH plus the one-entry holding register that feeds the shifter.
    for byte in (0x11, 0x22, 0x33, 0x44, 0x55):
        await ahb_write(dut, ADDR_TXDATA, byte, size=HSIZE_BYTE)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert status & STATUS_TX_FULL, "TX_FULL not set after filling the FIFO"

    counter = [0]
    task = cocotb.start_soon(count_waits_task(dut, counter))
    hresp = await ahb_write(dut, ADDR_TXDATA, 0x66, size=HSIZE_BYTE)
    task.kill()

    assert hresp == 0, "an overflowing write must not error, only flag"
    assert counter[0] == 0, \
        f"write to a full FIFO stalled {counter[0]} cycles - must not be wire-paced"

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_OVERFLOW, "OVERFLOW not set on a write to a full TX FIFO"
    assert not (irq & IRQ_UNDERRUN), \
        "a bus-side overflow must not set the wire-side UNDERRUN"


# TEST 17
@spi_s_test()
async def test_irq_status_w1c(dut):
    """IRQ_STATUS bits are write-1-to-clear; a write of 0 leaves them set."""
    await init_test(dut)
    await enable(dut)

    # An empty-FIFO read is the bus-side error, so it sets UNDERFLOW.
    await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_UNDERFLOW, "UNDERFLOW not set after an empty RX read"

    await ahb_write(dut, ADDR_IRQ_STATUS, 0)
    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_UNDERFLOW, "UNDERFLOW cleared by a write of 0"

    await ahb_write(dut, ADDR_IRQ_STATUS, IRQ_UNDERFLOW)
    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert not (irq & IRQ_UNDERFLOW), "UNDERFLOW not cleared by W1C"


# TEST 18
@spi_s_test()
async def test_irq_en_gates_output(dut):
    """irq follows IRQ_STATUS & IRQ_EN; IRQ_STATUS records either way."""
    await init_test(dut)
    await enable(dut)

    await ahb_write(dut, ADDR_IRQ_EN, 0)
    await spi_write_frame(dut, [0x77], address=0x40)

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_RX_VALID, "IRQ_STATUS must record the event regardless"
    assert int(dut.irq.value) == 0, "irq asserted with IRQ_EN clear"

    await ahb_write(dut, ADDR_IRQ_EN, IRQ_RX_VALID)
    # Two edges: the enable is written on the first and irq, being
    # combinational off the registered enable, settles on the second.
    await RisingEdge(dut.HCLK)
    await RisingEdge(dut.HCLK)
    assert int(dut.irq.value) == 1, "irq did not assert once enabled"

    # Drain the FIFO first: RX_VALID re-asserts while a byte is still queued,
    # so a W1C alone would be immediately re-set by its own source.
    await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
    await ahb_write(dut, ADDR_IRQ_STATUS, IRQ_RX_VALID)
    await RisingEdge(dut.HCLK)
    await RisingEdge(dut.HCLK)
    assert int(dut.irq.value) == 0, "irq did not drop once the source cleared"


# TEST 19
@spi_s_test()
async def test_soft_reset_flushes_fifos(dut):
    """SOFT_RESET empties both FIFOs but leaves IRQ_STATUS alone."""
    await init_test(dut)
    await enable(dut)

    await spi_write_frame(dut, [0x11, 0x22], address=0x50)
    await ahb_write(dut, ADDR_TXDATA, 0x33, size=HSIZE_BYTE)

    irq_before, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq_before & IRQ_RX_VALID, "expected RX_VALID set before the reset"

    await ahb_write(dut, ADDR_CTRL, CTRL_ENABLE | CTRL_SOFT_RESET)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert status & STATUS_RX_EMPTY, "RX FIFO not flushed by SOFT_RESET"
    assert status & STATUS_TX_EMPTY, "TX FIFO not flushed by SOFT_RESET"
    assert rx_level(status) == 0, "RX_LEVEL not cleared by SOFT_RESET"

    irq_after, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq_after & IRQ_RX_VALID, \
        "SOFT_RESET cleared IRQ_STATUS; it records what already happened"


# TEST 20
@spi_s_test()
async def test_reserved_offset_errors(dut):
    """Offsets past the end of the map error, on read and write alike."""
    await init_test(dut)

    hresp = await ahb_write(dut, 0x18, 0xDEADBEEF)
    assert hresp == 1, "expected HRESP error writing past the register map"

    _, hresp = await ahb_read(dut, 0x18)
    assert hresp == 1, "expected HRESP error reading past the register map"


# TEST 21
@spi_s_test()
async def test_mode3_transfer(dut):
    """Mode 3 (CPOL=CPHA=1) transfers correctly (SPIS-SPEC-005)."""
    await init_test(dut)
    await enable(dut, extra=CTRL_CPOL | CTRL_CPHA)

    # Mode 3 idles SCK high and samples on the leading (falling) edge. The
    # driver must produce that waveform, not a mode-0 one with the CTRL bits
    # set -- otherwise this test passes against a block that ignores CPHA.
    dut.spi_s_sck.value = 1
    await RisingEdge(dut.HCLK)

    payload = [0x96]
    await spi_frame(dut, OP_SPI_WRITE, 0x60, payload=payload, mode=3)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert rx_level(status) == 1, \
        f"mode 3: RX_LEVEL {rx_level(status)}, expected 1"

    got, _ = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
    assert got == payload[0], \
        f"mode 3: expected 0x{payload[0]:02X}, got 0x{got:02X}"


# TEST 21b
@spi_s_test()
async def test_mode1_transfer(dut):
    """Mode 1 (CPOL=0, CPHA=1) transfers correctly (SPIS-SPEC-005).

    Modes 0 and 3 both sample on the leading edge, so neither distinguishes a
    block that implements CPOL and ignores CPHA. Mode 1 is the cheapest case
    that does: CPOL and CPHA disagree, so the sampling edge moves.
    """
    await init_test(dut)
    await enable(dut, extra=CTRL_CPHA)

    dut.spi_s_sck.value = 0
    await RisingEdge(dut.HCLK)

    payload = [0x96]
    await spi_frame(dut, OP_SPI_WRITE, 0x60, payload=payload, mode=1)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert rx_level(status) == 1, \
        f"mode 1: RX_LEVEL {rx_level(status)}, expected 1"

    got, _ = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
    assert got == payload[0], \
        f"mode 1: expected 0x{payload[0]:02X}, got 0x{got:02X}"


# TEST 22
@spi_s_test()
async def test_status_busy(dut):
    """BUSY is set during a frame and clear once SS releases."""
    await init_test(dut)
    await enable(dut)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert not (status & STATUS_BUSY), "BUSY set while idle"

    dut.spi_s_ss.value = 0
    await RisingEdge(dut.HCLK)
    await RisingEdge(dut.HCLK)

    assert int(dut.u_core.busy.value) == 1, "BUSY not set during a transaction"

    dut.spi_s_ss.value = 1
    await RisingEdge(dut.HCLK)
    await RisingEdge(dut.HCLK)

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert not (status & STATUS_BUSY), "BUSY did not clear when SS released"
