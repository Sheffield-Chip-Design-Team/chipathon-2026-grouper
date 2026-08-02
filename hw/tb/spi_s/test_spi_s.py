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
CTRL_SOFT_RESET = 1 << 1

STATUS_BUSY = 1 << 0
STATUS_RX_VALID = 1 << 1
STATUS_TX_READY = 1 << 2

CLK_PERIOD_NS = 10

#keep this from UART
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

#test 1
@cocotb.test() 
async def test_ctrl_rw(dut):
    """Test read/write access to the CTRL register."""

    #start clock
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())

    #reset peripheral 
    await reset_dut(dut)

    #Test ENABLE bit
    ctrl_value = CTRL_ENABLE #write to CTRL register

    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_value)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"

    assert value == ctrl_value, \
        f"Expected 0x{ctrl_value:08X}, got 0x{value:08X}"

    #Test ENABLE + SOFT_RESET bits
    ctrl_value = CTRL_ENABLE | CTRL_SOFT_RESET

    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_value)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"

    assert value == ctrl_value, \
        f"Expected 0x{ctrl_value:08X}, got 0x{value:08X}"

#test 2
@cocotb.test()
async def test_status_ro(dut):
    """Test that STATUS is read-only."""

    # Start clock
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())

    # Reset peripheral
    await reset_dut(dut)

    # Read STATUS register after reset
    value, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"

    # STATUS should report TX_READY = 1 after reset
    assert value == STATUS_TX_READY, \
        f"Expected STATUS = 0x{STATUS_TX_READY:08X}, got 0x{value:08X}"

    # Attempt to write STATUS (should return an AHB error)
    hresp = await ahb_write(dut, ADDR_STATUS, 0xFFFFFFFF)
    assert hresp == 1, "Expected HRESP error when writing STATUS"

    # Read STATUS again
    value, hresp = await ahb_read(dut, ADDR_STATUS)
    assert hresp == 0, "STATUS read reported HRESP error"

    # STATUS should be unchanged after the failed write
    assert value == STATUS_TX_READY, \
        f"STATUS register changed after write: 0x{value:08X}"

#test 3
@cocotb.test()
async def test_txdata_wo(dut):
    """Test that TXDATA is write-only."""

    # Start clock
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())

    # Reset peripheral
    await reset_dut(dut)

    # Write a byte to TXDATA
    hresp = await ahb_write(dut, ADDR_TXDATA, 0xA5)
    assert hresp == 0, "TXDATA write reported HRESP error"

    # Read TXDATA back
    value, hresp = await ahb_read(dut, ADDR_TXDATA)
    assert hresp == 0, "TXDATA read reported HRESP error"

    # TXDATA is write-only, so reads currently return 0
    assert value == 0, \
        f"Expected TXDATA read to return 0x00000000, got 0x{value:08X}"

#test 4
@cocotb.test()
async def test_rxdata_ro(dut):
    """Test that RXDATA is read-only."""

    # Start clock
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())

    # Reset peripheral
    await reset_dut(dut)

    # Read RXDATA (should be allowed)
    value, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 0, "RXDATA read reported HRESP error"

    # Attempt to write RXDATA (should return an AHB error)
    hresp = await ahb_write(dut, ADDR_RXDATA, 0x55)
    assert hresp == 1, "Expected HRESP error when writing RXDATA"

    # Read RXDATA again (should still be allowed)
    value, hresp = await ahb_read(dut, ADDR_RXDATA)
    assert hresp == 0, "RXDATA read reported HRESP error"