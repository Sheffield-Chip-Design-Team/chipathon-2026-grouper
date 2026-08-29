"""Directed cocotb tests for ahb_spi_m.

Two groups:

  * register tests  -- reset values, field placement, W1C, error responses
  * transaction tests -- the four APS6404L commands of GRPR-SPIM-006, checked
    against the decoded MOSI byte stream and SCK cycle count

The transaction tests are the ones that matter: they are what would have
caught the defects listed in hw/rtl/spi_m/spi_m_bugs.md.
"""

import functools
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import (
    RisingEdge,
    SimTimeoutError,
    Timer,
    with_timeout,
)

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_BYTE,
    HSIZE_WORD,
    ahb_read,
    ahb_write,
)
from hw.tb.spi_m.spi_m_utils import (
    ADDR,
    CMD,
    CTRL,
    DATA,
    IRQ_EN,
    IRQ_STATUS,
    IRQ_CFG_ERR,
    IRQ_OVERFLOW,
    IRQ_OVERRUN,
    IRQ_UNDERFLOW,
    IRQ_TXN_COMPLETE,
    IRQ_UNDERRUN,
    OP_FAST_READ,
    OP_FAST_WRITE,
    OP_SPI_READ,
    OP_SPI_WRITE,
    FAST_READ_DUMMY,
    ST_BUSY,
    ST_RX_EMPTY,
    ST_TX_EMPTY,
    STATUS,
    SpiMonitor,
    cmd_word,
    ctrl_word,
    wait_not_busy,
)

log = logging.getLogger("cocotb.spi_m_tb")

CLK_PERIOD_NS = 10
# A small divider keeps the tests fast: SCK = HCLK / (2 * (CLKDIV + 1)).
TEST_CLKDIV = 1

async def settle(dut):
    """Advance to a clock edge before letting the test end.

    A test that returns immediately after a Timer or a value read leaves the
    simulator mid-cycle, and Verilator's VPI teardown then walks a partially
    updated model - which comes back as a bare exit -11 (SIGSEGV) from
    ./Vtop after the regression summary has already printed every test as
    passing. Ending on a clock edge lets the cycle complete first. Same
    reasoning, and the same helper, as soc_test() in hw/tb/top/test_soc.py.
    """
    try:
        await with_timeout(RisingEdge(dut.HCLK), 10 * CLK_PERIOD_NS, "ns")
    except SimTimeoutError:
        log.debug("settle: no clock edge - ending without one")
    except Exception as exc:
        log.debug("settle: %s", exc)


def spi_m_test(**kwargs):
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


async def reset_dut(dut):
    dut.HRESETn.value = 0
    dut.HSEL.value = 0
    dut.HREADYIN.value = 1
    dut.HTRANS.value = 0
    dut.HWRITE.value = 0
    dut.HADDR.value = 0
    dut.HWDATA.value = 0
    dut.HSIZE.value = 2
    dut.HBURST.value = 0
    dut.HMASTLOCK.value = 0
    dut.HPROT.value = 0
    dut.spi_m_miso_i.value = 0

    await Timer(20, unit="ns")
    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)


