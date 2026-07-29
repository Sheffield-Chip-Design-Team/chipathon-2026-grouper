"""Simple directed cocotb testbench for ahb_spi_s

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

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

    dut.spi_ss.value = 1 #slave not selected
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    
    for _ in range(5):
        await RisingEdge(dut.HCLK)
    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)

@cocotb.test()
async def test_spi_txdata_write(dut):
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
async def test_spi_rxdata_read(dut):
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
