"""Simple directed cocotb testbench for ahb_uart (hw/rtl/uart/ahb_uart.sv).

No pyuvm - just plain cocotb.test()s that drive the AHB3-Lite bus and the
uart_tx/uart_rx pins directly. For a fuller constrained-random/coverage-driven
bench built on pyuvm and reusable VIPs, see hw/dv/ahb_uart/.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

from hw.dv.ahb_uart.uart_clk_math import clk_div_for_baud
from hw.tb.tb_utils.ahb_utils import HSIZE_WORD, HTRANS_IDLE, ahb_read, ahb_write

ADDR_CTRL = 0x0
ADDR_STATUS = 0x4
ADDR_TXDATA = 0x8
ADDR_RXDATA = 0xC

CTRL_ENABLE = 1 << 0
CTRL_TX_EN = 1 << 1
CTRL_RX_EN = 1 << 2
CTRL_RX_RESYNC_EN = 1 << 3
CTRL_CLK_DIV_SHIFT = 16

STATUS_TX_EMPTY = 1 << 0
STATUS_RX_EMPTY = 1 << 2
STATUS_TX_ACTIVE = 1 << 4

CLK_PERIOD_NS = 10
BAUD_RATE = 1_250_000
UART_OVERSAMPLE = 8

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

    data, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 0, "RXDATA read reported HRESP error"
    assert data == rx_byte, f"expected 0x{rx_byte:02x}, read 0x{data:02x}"
