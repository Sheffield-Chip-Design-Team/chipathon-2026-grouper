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

    dut.spi_ss.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)

    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)


async def spi_send_byte(dut, data):
    """Send one byte over the SPI interface (MSB first)."""

    dut.spi_ss.value = 0

    for i in range(7, -1, -1):
        dut.spi_mosi.value = (data >> i) & 1

        await RisingEdge(dut.HCLK)

        dut.spi_sck.value = 1
        await RisingEdge(dut.HCLK)

        dut.spi_sck.value = 0
        await RisingEdge(dut.HCLK)

    dut.spi_ss.value = 1

# TEST 1
@cocotb.test()
async def test_ctrl_rw(dut):
    """Test read/write access to the CTRL register."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )

    await reset_dut(dut)

    # test ENABLE bit
    ctrl_value = CTRL_ENABLE

    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_value)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"

    assert value == ctrl_value, \
        f"Expected 0x{ctrl_value:08X}, got 0x{value:08X}"

    # test ENABLE + SOFT_RESET bits
    ctrl_value = CTRL_ENABLE | CTRL_SOFT_RESET

    hresp = await ahb_write(dut, ADDR_CTRL, ctrl_value)
    assert hresp == 0, "CTRL write reported HRESP error"

    value, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"

    assert value == ctrl_value, \
        f"Expected 0x{ctrl_value:08X}, got 0x{value:08X}"

# TEST 2
@cocotb.test()
async def test_status_ro(dut):
    """Test that STATUS is read-only."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )
    
    await reset_dut(dut)

    # read STATUS after reset
    value, hresp = await ahb_read(dut, ADDR_STATUS)

    assert hresp == 0, \
        "STATUS read reported HRESP error"

    # TX_READY should be high after reset
    assert value == STATUS_TX_READY, \
        f"Expected STATUS = 0x{STATUS_TX_READY:08X}, got 0x{value:08X}"

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

    assert value == STATUS_TX_READY, \
        f"STATUS changed after write: 0x{value:08X}"

# TEST 3
@cocotb.test()
async def test_txdata_wo(dut):
    """Test that TXDATA is write-only."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )

    await reset_dut(dut)

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
@cocotb.test()
async def test_rxdata_ro(dut):
    """Test that RXDATA is read-only."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )

    await reset_dut(dut)

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
@cocotb.test()
async def test_spi_receive_byte(dut):
    """Receive one byte over SPI."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )
    await reset_dut(dut)

    # enable the SPI
    hresp = await ahb_write(
        dut,
        ADDR_CTRL,
        CTRL_ENABLE
    )
    assert hresp == 0, \
        "CTRL write reported HRESP error"

    TEST_BYTE = 0xA5

    # send one byte over SPI
    await spi_send_byte(
        dut,
        TEST_BYTE
    )

    # read STATUS
    status, hresp = await ahb_read(
        dut,
        ADDR_STATUS
    )

    assert hresp == 0, \
        "STATUS read reported HRESP error"
    
    assert status & STATUS_RX_VALID, \
        "STATUS_RX_VALID was not set"

    # read RXDATA
    value, hresp = await ahb_read(
        dut,
        ADDR_RXDATA
    )

    assert hresp == 0, \
        "RXDATA read reported HRESP error"

    assert value == TEST_BYTE, \
        f"Expected 0x{TEST_BYTE:02X}, got 0x{value:02X}"


# TEST 6
@cocotb.test()
async def test_rx_valid_clears_after_read(dut):
    """RX_VALID should clear after RXDATA is read."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )

    await reset_dut(dut)

    # enable the SPI
    hresp = await ahb_write(
        dut,
        ADDR_CTRL,
        CTRL_ENABLE
    )

    assert hresp == 0, \
        "CTRL write reported HRESP error"

    # send one byte
    await spi_send_byte(
        dut,
        0xA5
    )

    # STATUS should show RX_VALID
    status, hresp = await ahb_read(
        dut,
        ADDR_STATUS
    )

    assert hresp == 0, \
        "STATUS read reported HRESP error"

    assert status & STATUS_RX_VALID, \
        "RX_VALID was not set after receiving a byte"

    # read RXDATA
    data, hresp = await ahb_read(
        dut,
        ADDR_RXDATA
    )

    assert hresp == 0, \
        "RXDATA read reported HRESP error"

    assert data == 0xA5, \
        f"Expected RXDATA = 0xA5, got 0x{data:02X}"

    # STATUS for RX_VALID should be cleared
    status, hresp = await ahb_read(
        dut,
        ADDR_STATUS
    )

    assert hresp == 0, \
        "STATUS read reported HRESP error"

    assert (status & STATUS_RX_VALID) == 0, \
        "RX_VALID did not clear after reading RXDATA"

# TEST 7
@cocotb.test()
async def test_txdata_multiple_writes(dut):
    """Test that multiple TXDATA writes are accepted."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )

    await reset_dut(dut)

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
@cocotb.test()
async def test_spi_transmit_byte(dut):
    """Transmit one byte from TXDATA over MISO."""

    cocotb.start_soon(
        Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start()
    )
    await reset_dut(dut)

    # enable the SPI
    hresp = await ahb_write(
        dut,
        ADDR_CTRL,
        CTRL_ENABLE
    )
    assert hresp == 0, \
        "CTRL write reported HRESP error"

    # write a byte that should be transmitted
    test_byte = 0xA5
    hresp = await ahb_write(
        dut,
        ADDR_TXDATA,
        test_byte
    )
    assert hresp == 0, \
        "TXDATA write reported HRESP error"

    # select SPI slave
    dut.spi_ss.value = 0

    # give the slave one HCLK cycle, SS go low
    await RisingEdge(dut.HCLK)
    received = 0

    # read 8 bits (MSB first)
    for i in range(8):

        # master raises SCK
        # slave should have the current bit ready on MISO
        dut.spi_sck.value = 1
        await RisingEdge(dut.HCLK)

        # sample MISO on the rising edge
        bit = int(dut.spi_miso.value)
        received = (received << 1) | bit

        # master lowers SCK
        # slave shifts to the next bit on the falling edge
        dut.spi_sck.value = 0
        await RisingEdge(dut.HCLK)

    # deselect SPI slave
    dut.spi_ss.value = 1

    assert received == test_byte, \
        f"Expected MISO = 0x{test_byte:02X}, got 0x{received:02X}"