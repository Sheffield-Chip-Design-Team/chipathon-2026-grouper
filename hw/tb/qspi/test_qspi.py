"""Directed tests for the reviewed AHB QSPI implementation."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, ValueChange
from cocotb.utils import get_sim_time

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_BYTE,
    HSIZE_HALF,
    HSIZE_WORD,
    HTRANS_IDLE,
    HTRANS_NONSEQ,
    ahb_read,
    ahb_write,
)

# Register map
REG_CTRL = 0x00
REG_CMD = 0x04
REG_STATUS = 0x08
REG_ADDR = 0x0C
REG_DATA = 0x10

# CTRL
CTRL_CPHA = 1 << 0
CTRL_CPOL = 1 << 1
CTRL_QUAD_MODE = 1 << 2
CTRL_FLASH_WRITE_EN = 1 << 3
CTRL_IE_DONE = 1 << 4
CTRL_IE_ERR = 1 << 5
CTRL_CLKDIV_SHIFT = 8

# CMD
CMD_START = 1 << 0
CMD_DIR = 1 << 1
CMD_ADDR_EN = 1 << 2
CMD_DATA_EN = 1 << 3
CMD_TARGET = 1 << 4
CMD_DUMMY_SHIFT = 8
CMD_OPCODE_SHIFT = 16

# STATUS
STATUS_BUSY = 1 << 0
STATUS_INIT_DONE = 1 << 1
STATUS_DONE = 1 << 2
STATUS_RX_VALID = 1 << 3
STATUS_CFG_ERR = 1 << 4
STATUS_WRITE_BLOCKED = 1 << 5
STATUS_ADDR_ERR = 1 << 6

HCLK_PERIOD_NS = 10


def make_cmd(opcode, *, start=False, read=False, addr_en=False, data_en=False, target=0, dummy=0):
    value = ((opcode & 0xFF) << CMD_OPCODE_SHIFT) | ((dummy & 0xFF) << CMD_DUMMY_SHIFT)
    if start:
        value |= CMD_START
    if read:
        value |= CMD_DIR
    if addr_en:
        value |= CMD_ADDR_EN
    if data_en:
        value |= CMD_DATA_EN
    if target:
        value |= CMD_TARGET
    return value


def ahb_word_to_wire(value):
    """Return the serial byte order for one little-endian 32-bit AHB word."""
    return int.from_bytes((value & 0xFFFFFFFF).to_bytes(4, "little"), "big")


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
    dut.HREADYIN.value = 1
    dut.HSEL.value = 0
    dut.HMEMSEL.value = 0
    dut.HMEMADDR.value = 0

    dut.qspi_sio_i.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)

    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def write_reg(dut, address, value, size=HSIZE_WORD, expected_hresp=0):
    hresp = await ahb_write(dut, address, value, size=size)
    assert hresp == expected_hresp
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def read_reg(dut, address, size=HSIZE_WORD, expected_hresp=0):
    value, hresp = await ahb_read(dut, address, size=size)
    assert hresp == expected_hresp
    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")
    return value

async def mapped_write(dut, address, value, size=HSIZE_WORD):
    await RisingEdge(dut.HCLK)

    dut.HADDR.value = address & 0xFFF
    dut.HMEMADDR.value = address
    dut.HSIZE.value = size
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 1
    dut.HWDATA.value = value
    dut.HSEL.value = 0
    dut.HMEMSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)

    dut.HTRANS.value = HTRANS_IDLE
    dut.HWRITE.value = 0
    dut.HMEMSEL.value = 0

    await Timer(1, unit="ps")

    saw_wait = int(dut.HREADYOUT.value) == 0

    while not int(dut.HREADYOUT.value):
        await RisingEdge(dut.HCLK)
        await Timer(1, unit="ps")

    hresp = int(dut.HRESP.value)

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    return hresp, saw_wait


async def mapped_read(dut, address, size=HSIZE_WORD):
    await RisingEdge(dut.HCLK)

    dut.HADDR.value = address & 0xFFF
    dut.HMEMADDR.value = address
    dut.HSIZE.value = size
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 0
    dut.HSEL.value = 0
    dut.HMEMSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)

    dut.HTRANS.value = HTRANS_IDLE
    dut.HMEMSEL.value = 0

    await Timer(1, unit="ps")

    saw_wait = int(dut.HREADYOUT.value) == 0

    while not int(dut.HREADYOUT.value):
        await RisingEdge(dut.HCLK)
        await Timer(1, unit="ps")

    value = int(dut.HRDATA.value)
    hresp = int(dut.HRESP.value)

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    return value, hresp, saw_wait

async def mapped_read_pair(dut, first_address, second_address):
    await RisingEdge(dut.HCLK)

    dut.HADDR.value = first_address & 0xFFF
    dut.HMEMADDR.value = first_address
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 0
    dut.HSEL.value = 0
    dut.HMEMSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)

    dut.HADDR.value = second_address & 0xFFF
    dut.HMEMADDR.value = second_address
    dut.HTRANS.value = HTRANS_NONSEQ

    await Timer(1, unit="ps")

    while not int(dut.HREADYOUT.value):
        await RisingEdge(dut.HCLK)
        await Timer(1, unit="ps")

    first_value = int(dut.HRDATA.value)

    await RisingEdge(dut.HCLK)

    dut.HTRANS.value = HTRANS_IDLE
    dut.HMEMSEL.value = 0

    await Timer(1, unit="ps")

    while not int(dut.HREADYOUT.value):
        await RisingEdge(dut.HCLK)
        await Timer(1, unit="ps")

    second_value = int(dut.HRDATA.value)

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    return first_value, second_value

async def mapped_write_pair(dut, first_address, first_value, second_address, second_value):
    await RisingEdge(dut.HCLK)

    dut.HADDR.value = first_address & 0xFFF
    dut.HMEMADDR.value = first_address
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 1
    dut.HWDATA.value = first_value
    dut.HSEL.value = 0
    dut.HMEMSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)

    dut.HADDR.value = second_address & 0xFFF
    dut.HMEMADDR.value = second_address
    dut.HTRANS.value = HTRANS_NONSEQ

    await Timer(1, unit="ps")

    while not int(dut.HREADYOUT.value):
        await RisingEdge(dut.HCLK)
        await Timer(1, unit="ps")

    await RisingEdge(dut.HCLK)

    dut.HWDATA.value = second_value
    dut.HTRANS.value = HTRANS_IDLE
    dut.HMEMSEL.value = 0

    await Timer(1, unit="ps")

    while not int(dut.HREADYOUT.value):
        await RisingEdge(dut.HCLK)
        await Timer(1, unit="ps")

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

async def wait_status(dut, mask, expected, max_reads=300):
    last = 0
    for _ in range(max_reads):
        last = await read_reg(dut, REG_STATUS)
        if (last & mask) == (expected & mask):
            return last

    raise AssertionError(
        f"STATUS timeout: mask=0x{mask:08x} expected=0x{expected:08x} last=0x{last:08x}"
    )


async def wait_ce(dut, value):
    while int(dut.qspi_ce_n_o.value) != value:
        await ValueChange(dut.qspi_ce_n_o)
    await Timer(1, unit="ps")


def groups_to_int(groups, width):
    value = 0
    mask = (1 << width) - 1
    for group in groups:
        value = (value << width) | (group & mask)
    return value


async def capture_tx_groups(dut, count, *, quad, ce_value, mode3=False):
    """Capture one transmitted command/address/data stream."""
    await wait_ce(dut, ce_value)
    groups = []

    for index in range(count):
        if mode3:
            await FallingEdge(dut.qspi_sck_o)
        else:
            await RisingEdge(dut.qspi_sck_o)

        await Timer(1, unit="ps")
        assert int(dut.qspi_ce_n_o.value) == ce_value

        if quad:
            assert int(dut.qspi_sio_oe.value) == 0b1111
            groups.append(int(dut.qspi_sio_o.value) & 0xF)
        else:
            assert int(dut.qspi_sio_oe.value) == 0b0001
            groups.append(int(dut.qspi_sio_o.value) & 0x1)

        if (not mode3) and (index != (count - 1)):
            await FallingEdge(dut.qspi_sck_o)

    return groups


async def respond_read(dut, *, opcode_groups, address_groups, dummy_cycles, response, quad, ce_value):
    """Capture a mode-0 command/address and drive one 32-bit read response."""
    await wait_ce(dut, ce_value)
    sent = []

    for _ in range(opcode_groups + address_groups):
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")

        if quad:
            assert int(dut.qspi_sio_oe.value) == 0b1111
            sent.append(int(dut.qspi_sio_o.value) & 0xF)
        else:
            assert int(dut.qspi_sio_oe.value) == 0b0001
            sent.append(int(dut.qspi_sio_o.value) & 0x1)

        await FallingEdge(dut.qspi_sck_o)

    # Dummy cycles: controller releases the SIO bus.
    for _ in range(dummy_cycles):
        assert int(dut.qspi_sio_oe.value) == 0
        await RisingEdge(dut.qspi_sck_o)
        await FallingEdge(dut.qspi_sck_o)

    response_bytes = (response & 0xFFFFFFFF).to_bytes(4, "little")
    if quad:
        response_groups = [group for byte in response_bytes for group in ((byte >> 4) & 0xF, byte & 0xF)]
    else:
        response_groups = [(byte >> bit) & 1 for byte in response_bytes for bit in range(7, -1, -1)]

    for index, group in enumerate(response_groups):
        dut.qspi_sio_i.value = group if quad else (group << 1)
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")
        assert int(dut.qspi_sio_oe.value) == 0

        if index != (len(response_groups) - 1):
            await FallingEdge(dut.qspi_sck_o)

    await wait_ce(dut, 0b11)
    return sent

async def respond_stream_read(dut, *, opcode_groups, address_groups, dummy_cycles, responses, quad, ce_value):
    await wait_ce(dut, ce_value)
    sent = []

    for _ in range(opcode_groups + address_groups):
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")

        if quad:
            assert int(dut.qspi_sio_oe.value) == 0b1111
            sent.append(int(dut.qspi_sio_o.value) & 0xF)
        else:
            assert int(dut.qspi_sio_oe.value) == 0b0001
            sent.append(int(dut.qspi_sio_o.value) & 0x1)

        await FallingEdge(dut.qspi_sck_o)

    for _ in range(dummy_cycles):
        assert int(dut.qspi_sio_oe.value) == 0
        await RisingEdge(dut.qspi_sck_o)
        await FallingEdge(dut.qspi_sck_o)

    for response in responses:
        response_bytes = (response & 0xFFFFFFFF).to_bytes(4, "little")

        if quad:
            response_groups = [group for byte in response_bytes for group in ((byte >> 4) & 0xF, byte & 0xF)]
        else:
            response_groups = [(byte >> bit) & 1 for byte in response_bytes for bit in range(7, -1, -1)]

        for index, group in enumerate(response_groups):
            dut.qspi_sio_i.value = group if quad else (group << 1)

            await RisingEdge(dut.qspi_sck_o)
            await Timer(1, unit="ps")

            assert int(dut.qspi_ce_n_o.value) == ce_value
            assert int(dut.qspi_sio_oe.value) == 0

            if index != (len(response_groups) - 1):
                await FallingEdge(dut.qspi_sck_o)

    await wait_ce(dut, 0b11)

    return sent


async def write_expect_two_cycle_error(dut, address, data, size=HSIZE_WORD):
    """Verify the required AHB-Lite two-cycle ERROR response."""
    await RisingEdge(dut.HCLK)

    dut.HADDR.value = address
    dut.HSIZE.value = size
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 1
    dut.HWDATA.value = data
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)

    dut.HTRANS.value = HTRANS_IDLE
    dut.HSEL.value = 0
    dut.HWRITE.value = 0

    await FallingEdge(dut.HCLK)
    first = (int(dut.HRESP.value), int(dut.HREADYOUT.value))
    dut.HREADYIN.value = int(dut.HREADYOUT.value)

    await RisingEdge(dut.HCLK)
    await FallingEdge(dut.HCLK)
    second = (int(dut.HRESP.value), int(dut.HREADYOUT.value))
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    assert first == (1, 0)
    assert second == (1, 1)


@cocotb.test()
async def test_register_map_sizes_and_ahb_error(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    assert await read_reg(dut, REG_CTRL) == 0
    assert await read_reg(dut, REG_CMD) == 0
    assert await read_reg(dut, REG_STATUS) == 0
    assert await read_reg(dut, REG_ADDR) == 0
    assert await read_reg(dut, REG_DATA) == 0

    # Existing register byte/halfword behaviour.
    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_IE_DONE | CTRL_IE_ERR, size=HSIZE_BYTE)
    await write_reg(dut, REG_CTRL + 1, 3 << 8, size=HSIZE_BYTE)
    await write_reg(dut, REG_CMD, CMD_ADDR_EN | CMD_DATA_EN, size=HSIZE_BYTE)
    await write_reg(dut, REG_CMD + 1, 4 << 8, size=HSIZE_BYTE)
    await write_reg(dut, REG_CMD + 2, 0xA6 << 16, size=HSIZE_BYTE)
    await write_reg(dut, REG_ADDR, 0x0000_BEEF, size=HSIZE_HALF)
    await write_reg(dut, REG_ADDR + 2, 0x12 << 16, size=HSIZE_BYTE)

    assert await read_reg(dut, REG_CTRL) == CTRL_QUAD_MODE | CTRL_IE_DONE | CTRL_IE_ERR | (3 << CTRL_CLKDIV_SHIFT)
    assert await read_reg(dut, REG_CMD) == (0xA6 << CMD_OPCODE_SHIFT) | (4 << CMD_DUMMY_SHIFT) | CMD_ADDR_EN | CMD_DATA_EN
    assert await read_reg(dut, REG_ADDR) == 0x12_BEEF

    # GRPR-QSPI-022: DATA is a complete 32-bit AHB register.
    await write_reg(dut, REG_DATA, 0x1122_3344)
    assert await read_reg(dut, REG_DATA) == 0x1122_3344

    # Byte access updates only the addressed byte lane.
    await write_reg(dut, REG_DATA + 1, 0x0000_AA00, size=HSIZE_BYTE)
    assert await read_reg(dut, REG_DATA) == 0x1122_AA44
    data_byte1 = await read_reg(dut, REG_DATA + 1, size=HSIZE_BYTE)
    assert ((data_byte1 >> 8) & 0xFF) == 0xAA

    # Halfword access updates only the addressed halfword lanes.
    await write_reg(dut, REG_DATA + 2, 0xBEEF_0000, size=HSIZE_HALF)
    assert await read_reg(dut, REG_DATA) == 0xBEEF_AA44
    data_half1 = await read_reg(dut, REG_DATA + 2, size=HSIZE_HALF)
    assert ((data_half1 >> 16) & 0xFFFF) == 0xBEEF

    # Existing byte and halfword reads remain legal.
    ctrl_byte1 = await read_reg(dut, REG_CTRL + 1, size=HSIZE_BYTE)
    assert ((ctrl_byte1 >> 8) & 0xFF) == 3
    addr_half = await read_reg(dut, REG_ADDR, size=HSIZE_HALF)
    assert (addr_half & 0xFFFF) == 0xBEEF

    # Existing AHB error behaviour remains unchanged.
    await write_expect_two_cycle_error(dut, 0x14, 0x1234_5678)
    await write_expect_two_cycle_error(dut, REG_CTRL + 1, 0, size=HSIZE_HALF)


@cocotb.test()
async def test_single_spi_bare_opcode_and_init_done(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, 1 << CTRL_CLKDIV_SHIFT)
    monitor = cocotb.start_soon(capture_tx_groups(dut, 8, quad=False, ce_value=0b10))
    await write_reg(dut, REG_CMD, make_cmd(0x35, start=True))

    bits = await monitor
    assert groups_to_int(bits, 1) == 0x35

    status = await wait_status(dut, STATUS_DONE | STATUS_INIT_DONE, STATUS_DONE | STATUS_INIT_DONE)
    assert not (status & STATUS_RX_VALID)

    # DONE is W1C. INIT_DONE is read-only.
    await write_reg(dut, REG_STATUS, STATUS_DONE)
    status = await read_reg(dut, REG_STATUS)
    assert not (status & STATUS_DONE)
    assert status & STATUS_INIT_DONE


@cocotb.test()
async def test_phase_enables(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | (1 << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_ADDR, 0x12_3456)
    await write_reg(dut, REG_DATA, 0x1122_3344)

    # Opcode + address, no DATA phase.
    monitor = cocotb.start_soon(capture_tx_groups(dut, 8, quad=True, ce_value=0b10))
    await write_reg(dut, REG_CMD, make_cmd(0xA1, start=True, addr_en=True))
    groups = await monitor
    assert groups_to_int(groups[:2], 4) == 0xA1
    assert groups_to_int(groups[2:], 4) == 0x12_3456

    await wait_status(dut, STATUS_DONE, STATUS_DONE)
    await write_reg(dut, REG_STATUS, STATUS_DONE)

    # Opcode + one complete 32-bit DATA word, no address phase.
    monitor = cocotb.start_soon(capture_tx_groups(dut, 10, quad=True, ce_value=0b10))
    await write_reg(dut, REG_CMD, make_cmd(0xB2, start=True, data_en=True))
    groups = await monitor
    assert groups_to_int(groups[:2], 4) == 0xB2
    assert groups_to_int(groups[2:], 4) == ahb_word_to_wire(0x1122_3344)

    await wait_status(dut, STATUS_DONE, STATUS_DONE)


@cocotb.test()
async def test_quad_read_with_dummy_mode0(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_IE_DONE | (1 << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_ADDR, 0x12_3456)
    await write_reg(dut, REG_DATA, 0xDEAD_BEEF)

    responder = cocotb.start_soon(
        respond_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=3,
            response=0x1234_5678,
            quad=True,
            ce_value=0b10,
        )
    )
    await write_reg(dut, REG_CMD, make_cmd(0xEB, start=True, read=True, addr_en=True, data_en=True, dummy=3))

    sent = await responder
    assert groups_to_int(sent[:2], 4) == 0xEB
    assert groups_to_int(sent[2:], 4) == 0x12_3456

    await wait_status(dut, STATUS_DONE | STATUS_RX_VALID, STATUS_DONE | STATUS_RX_VALID)
    assert await read_reg(dut, REG_DATA) == 0x1234_5678
    assert int(dut.irq.value) == 1

    await write_reg(dut, REG_STATUS, STATUS_DONE | STATUS_RX_VALID)
    assert int(dut.irq.value) == 0


@cocotb.test()
async def test_single_spi_read_and_mode3_quad_write(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    # Single-bit SPI 32-bit read, mode 0.
    await write_reg(dut, REG_CTRL, 1 << CTRL_CLKDIV_SHIFT)
    responder = cocotb.start_soon(
        respond_read(
            dut,
            opcode_groups=8,
            address_groups=0,
            dummy_cycles=0,
            response=0xA1B2_C3D4,
            quad=False,
            ce_value=0b10,
        )
    )
    await write_reg(dut, REG_CMD, make_cmd(0x9F, start=True, read=True, data_en=True))

    sent = await responder
    assert groups_to_int(sent, 1) == 0x9F
    await wait_status(dut, STATUS_DONE | STATUS_RX_VALID, STATUS_DONE | STATUS_RX_VALID)
    assert await read_reg(dut, REG_DATA) == 0xA1B2_C3D4
    await write_reg(dut, REG_STATUS, STATUS_DONE | STATUS_RX_VALID)

    # Mode 3 + quad 32-bit write.
    ctrl = CTRL_CPHA | CTRL_CPOL | CTRL_QUAD_MODE | CTRL_IE_DONE | (1 << CTRL_CLKDIV_SHIFT)
    await write_reg(dut, REG_CTRL, ctrl)
    assert int(dut.qspi_sck_o.value) == 1

    await write_reg(dut, REG_ADDR, 0x01_2345)
    await write_reg(dut, REG_DATA, 0x89AB_CDEF)

    monitor = cocotb.start_soon(capture_tx_groups(dut, 16, quad=True, ce_value=0b10, mode3=True))
    await write_reg(dut, REG_CMD, make_cmd(0xA5, start=True, addr_en=True, data_en=True))
    groups = await monitor

    assert groups_to_int(groups[:2], 4) == 0xA5
    assert groups_to_int(groups[2:8], 4) == 0x01_2345
    assert groups_to_int(groups[8:], 4) == ahb_word_to_wire(0x89AB_CDEF)

    status = await wait_status(dut, STATUS_DONE, STATUS_DONE)
    assert not (status & STATUS_RX_VALID)
    assert int(dut.irq.value) == 1

    await write_reg(dut, REG_STATUS, STATUS_DONE)
    assert int(dut.irq.value) == 0


@cocotb.test()
async def test_busy_cfg_error_and_w1c(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    original_ctrl = CTRL_IE_ERR | (2 << CTRL_CLKDIV_SHIFT)
    await write_reg(dut, REG_CTRL, original_ctrl)
    await write_reg(dut, REG_CMD, make_cmd(0x03, start=True, read=True, data_en=True, dummy=20))
    await wait_status(dut, STATUS_BUSY, STATUS_BUSY)

    # CTRL write while BUSY is ignored.
    await write_reg(dut, REG_CTRL, CTRL_CPHA | CTRL_CPOL | CTRL_IE_ERR | (7 << CTRL_CLKDIV_SHIFT))

    # START while BUSY is rejected.
    await write_reg(dut, REG_CMD, make_cmd(0x99, start=True))

    status = await read_reg(dut, REG_STATUS)
    assert status & STATUS_CFG_ERR
    assert int(dut.irq.value) == 1
    assert await read_reg(dut, REG_CTRL) == original_ctrl

    await write_reg(dut, REG_STATUS, STATUS_CFG_ERR)
    status = await read_reg(dut, REG_STATUS)
    assert not (status & STATUS_CFG_ERR)
    assert int(dut.irq.value) == 0

    await wait_status(dut, STATUS_DONE, STATUS_DONE)


@cocotb.test()
async def test_flash_write_protection_and_two_cycle_error(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_IE_ERR)
    await write_reg(dut, REG_DATA, 0x5566_7788)

    blocked_cmd = make_cmd(0x02, start=True, data_en=True, target=1)
    await write_expect_two_cycle_error(dut, REG_CMD, blocked_cmd)

    status = await read_reg(dut, REG_STATUS)
    assert not (status & STATUS_BUSY)
    assert status & STATUS_WRITE_BLOCKED
    assert int(dut.irq.value) == 1

    await write_reg(dut, REG_STATUS, STATUS_WRITE_BLOCKED)
    assert int(dut.irq.value) == 0

    # Enable NOR writes and retry.
    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_FLASH_WRITE_EN)
    monitor = cocotb.start_soon(capture_tx_groups(dut, 10, quad=True, ce_value=0b01))
    await write_reg(dut, REG_CMD, blocked_cmd)

    groups = await monitor
    assert groups_to_int(groups[:2], 4) == 0x02
    assert groups_to_int(groups[2:], 4) == ahb_word_to_wire(0x5566_7788)

    await wait_status(dut, STATUS_DONE, STATUS_DONE)


@cocotb.test()
async def test_address_error_and_invalid_spi_mode(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_IE_ERR)
    await write_reg(dut, REG_ADDR, 0x80_0000)
    await write_reg(dut, REG_CMD, make_cmd(0x03, start=True, addr_en=True))

    status = await read_reg(dut, REG_STATUS)
    assert not (status & STATUS_BUSY)
    assert status & STATUS_ADDR_ERR
    assert int(dut.irq.value) == 1

    await write_reg(dut, REG_STATUS, STATUS_ADDR_ERR)

    # CPHA != CPOL is neither mode 0 nor mode 3.
    await write_reg(dut, REG_CTRL, CTRL_CPHA | CTRL_IE_ERR)
    await write_reg(dut, REG_ADDR, 0x01_0000)
    await write_reg(dut, REG_CMD, make_cmd(0x66, start=True))

    status = await read_reg(dut, REG_STATUS)
    assert not (status & STATUS_BUSY)
    assert status & STATUS_CFG_ERR
    assert int(dut.irq.value) == 1

    await write_reg(dut, REG_STATUS, STATUS_CFG_ERR)
    assert int(dut.irq.value) == 0


@cocotb.test()
async def test_minimum_cs_high_interval(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    clkdiv = 1
    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_IE_DONE | (clkdiv << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_CMD, make_cmd(0x66))
    await write_reg(dut, REG_CMD, make_cmd(0x66, start=True))

    await wait_ce(dut, 0b10)
    await wait_ce(dut, 0b11)
    ce_high_time = int(get_sim_time(unit="ns"))

    await RisingEdge(dut.irq)
    done_time = int(get_sim_time(unit="ns"))
    minimum_expected = 2 * (clkdiv + 1) * HCLK_PERIOD_NS

    assert (done_time - ce_high_time) >= minimum_expected

@cocotb.test()
async def test_memory_mapped_psram_read_write(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | (1 << CTRL_CLKDIV_SHIFT))

    # TARGET=0 selects PSRAM. DUMMY=2 is used here only to make the
    # read dummy phase directly observable in the directed test.
    await write_reg(dut, REG_CMD, make_cmd(0x00, dummy=2))

    address = 0x001234
    write_data = 0x11223344

    monitor = cocotb.start_soon(capture_tx_groups(dut, 16, quad=True, ce_value=0b10))

    hresp, saw_wait = await mapped_write(dut, address, write_data)

    groups = await monitor

    assert saw_wait
    assert hresp == 0
    assert groups_to_int(groups[:2], 4) == 0x02
    assert groups_to_int(groups[2:8], 4) == address
    assert groups_to_int(groups[8:], 4) == ahb_word_to_wire(write_data)

    read_address = 0x001238
    response = 0xA1B2C3D4

    await write_reg(dut, REG_DATA, 0x12345678)

    responder = cocotb.start_soon(
        respond_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=2,
            response=response,
            quad=True,
            ce_value=0b10,
        )
    )

    value, hresp, saw_wait = await mapped_read(dut, read_address)

    sent = await responder

    assert saw_wait
    assert hresp == 0
    assert groups_to_int(sent[:2], 4) == 0xEB
    assert groups_to_int(sent[2:], 4) == read_address
    assert value == response
    assert await read_reg(dut, REG_DATA) == 0x12345678

@cocotb.test()
async def test_memory_mapped_nor_read_and_write_rejection(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_IE_ERR | (1 << CTRL_CLKDIV_SHIFT))

    # TARGET=1 selects NOR.
    await write_reg(dut, REG_CMD, make_cmd(0x00, target=1, dummy=3))

    address = 0x002000
    response = 0x55667788

    responder = cocotb.start_soon(
        respond_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=3,
            response=response,
            quad=True,
            ce_value=0b01,
        )
    )

    value, hresp, saw_wait = await mapped_read(dut, address)

    sent = await responder

    assert saw_wait
    assert hresp == 0
    assert groups_to_int(sent[:2], 4) == 0xEB
    assert groups_to_int(sent[2:], 4) == address
    assert value == response

    # NOR writes are not supported through the mapped path.
    hresp, saw_wait = await mapped_write(dut, address, 0xDEADBEEF)

    assert saw_wait
    assert hresp == 1
    assert int(dut.qspi_ce_n_o.value) == 0b11

    status = await read_reg(dut, REG_STATUS)

    assert status & STATUS_WRITE_BLOCKED
    assert int(dut.irq.value) == 1

    await write_reg(dut, REG_STATUS, STATUS_WRITE_BLOCKED)

    assert int(dut.irq.value) == 0

@cocotb.test()
async def test_memory_mapped_nor_address_limit(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | CTRL_IE_ERR)
    await write_reg(dut, REG_CMD, make_cmd(0x00, target=1))

    value, hresp, saw_wait = await mapped_read(dut, 0x400000)

    assert saw_wait
    assert hresp == 1
    assert value == 0
    assert int(dut.qspi_ce_n_o.value) == 0b11

    status = await read_reg(dut, REG_STATUS)

    assert status & STATUS_ADDR_ERR

@cocotb.test()
async def test_memory_mapped_psram_sequential_reads_stream(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | (1 << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_CMD, make_cmd(0x00, dummy=2))

    first_address = 0x001200
    second_address = first_address + 4

    responder = cocotb.start_soon(
        respond_stream_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=2,
            responses=[0x11223344, 0x55667788],
            quad=True,
            ce_value=0b10,
        )
    )

    first_value, second_value = await mapped_read_pair(dut, first_address, second_address)
    sent = await responder

    assert groups_to_int(sent[:2], 4) == 0xEB
    assert groups_to_int(sent[2:], 4) == first_address
    assert first_value == 0x11223344
    assert second_value == 0x55667788

@cocotb.test()
async def test_memory_mapped_psram_sequential_writes_stream(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | (1 << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_CMD, make_cmd(0x00))

    first_address = 0x002000
    second_address = first_address + 4
    first_value = 0x12345678
    second_value = 0xA1B2C3D4

    monitor = cocotb.start_soon(capture_tx_groups(dut, 24, quad=True, ce_value=0b10))

    await mapped_write_pair(dut, first_address, first_value, second_address, second_value)

    groups = await monitor

    assert groups_to_int(groups[:2], 4) == 0x02
    assert groups_to_int(groups[2:8], 4) == first_address
    assert groups_to_int(groups[8:16], 4) == ahb_word_to_wire(first_value)
    assert groups_to_int(groups[16:24], 4) == ahb_word_to_wire(second_value)

    await wait_ce(dut, 0b11)

@cocotb.test()
async def test_memory_mapped_nor_sequential_reads_stream(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | (1 << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_CMD, make_cmd(0x00, target=1, dummy=3))

    first_address = 0x003000
    second_address = first_address + 4

    responder = cocotb.start_soon(
        respond_stream_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=3,
            responses=[0x89ABCDEF, 0x10203040],
            quad=True,
            ce_value=0b01,
        )
    )

    first_value, second_value = await mapped_read_pair(dut, first_address, second_address)
    sent = await responder

    assert groups_to_int(sent[:2], 4) == 0xEB
    assert groups_to_int(sent[2:], 4) == first_address
    assert first_value == 0x89ABCDEF
    assert second_value == 0x10203040

@cocotb.test()
async def test_memory_mapped_nonsequential_read_restarts(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    await write_reg(dut, REG_CTRL, CTRL_QUAD_MODE | (1 << CTRL_CLKDIV_SHIFT))
    await write_reg(dut, REG_CMD, make_cmd(0x00, dummy=2))

    first_address = 0x001000
    second_address = 0x002000

    async def respond_two_transactions():
        first_sent = await respond_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=2,
            response=0x11112222,
            quad=True,
            ce_value=0b10,
        )

        second_sent = await respond_read(
            dut,
            opcode_groups=2,
            address_groups=6,
            dummy_cycles=2,
            response=0x33334444,
            quad=True,
            ce_value=0b10,
        )

        return first_sent, second_sent

    responder = cocotb.start_soon(respond_two_transactions())

    first_value, second_value = await mapped_read_pair(dut, first_address, second_address)
    first_sent, second_sent = await responder

    assert groups_to_int(first_sent[:2], 4) == 0xEB
    assert groups_to_int(first_sent[2:], 4) == first_address
    assert groups_to_int(second_sent[:2], 4) == 0xEB
    assert groups_to_int(second_sent[2:], 4) == second_address
    assert first_value == 0x11112222
    assert second_value == 0x33334444