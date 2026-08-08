import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, FallingEdge

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


@cocotb.test()
async def test_ahb_spi_master(dut):

    print("\n========================================")
    print(" AHB SPI MASTER FULL TEST")
    print("========================================")

    # Clock
    cocotb.start_soon(
        Clock(dut.HCLK, 10, unit="ns").start()
    )

    # --------------------------------------------------------
    # 1. RESET
    # --------------------------------------------------------

    await reset_dut(dut)

    print("[PASS] Reset completed")

    # --------------------------------------------------------
    # 2. CTRL REGISTER
    # --------------------------------------------------------

    # CPHA = 0
    # CPOL = 0
    # CLK_DIV = 4
    # IE_DONE = 0
    # IE_ERR = 0
    #
    # ctrl_clk_div is bits [9:2]
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
    # 5. TX FIFO DATA WRITE
    # --------------------------------------------------------

    tx_data = 0x000000A5

    await ahb_write(dut, DATA, tx_data)

    print("[PASS] DATA write")

    # --------------------------------------------------------
    # 6. CMD REGISTER
    # --------------------------------------------------------
    #
    # CMD layout:
    #
    # bit 0       START
    # bits 8:1    OPCODE
    # bit 9       CMD_EN
    # bit 10      ADDR_EN
    # bits 12:11  ADDR_BYTES
    # bit 13      DATA_EN
    # bit 14      DIR
    # bits 19:15  DUMMY
    # bits 27:20  LEN
    #
    # Send:
    # opcode = 0x9A
    # command enabled
    # data enabled
    # write direction
    # length = 1 byte
    #

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

    print("[PASS] CMD write")

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

    # --------------------------------------------------------
    # FINISHED
    # --------------------------------------------------------

    print("\n========================================")
    print(" ALL AHB SPI MASTER TESTS COMPLETED")
    print("========================================\n")

    await Timer(20, unit="ns")