async def init_test(dut):
    """Start the clock and release reset. Returns with the DUT idle."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)


async def configure(dut, cpol=0, cpha=0, clk_div=TEST_CLKDIV):
    """Program CTRL and confirm it read back."""
    value = ctrl_word(cpol=cpol, cpha=cpha, clk_div=clk_div, enable=1)
    hresp = await ahb_write(dut, CTRL, value)
    assert hresp == 0, "CTRL write errored unexpectedly"
    readback, _ = await ahb_read(dut, CTRL)
    assert readback == value, \
        "CTRL readback 0x%08x != written 0x%08x" % (readback, value)


async def push_tx(dut, data_bytes):
    """Push bytes into the TX FIFO via DATA, one byte per store.

    HSIZE_BYTE, not the default word size: a DATA write pushes 1-4 bytes
    according to the transfer size (SPIM-ISSUE-017 and the DATA row of the
    specification's register map), so a 32-bit store of one byte strobes all
    four lanes and queues that byte followed by three zeros. Pushing three
    bytes that way put 0xDE 0x00 0x00 on the wire and swallowed the two
    following stores, because the second and third arrived while the first
    store's lanes were still draining.
    """
    for byte in data_bytes:
        hresp = await ahb_write(dut, DATA, byte, size=HSIZE_BYTE)
        assert hresp == 0, "DATA write errored"


def expect_bytes(actual, expected, what):
    assert actual == expected, \
        "%s mismatch:\n  expected %s\n  actual   %s" % (
            what,
            " ".join("0x%02X" % b for b in expected),
            " ".join("0x%02X" % b for b in actual),
        )


# ---------------------------------------------------------------------------
# Register tests
# ---------------------------------------------------------------------------

@spi_m_test()
async def test_reset_values(dut):
    """Every register reads its specified reset value. GRPR-SPIM-001."""
    await init_test(dut)

    # CTRL resets with CLKDIV = 1 (4 MHz from 16 MHz -- GRPR-SPIM-013).
    ctrl, _ = await ahb_read(dut, CTRL)
    assert ctrl == 0x0000_0100, "CTRL reset 0x%08x != 0x00000100" % ctrl

    cmd, _ = await ahb_read(dut, CMD)
    assert cmd == 0, "CMD reset 0x%08x != 0" % cmd

    # STATUS reset 0x0A: TX_EMPTY and RX_EMPTY set, not busy.
    status, _ = await ahb_read(dut, STATUS)
    assert status == 0x0000_000A, "STATUS reset 0x%08x != 0x0A" % status

    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq == 0, "IRQ_STATUS reset 0x%08x != 0" % irq

    irq_en, _ = await ahb_read(dut, IRQ_EN)
    assert irq_en == 0, "IRQ_EN reset 0x%08x != 0" % irq_en

    addr, _ = await ahb_read(dut, ADDR)
    assert addr == 0, "ADDR reset 0x%08x != 0" % addr

    log.info("reset values OK")


@spi_m_test()
async def test_ctrl_fields(dut):
    """CTRL field placement: CPHA[0] CPOL[1] ENABLE[3] CLKDIV[15:8] IE[17:16]."""
    await init_test(dut)

    value = ctrl_word(cpol=1, cpha=1, clk_div=0xA5, enable=1,
                      ie_complete=1, ie_err=1)
    await ahb_write(dut, CTRL, value)
    readback, _ = await ahb_read(dut, CTRL)

    assert readback == value, \
        "CTRL readback 0x%08x != 0x%08x" % (readback, value)
    assert (readback >> 8) & 0xFF == 0xA5, "CLKDIV not at bits [15:8]"
    assert readback & 0x1 == 1 and (readback >> 1) & 0x1 == 1, "CPHA/CPOL wrong"
    assert (readback >> 3) & 0x1 == 1, "ENABLE not at bit 3"


@spi_m_test()
async def test_cmd_fields(dut):
    """CMD field placement, and START always reads back 0 (self-clearing)."""
    await init_test(dut)
    await configure(dut)

    # Descriptor only: no START, so nothing launches.
    value = cmd_word(opcode=0x9A, cmd_en=1, addr_en=1, addr_bytes=2,
                     data_en=1, dir_read=1, dummy=8, data_len=4, start=0)
    await ahb_write(dut, CMD, value)
    readback, _ = await ahb_read(dut, CMD)

    assert readback == value, \
        "CMD readback 0x%08x != 0x%08x" % (readback, value)
    assert (readback >> 1) & 0xFF == 0x9A, "OPCODE not at bits [8:1]"
    assert readback & 0x1 == 0, "START must always read 0"


@spi_m_test()
async def test_start_self_clears(dut):
    """SPIM-ISSUE-005: START is a pulse, so a transfer must not repeat."""
    await init_test(dut)
    await configure(dut)

    monitor = SpiMonitor(dut).start()
    await ahb_write(dut, CMD, cmd_word(opcode=OP_SPI_WRITE, cmd_en=1,
                                       data_en=0, start=1))
    await wait_not_busy(dut, ahb_read)

    # Give the block plenty of time to (wrongly) relaunch.
    await Timer(2000, unit="ns")
    monitor.stop()

    start, _ = await ahb_read(dut, CMD)
    assert start & 0x1 == 0, "START read back set"
    assert monitor.cs_windows == 1, \
        "transfer ran %d times, expected 1 (START did not self-clear)" % \
        monitor.cs_windows


@spi_m_test()
async def test_addr_byte_strobes(dut):
    """SPIM-ISSUE-019: a sub-word ADDR write must not clobber all 32 bits."""
    await init_test(dut)

    await ahb_write(dut, ADDR, 0x1234_5678)
    value, _ = await ahb_read(dut, ADDR)
    assert value == 0x1234_5678, "ADDR word write failed: 0x%08x" % value

    # Byte write to the lowest byte only.
    await ahb_write(dut, ADDR, 0xAA, size=HSIZE_BYTE)
    value, _ = await ahb_read(dut, ADDR)
    assert value == 0x1234_56AA, \
        "byte write to ADDR clobbered upper bytes: 0x%08x" % value


@spi_m_test()
async def test_irq_status_w1c(dut):
    """IRQ_STATUS bits are write-1-to-clear."""
    await init_test(dut)
    await configure(dut)

    # Reading the empty RX FIFO is an AHB access error, so it sets UNDERFLOW
    # (bit 4), not the in-transfer UNDERRUN (bit 1) -- SPIM-SPEC-001.
    await ahb_read(dut, DATA)
    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_UNDERFLOW, "UNDERFLOW not set after empty RX read"
    assert not (irq & IRQ_UNDERRUN), \
        "an AHB read of an empty RX FIFO must not set the in-transfer UNDERRUN"

    # Writing 0 to the bit leaves it alone.
    await ahb_write(dut, IRQ_STATUS, 0)
    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_UNDERFLOW, "UNDERFLOW cleared by a write of 0"

    # Writing 1 clears it.
    await ahb_write(dut, IRQ_STATUS, IRQ_UNDERFLOW)
    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert not (irq & IRQ_UNDERFLOW), "UNDERFLOW not cleared by W1C"


@spi_m_test()
async def test_tx_overrun(dut):
    """Writing a full TX FIFO is dropped and sets OVERFLOW."""
    await init_test(dut)
    await configure(dut)

    # FIFO_DEPTH is 4; the fifth push overruns.
    await push_tx(dut, [0x11, 0x22, 0x33, 0x44])
    status, _ = await ahb_read(dut, STATUS)
    assert not (status & ST_TX_EMPTY), "TX FIFO still reads empty after 4 pushes"

    # A push to a full TX FIFO is an AHB access error, so it sets OVERFLOW
    # (bit 5), not the in-transfer OVERRUN (bit 2) -- SPIM-SPEC-001.
    await push_tx(dut, [0x55])
    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_OVERFLOW, "OVERFLOW not set on write to a full TX FIFO"
    assert not (irq & IRQ_OVERRUN), \
        "an AHB write to a full TX FIFO must not set the in-transfer OVERRUN"


@spi_m_test()
async def test_illegal_mode_error_response(dut):
    """GRPR-SPIM-016 / SPIM-ISSUE-014: CPOL != CPHA gives a 2-cycle ERROR."""
    await init_test(dut)

    # CPHA=1, CPOL=0 is neither mode 0 nor mode 3.
    hresp = await ahb_write(dut, CTRL, (1 << 0) | (0 << 1))
    assert hresp == 1, "illegal CPOL/CPHA pair did not produce HRESP"

    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_CFG_ERR, "CFG_ERR not set for an illegal mode"

    # The illegal write must not have taken effect.
    ctrl, _ = await ahb_read(dut, CTRL)
    assert ctrl & 0x3 == 0, "illegal mode was accepted into CTRL"


@spi_m_test()
async def test_status_write_error(dut):
    """STATUS is read-only: a write must error."""
    await init_test(dut)
    hresp = await ahb_write(dut, STATUS, 0x1234_5678)
    assert hresp == 1, "write to read-only STATUS did not produce HRESP"


@spi_m_test()
async def test_cfg_err_start_while_busy(dut):
    """START while BUSY sets CFG_ERR and does not disturb the transfer."""
    await init_test(dut)
    await configure(dut)

    monitor = SpiMonitor(dut).start()
    await push_tx(dut, [0xA5])
    await ahb_write(dut, CMD, cmd_word(opcode=OP_SPI_WRITE, cmd_en=1,
                                       data_en=1, data_len=1))

    # Second START while the first is still running.
    await ahb_write(dut, CMD, cmd_word(opcode=OP_SPI_READ, cmd_en=1))
    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_CFG_ERR, "CFG_ERR not set for START while BUSY"

    await wait_not_busy(dut, ahb_read)
    monitor.stop()
    # The original descriptor must have survived.
    expect_bytes(monitor.mosi_bytes, [OP_SPI_WRITE, 0xA5],
                 "MOSI after a rejected second START")


# ---------------------------------------------------------------------------
# Transaction tests -- the four commands of GRPR-SPIM-006
# ---------------------------------------------------------------------------

@spi_m_test()
async def test_spi_write(dut):
    """SPI_WRITE (0x02): opcode + 24-bit address + data, all on MOSI.

    Covers SPIM-ISSUE-001/-002/-010/-012: opcode present, 8 SCK per byte,
    the low-order address bytes in order, and no leading 0x00 data byte.
    """
    await init_test(dut)
    await configure(dut)

    spi_addr = 0x0012_3456
    payload = [0xDE, 0xAD, 0xBE]

    monitor = SpiMonitor(dut).start()

    await ahb_write(dut, ADDR, spi_addr)
    await push_tx(dut, payload)
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_SPI_WRITE, cmd_en=1,
        addr_en=1, addr_bytes=2,          # 3 address bytes
        data_en=1, dir_read=0,
        data_len=len(payload),
    ))

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expected = [OP_SPI_WRITE, 0x12, 0x34, 0x56] + payload
    expect_bytes(monitor.mosi_bytes, expected, "SPI_WRITE MOSI stream")

    # GRPR-SPIM-016: exactly 8 SCK cycles per byte, no dummy phase.
    assert monitor.sck_cycles == 8 * len(expected), \
        "SPI_WRITE used %d SCK cycles, expected %d" % (
            monitor.sck_cycles, 8 * len(expected))

    # GRPR-SPIM-017: CS_N deasserted exactly once, at the end.
    assert monitor.cs_windows == 1, \
        "expected 1 CS_N window, saw %d" % monitor.cs_windows
    assert int(dut.spi_m_cs_n_o.value) == 1, "CS_N still low after the transfer"

    # GRPR-SPIM-008: completion flag.
    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_TXN_COMPLETE, "TXN_COMPLETE not set after SPI_WRITE"


@spi_m_test()
async def test_fast_write(dut):
    """FAST_WRITE (0x38): same shape as SPI_WRITE with a different opcode."""
    await init_test(dut)
    await configure(dut)

    spi_addr = 0x00AB_CDEF
    payload = [0x01, 0x02]

    monitor = SpiMonitor(dut).start()

    await ahb_write(dut, ADDR, spi_addr)
    await push_tx(dut, payload)
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_FAST_WRITE, cmd_en=1,
        addr_en=1, addr_bytes=2,
        data_en=1, dir_read=0,
        data_len=len(payload),
    ))

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expected = [OP_FAST_WRITE, 0xAB, 0xCD, 0xEF] + payload
    expect_bytes(monitor.mosi_bytes, expected, "FAST_WRITE MOSI stream")
    assert monitor.sck_cycles == 8 * len(expected), \
        "FAST_WRITE used %d SCK cycles, expected %d" % (
            monitor.sck_cycles, 8 * len(expected))


@spi_m_test()
async def test_spi_read(dut):
    """SPI_READ (0x03): opcode + address out, data in on MISO, no dummy.

    Covers SPIM-ISSUE-007/-009/-011: the RX FIFO must hold exactly the data
    phase bytes -- not the command or address phases -- and MOSI must not
    drain the TX FIFO during a read.
    """
    await init_test(dut)
    await configure(dut)

    spi_addr = 0x0000_1234
    # The slave model shifts these out from the first SCK edge; the command
    # and address phases consume the first 4 bytes, so pad them.
    read_data = [0x55, 0x66, 0x77]
    miso_stream = [0x00, 0x00, 0x00, 0x00] + read_data

    monitor = SpiMonitor(dut, miso_data=miso_stream).start()

    await ahb_write(dut, ADDR, spi_addr)
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_SPI_READ, cmd_en=1,
        addr_en=1, addr_bytes=2,
        data_en=1, dir_read=1,
        data_len=len(read_data),
    ))

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    # MOSI carries only the command and address phases -- SPIM-ISSUE-009.
    expected_mosi = [OP_SPI_READ, 0x00, 0x12, 0x34]
    got_mosi = monitor.mosi_bytes[:len(expected_mosi)]
    expect_bytes(got_mosi, expected_mosi, "SPI_READ MOSI stream")

    # Total SCK: 1 opcode + 3 address + 3 data bytes.
    assert monitor.sck_cycles == 8 * 7, \
        "SPI_READ used %d SCK cycles, expected 56" % monitor.sck_cycles

    # The RX FIFO holds exactly the data-phase bytes.
    received = []
    for _ in range(len(read_data)):
        status, _ = await ahb_read(dut, STATUS)
        assert not (status & ST_RX_EMPTY), "RX FIFO empty too early"
        value, _ = await ahb_read(dut, DATA)
        received.append(value & 0xFF)

    expect_bytes(received, read_data, "SPI_READ RX data")

    status, _ = await ahb_read(dut, STATUS)
    assert status & ST_RX_EMPTY, \
        "RX FIFO not empty after popping all data -- extra bytes captured"


@spi_m_test()
async def test_fast_read(dut):
    """FAST_READ (0x0B): opcode + address + 8 dummy SCK cycles, then data.

    Covers SPIM-ISSUE-006: DUMMY counts whole SCK cycles, not half periods.
    """
    await init_test(dut)
    await configure(dut)

    spi_addr = 0x0000_0010
    read_data = [0xC3, 0x3C]
    # 1 opcode + 3 address + 1 dummy byte-time = 5 bytes before data.
    miso_stream = [0x00] * 5 + read_data

    monitor = SpiMonitor(dut, miso_data=miso_stream).start()

    await ahb_write(dut, ADDR, spi_addr)
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_FAST_READ, cmd_en=1,
        addr_en=1, addr_bytes=2,
        data_en=1, dir_read=1,
        dummy=FAST_READ_DUMMY,
        data_len=len(read_data),
    ))

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expected_mosi = [OP_FAST_READ, 0x00, 0x00, 0x10]
    expect_bytes(monitor.mosi_bytes[:4], expected_mosi, "FAST_READ MOSI stream")

    # 4 bytes out + 8 dummy cycles + 2 bytes in.
    expected_sck = 8 * 4 + FAST_READ_DUMMY + 8 * len(read_data)
    assert monitor.sck_cycles == expected_sck, \
        "FAST_READ used %d SCK cycles, expected %d (DUMMY miscounted?)" % (
            monitor.sck_cycles, expected_sck)

    received = []
    for _ in range(len(read_data)):
        value, _ = await ahb_read(dut, DATA)
        received.append(value & 0xFF)
    expect_bytes(received, read_data, "FAST_READ RX data")


@spi_m_test()
async def test_mode3(dut):
    """GRPR-SPIM-002/-009: the same transfer works in mode 3 (CPOL=CPHA=1)."""
    await init_test(dut)
    await configure(dut, cpol=1, cpha=1)

    # SCK must idle high in mode 3.
    await Timer(100, unit="ns")
    assert int(dut.spi_m_sck_o.value) == 1, "SCK does not idle high in mode 3"

    payload = [0x5A]
    monitor = SpiMonitor(dut, cpol=1, cpha=1).start()

    await push_tx(dut, payload)
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_SPI_WRITE, cmd_en=1, data_en=1, data_len=len(payload),
    ))

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expect_bytes(monitor.mosi_bytes, [OP_SPI_WRITE] + payload,
                 "mode 3 MOSI stream")
    assert int(dut.spi_m_sck_o.value) == 1, "SCK not back to idle high after mode 3"


@spi_m_test()
async def test_cmd_only_transfer(dut):
    """A command-only descriptor emits exactly one byte. GRPR-SPIM-016."""
    await init_test(dut)
    await configure(dut)

    monitor = SpiMonitor(dut).start()
    await ahb_write(dut, CMD, cmd_word(opcode=0x66, cmd_en=1,
                                       addr_en=0, data_en=0))
    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expect_bytes(monitor.mosi_bytes, [0x66], "command-only MOSI stream")
    assert monitor.sck_cycles == 8, \
        "command-only used %d SCK cycles, expected 8" % monitor.sck_cycles


@spi_m_test()
async def test_addr_bytes_widths(dut):
    """ADDR_BYTES selects the low-order N+1 bytes, MSB first. SPIM-ISSUE-012."""
    await init_test(dut)
    await configure(dut)

    cases = [
        (0, [0x78]),
        (1, [0x56, 0x78]),
        (2, [0x34, 0x56, 0x78]),
        (3, [0x12, 0x34, 0x56, 0x78]),
    ]

    for addr_bytes, expected_addr in cases:
        monitor = SpiMonitor(dut).start()
        await ahb_write(dut, ADDR, 0x1234_5678)
        await ahb_write(dut, CMD, cmd_word(
            opcode=OP_SPI_READ, cmd_en=1,
            addr_en=1, addr_bytes=addr_bytes,
            data_en=0,
        ))
        await wait_not_busy(dut, ahb_read)
        await Timer(200, unit="ns")
        monitor.stop()

        expect_bytes(monitor.mosi_bytes, [OP_SPI_READ] + expected_addr,
                     "ADDR_BYTES=%d MOSI stream" % addr_bytes)


@spi_m_test()
async def test_clkdiv_ratio(dut):
    """GRPR-SPIM-010: SCK period is 2 * (CLKDIV + 1) system clocks."""
    await init_test(dut)

    clk_div = 3
    await configure(dut, clk_div=clk_div)

    await ahb_write(dut, CMD, cmd_word(opcode=0x9F, cmd_en=1, data_en=0))

    # Time two consecutive rising SCK edges.
    await RisingEdge(dut.spi_m_sck_o)
    start = cocotb.utils.get_sim_time(unit="ns")
    await RisingEdge(dut.spi_m_sck_o)
    period = cocotb.utils.get_sim_time(unit="ns") - start

    expected = 2 * (clk_div + 1) * CLK_PERIOD_NS
    assert period == expected, \
        "SCK period %d ns, expected %d ns for CLKDIV=%d" % (
            period, expected, clk_div)

    await wait_not_busy(dut, ahb_read)


@spi_m_test()
async def test_tx_fifo_stall(dut):
    """SPIM-SPEC-009: a data phase longer than the FIFO stalls, then resumes.

    The block holds CS_N low and stops SCK when the TX FIFO runs dry, so a
    transfer longer than FIFO_DEPTH completes as the CPU keeps feeding it.
    """
    await init_test(dut)
    await configure(dut)

    payload = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60]   # 6 bytes, FIFO holds 4
    monitor = SpiMonitor(dut).start()

    await push_tx(dut, payload[:4])
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_SPI_WRITE, cmd_en=1, data_en=1, data_len=len(payload),
    ))

    # Feed the rest once the FIFO has drained a little.
    for byte in payload[4:]:
        for _ in range(2000):
            status, _ = await ahb_read(dut, STATUS)
            if status & ST_TX_EMPTY:
                break
            await RisingEdge(dut.HCLK)
        await push_tx(dut, [byte])

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expect_bytes(monitor.mosi_bytes, [OP_SPI_WRITE] + payload,
                 "stalled SPI_WRITE MOSI stream")
    assert monitor.cs_windows == 1, \
        "CS_N deasserted mid-stall (%d windows)" % monitor.cs_windows


@spi_m_test()
async def test_fifo_flush(dut):
    """CMD.TX_FLUSH / RX_FLUSH empty the FIFOs. SPIM-ISSUE-022."""
    await init_test(dut)
    await configure(dut)

    await push_tx(dut, [0x11, 0x22])
    status, _ = await ahb_read(dut, STATUS)
    assert not (status & ST_TX_EMPTY), "TX FIFO reads empty after 2 pushes"

    # Flush without starting a transfer.
    await ahb_write(dut, CMD, cmd_word(cmd_en=0, data_en=0, start=0,
                                       tx_flush=1, rx_flush=1))
    await RisingEdge(dut.HCLK)
    await RisingEdge(dut.HCLK)

    status, _ = await ahb_read(dut, STATUS)
    assert status & ST_TX_EMPTY, "TX FIFO not empty after TX_FLUSH"
    assert status & ST_RX_EMPTY, "RX FIFO not empty after RX_FLUSH"


@spi_m_test()
async def test_reset_mid_transfer_drops(dut):
    """A reset mid-transfer drops the transaction outright (SPIM-SPEC-007).

    The block does not resume or replay: CS_N returns high, STATUS goes back
    to its reset value with both FIFOs empty, and only whatever bytes had
    already been clocked out are on the wire.
    """
    await init_test(dut)
    await configure(dut)

    monitor = SpiMonitor(dut).start()
    await ahb_write(dut, ADDR, 0x0012_3456)
    await push_tx(dut, [0xDE, 0xAD, 0xBE])
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_SPI_WRITE, cmd_en=1,
        addr_en=1, addr_bytes=2,
        data_en=1, dir_read=0, data_len=3,
    ))

    # Let the command phase get under way, then reset mid-flight.
    for _ in range(40):
        await RisingEdge(dut.HCLK)
    assert int(dut.spi_m_cs_n_o.value) == 0, "CS_N not asserted mid-transfer"

    await reset_dut(dut)
    monitor.stop()

    assert int(dut.spi_m_cs_n_o.value) == 1, "CS_N still low after reset"

    status, _ = await ahb_read(dut, STATUS)
    assert status == 0x0000_000A, \
        "STATUS 0x%02x after reset, expected the 0x0A reset value" % status

    # Nothing is retried: the transfer does not restart on its own.
    await Timer(2000, unit="ns")
    assert int(dut.spi_m_cs_n_o.value) == 1, "transfer resumed after reset"
    assert monitor.cs_windows == 1, \
        "%d CS_N windows -- the dropped transfer was replayed" % \
        monitor.cs_windows


@spi_m_test()
async def test_disable_mid_transfer_completes(dut):
    """Clearing CTRL.ENABLE does not kill a transfer already under way.

    A CTRL write while BUSY is ignored and flags CFG_ERR (GRPR-SPIM-016), so
    ENABLE cannot drop mid-transfer: the transaction runs to completion and
    puts its whole byte stream on the wire.
    """
    await init_test(dut)
    await configure(dut)

    payload = [0xDE, 0xAD, 0xBE]
    monitor = SpiMonitor(dut).start()

    await ahb_write(dut, ADDR, 0x0012_3456)
    await push_tx(dut, payload)
    await ahb_write(dut, CMD, cmd_word(
        opcode=OP_SPI_WRITE, cmd_en=1,
        addr_en=1, addr_bytes=2,
        data_en=1, dir_read=0, data_len=len(payload),
    ))

    for _ in range(40):
        await RisingEdge(dut.HCLK)
    assert int(dut.spi_busy.value) == 1, "not busy yet -- test set up wrong"

    # Try to disable mid-transfer. The write is rejected, not applied.
    await ahb_write(dut, CTRL, ctrl_word(clk_div=TEST_CLKDIV, enable=0))

    irq, _ = await ahb_read(dut, IRQ_STATUS)
    assert irq & IRQ_CFG_ERR, "CTRL write while BUSY did not flag CFG_ERR"

    await wait_not_busy(dut, ahb_read)
    await Timer(200, unit="ns")
    monitor.stop()

    expect_bytes(monitor.mosi_bytes,
                 [OP_SPI_WRITE, 0x12, 0x34, 0x56] + payload,
                 "MOSI stream after a rejected mid-transfer disable")
    assert monitor.cs_windows == 1, \
        "%d CS_N windows, expected 1" % monitor.cs_windows

    # ENABLE survived the rejected write.
    ctrl, _ = await ahb_read(dut, CTRL)
    assert ctrl & (1 << 3), "ENABLE was cleared by a write that BUSY rejected"


@spi_m_test()
async def test_irq_output(dut):
    """GRPR-SPIM-008: irq asserts on completion when enabled, clears on W1C."""
    await init_test(dut)

    await ahb_write(dut, CTRL, ctrl_word(clk_div=TEST_CLKDIV, enable=1,
                                         ie_complete=1))
    await ahb_write(dut, IRQ_EN, IRQ_TXN_COMPLETE)

    assert int(dut.irq.value) == 0, "irq asserted before any transfer"

    await ahb_write(dut, CMD, cmd_word(opcode=0x9F, cmd_en=1, data_en=0))
    await wait_not_busy(dut, ahb_read)
    await Timer(100, unit="ns")

    assert int(dut.irq.value) == 1, "irq not asserted after completion"

    await ahb_write(dut, IRQ_STATUS, IRQ_TXN_COMPLETE)
    await Timer(50, unit="ns")
    assert int(dut.irq.value) == 0, "irq not cleared after W1C"
