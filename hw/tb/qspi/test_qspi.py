"""Directed cocotb tests for the AHB-wrapped QSPI register shell.

These tests verify only the functionality currently implemented in
hw/rtl/qspi/ahb_qspi.sv. The external QSPI transaction engine is not yet
implemented, so serial command, clock and data-transfer behaviour is outside
this testbench's present scope.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_WORD,
    HTRANS_IDLE,
    ahb_read,
    ahb_write,
)


# -----------------------------------------------------------------------------
# Register offsets
# -----------------------------------------------------------------------------

ADDR_CTRL = 0x00
ADDR_CMD = 0x04
ADDR_STATUS = 0x08
ADDR_ADDR = 0x0C
ADDR_DATA = 0x10


# -----------------------------------------------------------------------------
# AHB constants
# -----------------------------------------------------------------------------

HSIZE_BYTE = 0b000
HSIZE_HALFWORD = 0b001

HTRANS_BUSY = 0b01
HTRANS_NONSEQ = 0b10


# -----------------------------------------------------------------------------
# CTRL fields
# -----------------------------------------------------------------------------

CTRL_CPHA = 1 << 0
CTRL_CPOL = 1 << 1
CTRL_QUAD_MODE = 1 << 2
CTRL_FLASH_WRITE_EN = 1 << 3
CTRL_IE_DONE = 1 << 4
CTRL_IE_ERR = 1 << 5

CTRL_CLKDIV_SHIFT = 8
CTRL_CLKDIV_MASK = 0xFF << CTRL_CLKDIV_SHIFT

CTRL_IMPLEMENTED_MASK = (
    CTRL_CPHA
    | CTRL_CPOL
    | CTRL_QUAD_MODE
    | CTRL_FLASH_WRITE_EN
    | CTRL_IE_DONE
    | CTRL_IE_ERR
    | CTRL_CLKDIV_MASK
)


# -----------------------------------------------------------------------------
# CMD fields
# -----------------------------------------------------------------------------

CMD_START = 1 << 0
CMD_DIR = 1 << 1
CMD_ADDR_EN = 1 << 2
CMD_DATA_EN = 1 << 3
CMD_TARGET = 1 << 4
CMD_FAST_TXN_EN = 1 << 5

CMD_DUMMY_SHIFT = 8
CMD_DUMMY_MASK = 0xFF << CMD_DUMMY_SHIFT

# START is an action and always reads as zero.
CMD_STORED_MASK = (
    CMD_DIR
    | CMD_ADDR_EN
    | CMD_DATA_EN
    | CMD_TARGET
    | CMD_FAST_TXN_EN
    | CMD_DUMMY_MASK
)


# -----------------------------------------------------------------------------
# STATUS fields
# -----------------------------------------------------------------------------

STATUS_BUSY = 1 << 0
STATUS_INIT_DONE = 1 << 1
STATUS_DONE = 1 << 2
STATUS_RX_VALID = 1 << 3
STATUS_CFG_ERR = 1 << 4
STATUS_WRITE_BLOCKED = 1 << 5
STATUS_ADDR_ERR = 1 << 6

STATUS_W1C_MASK = (
    STATUS_DONE
    | STATUS_RX_VALID
    | STATUS_CFG_ERR
    | STATUS_WRITE_BLOCKED
    | STATUS_ADDR_ERR
)

STATUS_IMPLEMENTED_MASK = (
    STATUS_BUSY
    | STATUS_INIT_DONE
    | STATUS_W1C_MASK
)


# -----------------------------------------------------------------------------
# Other implemented widths
# -----------------------------------------------------------------------------

ADDR_IMPLEMENTED_MASK = 0x00FF_FFFF
DATA_IMPLEMENTED_MASK = 0x0000_00FF

CLK_PERIOD_NS = 10


async def reset_dut(dut):
    """Reset the DUT and place every input in a known idle state."""

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

    dut.qspi_sio_i.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)

    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def write_word(dut, address, data, expected_hresp=0):
    """Perform a normal aligned 32-bit AHB write."""

    hresp = await ahb_write(
        dut,
        address,
        data,
    )

    assert hresp == expected_hresp, (
        f"write to 0x{address:03x}: expected HRESP={expected_hresp}, "
        f"got HRESP={hresp}"
    )

    # ahb_qspi pipelines the address/control phase and consumes HWDATA on the
    # following edge. Wait for that edge so this helper is self-contained.
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def read_word(dut, address, expected_hresp=0):
    """Perform a normal aligned 32-bit AHB read."""

    data, hresp = await ahb_read(
        dut,
        address,
    )

    assert hresp == expected_hresp, (
        f"read from 0x{address:03x}: expected HRESP={expected_hresp}, "
        f"got HRESP={hresp}"
    )

    # Clear the registered read phase before returning.
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    return data


async def raw_ahb_access(
    dut,
    address,
    *,
    is_write,
    data=0,
    size=HSIZE_WORD,
    trans=HTRANS_NONSEQ,
):
    """Drive an AHB access with explicit size and transfer type.

    This is used for byte-lane, alignment, unsupported-size and HTRANS=BUSY
    tests that the shared word-only helpers do not express.
    """

    await RisingEdge(dut.HCLK)

    dut.HADDR.value = address
    dut.HSIZE.value = size
    dut.HTRANS.value = trans
    dut.HWRITE.value = int(is_write)
    dut.HWDATA.value = data
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    hreadyout = int(dut.HREADYOUT.value)
    hresp = int(dut.HRESP.value)
    read_data = int(dut.HRDATA.value) & 0xFFFF_FFFF

    dut.HTRANS.value = HTRANS_IDLE
    dut.HSEL.value = 0
    dut.HWRITE.value = 0

    # Allow a valid write's registered data phase to complete and clear the
    # pipelined access controls before the next transfer.
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    return read_data, hresp, hreadyout


async def write_byte(dut, register_offset, byte_index, value):
    """Write one byte into a selected 32-bit register lane."""

    assert 0 <= byte_index <= 3

    address = register_offset + byte_index
    lane_data = (value & 0xFF) << (8 * byte_index)

    _, hresp, hreadyout = await raw_ahb_access(
        dut,
        address,
        is_write=True,
        data=lane_data,
        size=HSIZE_BYTE,
    )

    assert hreadyout == 1
    assert hresp == 0, (
        f"byte write to 0x{address:03x} returned HRESP=ERROR"
    )


async def read_byte(dut, register_offset, byte_index):
    """Read one byte lane from a register."""

    assert 0 <= byte_index <= 3

    address = register_offset + byte_index

    data, hresp, hreadyout = await raw_ahb_access(
        dut,
        address,
        is_write=False,
        size=HSIZE_BYTE,
    )

    assert hreadyout == 1
    assert hresp == 0, (
        f"byte read from 0x{address:03x} returned HRESP=ERROR"
    )

    return (data >> (8 * byte_index)) & 0xFF


@cocotb.test()
async def test_qspi_reset_and_full_word_registers(dut):
    """Check reset values, full-word storage and reserved-bit behaviour."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            CLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    assert await read_word(dut, ADDR_CTRL) == 0
    assert await read_word(dut, ADDR_CMD) == 0
    assert await read_word(dut, ADDR_STATUS) == 0
    assert await read_word(dut, ADDR_ADDR) == 0
    assert await read_word(dut, ADDR_DATA) == 0

    assert int(dut.qspi_sck_o.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b11
    assert int(dut.qspi_sio_o.value) == 0
    assert int(dut.qspi_sio_oe.value) == 0
    assert int(dut.irq.value) == 0

    ctrl_value = (
        CTRL_CPHA
        | CTRL_QUAD_MODE
        | (0x3C << CTRL_CLKDIV_SHIFT)
    )

    await write_word(
        dut,
        ADDR_CTRL,
        ctrl_value,
    )

    assert await read_word(dut, ADDR_CTRL) == ctrl_value

    # Only implemented CTRL fields may persist.
    await write_word(
        dut,
        ADDR_CTRL,
        0xFFFF_FFFF,
    )

    assert await read_word(
        dut,
        ADDR_CTRL,
    ) == CTRL_IMPLEMENTED_MASK

    # CPOL was written high, so inactive SCK must idle high.
    assert int(dut.qspi_sck_o.value) == 1
    assert int(dut.qspi_ce_n_o.value) == 0b11
    assert int(dut.qspi_sio_oe.value) == 0

    # Keep START clear while writing all stored CMD and reserved bits high.
    await write_word(
        dut,
        ADDR_CMD,
        0xFFFF_FF3E,
    )

    assert await read_word(
        dut,
        ADDR_CMD,
    ) == CMD_STORED_MASK

    await write_word(
        dut,
        ADDR_ADDR,
        0xFFFF_FFFF,
    )

    assert await read_word(
        dut,
        ADDR_ADDR,
    ) == ADDR_IMPLEMENTED_MASK

    await write_word(
        dut,
        ADDR_DATA,
        0xFFFF_FFA5,
    )

    assert await read_word(
        dut,
        ADDR_DATA,
    ) == 0xA5

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert status & ~STATUS_IMPLEMENTED_MASK == 0


@cocotb.test()
async def test_qspi_byte_lane_registers(dut):
    """Check byte-aligned fields and reserved byte lanes."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            CLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    # CTRL byte 0 contains control fields; byte 1 contains CLKDIV.
    await write_byte(dut, ADDR_CTRL, 0, 0x2D)
    await write_byte(dut, ADDR_CTRL, 1, 0xA6)
    await write_byte(dut, ADDR_CTRL, 2, 0xFF)
    await write_byte(dut, ADDR_CTRL, 3, 0xFF)

    assert await read_word(
        dut,
        ADDR_CTRL,
    ) == 0x0000_A62D

    assert await read_byte(dut, ADDR_CTRL, 0) == 0x2D
    assert await read_byte(dut, ADDR_CTRL, 1) == 0xA6
    assert await read_byte(dut, ADDR_CTRL, 2) == 0
    assert await read_byte(dut, ADDR_CTRL, 3) == 0

    # CMD byte 0 contains the descriptor. DUMMY occupies byte 1.
    await write_byte(dut, ADDR_CMD, 0, 0x3E)
    await write_byte(dut, ADDR_CMD, 1, 0x5A)
    await write_byte(dut, ADDR_CMD, 2, 0xFF)
    await write_byte(dut, ADDR_CMD, 3, 0xFF)

    assert await read_word(
        dut,
        ADDR_CMD,
    ) == 0x0000_5A3E

    # ADDR contains exactly three implemented bytes.
    await write_byte(dut, ADDR_ADDR, 0, 0x11)
    await write_byte(dut, ADDR_ADDR, 1, 0x22)
    await write_byte(dut, ADDR_ADDR, 2, 0x33)
    await write_byte(dut, ADDR_ADDR, 3, 0xFF)

    assert await read_word(
        dut,
        ADDR_ADDR,
    ) == 0x0033_2211

    # DATA implements only byte lane zero.
    await write_byte(dut, ADDR_DATA, 0, 0xC7)
    await write_byte(dut, ADDR_DATA, 1, 0xFF)

    assert await read_word(
        dut,
        ADDR_DATA,
    ) == (0xC7 & DATA_IMPLEMENTED_MASK)


@cocotb.test()
async def test_qspi_start_errors_w1c_and_irq(dut):
    """Check START semantics, protection, address errors, W1C and IRQ."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            CLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    # Valid PSRAM read request.
    await write_word(
        dut,
        ADDR_ADDR,
        0x0012_3456,
    )

    valid_psram_read = (
        CMD_START
        | CMD_DIR
        | CMD_ADDR_EN
        | CMD_DATA_EN
        | CMD_FAST_TXN_EN
        | (0x04 << CMD_DUMMY_SHIFT)
    )

    await write_word(
        dut,
        ADDR_CMD,
        valid_psram_read,
    )

    assert await read_word(
        dut,
        ADDR_CMD,
    ) == (valid_psram_read & CMD_STORED_MASK)

    assert await read_word(
        dut,
        ADDR_STATUS,
    ) == 0

    # Enable error IRQs but leave flash writes disabled.
    await reset_dut(dut)

    await write_word(
        dut,
        ADDR_CTRL,
        CTRL_IE_ERR,
    )

    # One byte beyond the 4 MB NOR range.
    await write_word(
        dut,
        ADDR_ADDR,
        0x0040_0000,
    )

    invalid_nor_write = (
        CMD_START
        | CMD_ADDR_EN
        | CMD_DATA_EN
        | CMD_TARGET
    )

    await write_word(
        dut,
        ADDR_CMD,
        invalid_nor_write,
    )

    expected_errors = (
        STATUS_WRITE_BLOCKED
        | STATUS_ADDR_ERR
    )

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert status & STATUS_W1C_MASK == expected_errors
    assert int(dut.irq.value) == 1

    # Clear only WRITE_BLOCKED. ADDR_ERR must remain.
    await write_word(
        dut,
        ADDR_STATUS,
        STATUS_WRITE_BLOCKED,
    )

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert status & STATUS_W1C_MASK == STATUS_ADDR_ERR
    assert int(dut.irq.value) == 1

    await write_word(
        dut,
        ADDR_STATUS,
        STATUS_ADDR_ERR,
    )

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert status & STATUS_W1C_MASK == 0
    assert int(dut.irq.value) == 0

    # Enabled write at the highest valid NOR address.
    await write_word(
        dut,
        ADDR_CTRL,
        CTRL_IE_ERR | CTRL_FLASH_WRITE_EN,
    )

    await write_word(
        dut,
        ADDR_ADDR,
        0x003F_FFFF,
    )

    await write_word(
        dut,
        ADDR_CMD,
        invalid_nor_write,
    )

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert status & STATUS_W1C_MASK == 0
    assert int(dut.irq.value) == 0

    # PSRAM address bit 23 is outside its 8 MB range.
    await write_word(
        dut,
        ADDR_CTRL,
        CTRL_IE_ERR,
    )

    await write_word(
        dut,
        ADDR_ADDR,
        0x0080_0000,
    )

    psram_read = (
        CMD_START
        | CMD_DIR
        | CMD_ADDR_EN
    )

    await write_word(
        dut,
        ADDR_CMD,
        psram_read,
    )

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert status & STATUS_ADDR_ERR
    assert int(dut.irq.value) == 1

    await write_word(
        dut,
        ADDR_STATUS,
        STATUS_ADDR_ERR,
    )

    # Highest valid PSRAM address.
    await write_word(
        dut,
        ADDR_ADDR,
        0x007F_FFFF,
    )

    await write_word(
        dut,
        ADDR_CMD,
        psram_read,
    )

    status = await read_word(
        dut,
        ADDR_STATUS,
    )

    assert not (status & STATUS_ADDR_ERR)
    assert int(dut.irq.value) == 0


@cocotb.test()
async def test_qspi_invalid_ahb_accesses(dut):
    """Check invalid offsets, alignment, sizes and HTRANS=BUSY."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            CLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    await write_word(
        dut,
        ADDR_CTRL,
        CTRL_CPHA,
    )

    # First unimplemented word after DATA.
    await write_word(
        dut,
        0x14,
        0xFFFF_FFFF,
        expected_hresp=1,
    )

    assert await read_word(
        dut,
        ADDR_CTRL,
    ) == CTRL_CPHA

    # Higher offset with identical low register-index bits must not alias.
    invalid_data = await read_word(
        dut,
        0x20,
        expected_hresp=1,
    )

    assert invalid_data == 0

    # Misaligned halfword.
    _, hresp, hreadyout = await raw_ahb_access(
        dut,
        ADDR_CTRL + 1,
        is_write=False,
        size=HSIZE_HALFWORD,
    )

    assert hreadyout == 1
    assert hresp == 1

    # Misaligned word.
    _, hresp, hreadyout = await raw_ahb_access(
        dut,
        ADDR_CTRL + 2,
        is_write=True,
        data=0,
        size=HSIZE_WORD,
    )

    assert hreadyout == 1
    assert hresp == 1

    # Unsupported 64-bit transfer size on a 32-bit register bus.
    _, hresp, hreadyout = await raw_ahb_access(
        dut,
        ADDR_CTRL,
        is_write=False,
        size=0b011,
    )

    assert hreadyout == 1
    assert hresp == 1

    # BUSY is not a valid transfer and must neither error nor write.
    _, hresp, hreadyout = await raw_ahb_access(
        dut,
        ADDR_CTRL,
        is_write=True,
        data=0,
        trans=HTRANS_BUSY,
    )

    assert hreadyout == 1
    assert hresp == 0

    assert await read_word(
        dut,
        ADDR_CTRL,
    ) == CTRL_CPHA