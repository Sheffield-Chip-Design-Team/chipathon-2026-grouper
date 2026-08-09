import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, FallingEdge
import logging
log = logging.getLogger("cocotb.spi_m_tb")

# ------------------------------------------------------------
# AHB SPI MASTER TEST
# ------------------------------------------------------------

CTRL   = 0x00
CMD    = 0x04
STATUS = 0x08
INT    = 0x0C
ADDR   = 0x10
DATA   = 0x14

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

    dut.SPI_MISO.value = 0

    await Timer(20, unit="ns")

    dut.HRESETn.value = 1

    await RisingEdge(dut.HCLK)

# FIXME - use the common functions for ahb_read/write for consistency
# These functions don't consider the AHB response (HRESP, HREADYOUT) signals, which is important for error handling.
  
async def ahb_write(dut, addr, data):
    # Address phase
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1
    dut.HTRANS.value = 2       
    dut.HWRITE.value = 1
    dut.HADDR.value = addr
    dut.HWDATA.value = data
    dut.HSIZE.value = 2        # 32-bit

    await RisingEdge(dut.HCLK)

    # Return bus to idle
    dut.HSEL.value = 0
    dut.HTRANS.value = 0
    dut.HWRITE.value = 0

    await RisingEdge(dut.HCLK)

async def ahb_read(dut, addr):
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1
    dut.HTRANS.value = 2       
    dut.HWRITE.value = 0
    dut.HADDR.value = addr
    dut.HSIZE.value = 2        # 32-bit

    await RisingEdge(dut.HCLK)

    # Read data is available from the registered address phase
    await Timer(1, unit="ns")
    data = int(dut.HRDATA.value)

    dut.HSEL.value = 0
    dut.HTRANS.value = 0

    await RisingEdge(dut.HCLK)

    return data

async def wait_for_spi_clock(dut, timeout_ns=5000):
    """Wait until SPI_SCK becomes a known 0/1 and then wait for an edge."""

    # Wait for SCK to become known
    for _ in range(timeout_ns // 10):
        value = dut.SPI_SCK.value

        if str(value) in ("0", "1"):
            initial = int(value)

            #  wait for it to change
            for _ in range(timeout_ns // 10):
                await Timer(10, unit="ns")

                current = dut.SPI_SCK.value

                if str(current) in ("0", "1") and int(current) != initial:
                    return True

            return False

        await Timer(10, unit="ns")

    return False

async def init_test(dut):
    """Initialize the DUT to a known state."""
    cocotb.start_soon(
        Clock(dut.HCLK, 10, unit="ns").start()
    )
    await reset_dut(dut)

# FIXME - this should be split into multiple tests so that we can reproduce one failure at a time.
@cocotb.test()
async def test_ahb_spi_m_reset(dut):
    log.info("\n========================================")
    log.info(" AHB SPI MASTER TEST")
    log.info("========================================")

    
    # --------------------------------------------------------
    # 1. RESET
    # --------------------------------------------------------

    await init_test(dut)
 
    # FIXME - there is no check here - we should actually read the registers and check they are reset to default values
    
    # FIXME - do NOT use print for logging - use cocotb.log.info() or cocotb.log.debug() instead
    # print("[PASS] Reset completed") # bad
    log.info("[PASS] Reset completed") # good


@cocotb.test()
async def test_reg_access(dut):
    await init_test(dut)
    
    # --------------------------------------------------------
    # 2. CTRL REGISTER
    # --------------------------------------------------------

    # FIXME - don't use all caps for non-constants - use lower case for local variables instead
    CPHA = 0
    CPOL = 0
    CLK_DIV = 4
    IE_DONE = 0
    IE_ERR = 0

    # ctrl_clk_div is bits [9:2]

    # FIXME - don't use 'magic numbers' - use the defined constants for the register bit fields instead
    # maybe use a function like ctrl_word() in test_uart to build the value instead of doing it manually here?
    ctrl_value = (4 << 2)

    await ahb_write(dut, CTRL, ctrl_value)
    ctrl_read = await ahb_read(dut, CTRL)
    print(f"CTRL = 0x{ctrl_read:08X}")

    assert (ctrl_read & 0x3FF) == ctrl_value, \
        f"CTRL mismatch: expected 0x{ctrl_value:08X}, got 0x{ctrl_read:08X}"

    print("[PASS] CTRL write/read")

    await ahb_write(dut, CTRL, ctrl_value)
    for _ in range(5):
        await RisingEdge(dut.HCLK)

    # --------------------------------------------------------
    # 3. ADDRESS REGISTER
    # --------------------------------------------------------

    test_addr = 0x12345678

    await ahb_write(dut, ADDR, test_addr)

    addr_read = await ahb_read(dut, ADDR)

    print(f"ADDR = 0x{addr_read:08X}")

    assert addr_read == test_addr, \
        f"ADDR mismatch: expected 0x{test_addr:08X}, got 0x{addr_read:08X}"

    print("[PASS] ADDR write/read")

    # --------------------------------------------------------
    # 4. STATUS REGISTER
    # --------------------------------------------------------

    status = await ahb_read(dut, STATUS)

    print(f"STATUS = 0x{status:08X}")

    # After reset SPI should not be busy.
    assert ((status >> 0) & 1) == 0, \
        "SPI unexpectedly busy after reset"

    print("[PASS] STATUS idle state")

  # --------------------------------------------------------
  # 6. CMD REGISTER
  # --------------------------------------------------------
    # FIXME - this should be handled in a function

    # CMD layout:
    
    # bit 0       START
    # bits 8:1    OPCODE
    # bit 9       CMD_EN
    # bit 10      ADDR_EN
    # bits 12:11  ADDR_BYTES
    # bit 13      DATA_EN
    # bit 14      DIR
    # bits 19:15  DUMMY
    # bits 27:20  LEN
    
    # Send:
    # opcode = 0x9A
    # command enabled
    # data enabled
    # write direction
    # length = 1 byte
    
    opcode = 0x9A

    cmd_value = (
        1                  |       # START
        (opcode << 1)     |
        (1 << 9)          |       # CMD_EN
        (0 << 10)         |       # ADDR_EN
        (0 << 11)         |
        (1 << 13)         |       # DATA_EN
        (0 << 14)         |       # WRITE
        (0 << 15)         |       # DUMMY
        (1 << 20)                 # LEN = 1
    )

    print(f"CMD = 0x{cmd_value:08X}")

    await ahb_write(dut, CMD, cmd_value)

    # FIXME - we aren't actually asserting anything here

    print("[PASS] CMD write")

@cocotb.test()
async def test_invalid_write(dut):
    await init_test(dut)
    
    # --------------------------------------------------------
    # 12. INVALID ACCESS
    # --------------------------------------------------------

    # address phase
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1
    dut.HTRANS.value = 2
    dut.HWRITE.value = 1
    dut.HADDR.value = STATUS
    dut.HSIZE.value = 2
    dut.HWDATA.value = 0x12345678

    await RisingEdge(dut.HCLK)

    # data phase — HRESP is valid here
    dut.HSEL.value = 0
    dut.HTRANS.value = 0
    dut.HWRITE.value = 0

    await Timer(1, unit="ns")

    assert int(dut.HRESP.value) == 1, \
        "Invalid STATUS write did not produce HRESP"

    await RisingEdge(dut.HCLK)

@cocotb.test()
async def test_fifo_write(dut):
    await init_test(dut)
    # --------------------------------------------------------
    # 5. TX FIFO DATA WRITE
    # --------------------------------------------------------

    tx_data = 0x000000A5

    await ahb_write(dut, DATA, tx_data)

    # FIXME - readback to actually CHECK that it worked?
    print("[PASS] DATA write")


@cocotb.test()
async def test_fifo_spi_write(dut):
    await init_test(dut)

    # TODO  - configure the SPI ctrl register
    # TODO  - write to the DATA register
    
    # --------------------------------------------------------
    # 7. CHECK SPI CS
    # --------------------------------------------------------

    cs_seen_low = False

    for _ in range(100):
        await Timer(10, unit="ns")

        if int(dut.SPI_CS_N.value) == 0:
            cs_seen_low = True
            break

    assert cs_seen_low, \
        "SPI_CS_N never went LOW"

    print("[PASS] SPI CS asserted")

    # --------------------------------------------------------
    # 8. CHECK SPI CLOCK
    # --------------------------------------------------------

    clock_toggled = await wait_for_spi_clock(dut)

    assert clock_toggled, \
        "SPI_SCK never toggled"

    print("[PASS] SPI clock toggled")

    # --------------------------------------------------------
    # 9. CHECK MOSI ACTIVITY
    # --------------------------------------------------------

    # FIXME - this test does not actually check the VALUE of the data coming out of MOSI

    mosi_values = []

    for _ in range(100):

        await Timer(5, unit="ns")

        mosi_values.append(int(dut.SPI_MOSI.value))

        # Stop once transaction finishes
        if int(dut.SPI_CS_N.value) == 1:
            break

    assert len(mosi_values) > 0, \
        "No MOSI activity observed"

    print(
        "[PASS] MOSI activity observed:",
        mosi_values
    )

    # --------------------------------------------------------
    # 10. WAIT FOR TRANSACTION TO FINISH
    # --------------------------------------------------------

    transaction_finished = False

    for _ in range(1000):

        await Timer(10, unit="ns")

        status = await ahb_read(dut, STATUS)

        busy = status & 1

        if busy == 0:
            transaction_finished = True
            break

    assert transaction_finished, \
        "SPI transaction did not finish"

    print("[PASS] SPI transaction finished")

    # --------------------------------------------------------
    # 11. CHECK INTERRUPT DONE
    # --------------------------------------------------------

    int_status = await ahb_read(dut, INT)

    print(f"INT = 0x{int_status:08X}")

    if int_status & 0x1:
        print("[PASS] DONE interrupt flag set")
    else:
        print("[INFO] DONE interrupt flag not set")

    # --------------------------------------------------------
    # FINISHED
    # --------------------------------------------------------

    log.info("\n========================================")
    log.info(" ALL AHB SPI MASTER TESTS COMPLETED")
    log.info("========================================\n")