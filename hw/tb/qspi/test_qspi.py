"""Tests for the arbitrary-command quad QSPI controller.

The controller supports:

- aligned 32-bit AHB accesses;
- an arbitrary 8-bit opcode;
- an arbitrary 24-bit address;
- one-byte quad read or write;
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, ValueChange

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_WORD,
    HTRANS_IDLE,
    ahb_read,
    ahb_write,
)


# Register offsets
REG_CTRL = 0x00
REG_STATUS = 0x04
REG_OPCODE = 0x08
REG_ADDRESS = 0x0C
REG_DATA = 0x10

# CTRL fields
CTRL_START = 1 << 0
CTRL_DIR = 1 << 1
CTRL_TARGET = 1 << 2
CTRL_CLKDIV_SHIFT = 8

# STATUS fields
STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1
STATUS_RX_VALID = 1 << 2

HCLK_PERIOD_NS = 10


async def reset_dut(dut):
    """Reset the controller and initialise all external inputs."""

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

    dut.qspi_sio_i.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)

    dut.HRESETn.value = 1

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def write_register(
    dut,
    address,
    value,
    expected_hresp=0,
):
    """Perform one aligned 32-bit AHB write."""

    hresp = await ahb_write(
        dut,
        address,
        value,
    )

    assert hresp == expected_hresp, (
        f"write 0x{address:02x}: "
        f"expected HRESP={expected_hresp}, got {hresp}"
    )

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def read_register(
    dut,
    address,
    expected_hresp=0,
):
    """Perform one aligned 32-bit AHB read."""

    value, hresp = await ahb_read(
        dut,
        address,
    )

    assert hresp == expected_hresp, (
        f"read 0x{address:02x}: "
        f"expected HRESP={expected_hresp}, got {hresp}"
    )

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")

    return value


async def wait_for_chip_select(
    dut,
    expected_value,
):
    """Wait until the two-bit chip-select vector reaches a value."""

    while int(dut.qspi_ce_n_o.value) != expected_value:
        await ValueChange(dut.qspi_ce_n_o)

    await Timer(1, unit="ps")


async def wait_for_done(dut):
    """Poll STATUS until the transaction has completed."""

    for _ in range(100):
        status = await read_register(
            dut,
            REG_STATUS,
        )

        if status & STATUS_DONE:
            return status

    raise AssertionError("QSPI transaction did not complete")


def nibbles_to_integer(nibbles):
    """Combine an MS-nibble-first sequence into one integer."""

    value = 0

    for nibble in nibbles:
        value = (value << 4) | nibble

    return value


async def capture_quad_write(
    dut,
    expected_chip_select,
):
    """Capture the ten nibbles of one quad write transaction."""

    await wait_for_chip_select(
        dut,
        expected_chip_select,
    )

    assert int(dut.qspi_sck_o.value) == 0

    nibbles = []

    for _ in range(10):
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")

        assert int(dut.qspi_ce_n_o.value) == expected_chip_select
        assert int(dut.qspi_sio_oe.value) == 0b1111

        nibbles.append(
            int(dut.qspi_sio_o.value) & 0xF
        )

        await FallingEdge(dut.qspi_sck_o)

    await wait_for_chip_select(
        dut,
        0b11,
    )

    return nibbles


async def respond_to_quad_read(
    dut,
    response_byte,
    expected_chip_select,
):
    """Capture command/address and provide one quad read byte."""

    await wait_for_chip_select(
        dut,
        expected_chip_select,
    )

    transmitted_nibbles = []

    # Capture two opcode nibbles and six address nibbles.
    for _ in range(8):
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")

        assert int(dut.qspi_sio_oe.value) == 0b1111

        transmitted_nibbles.append(
            int(dut.qspi_sio_o.value) & 0xF
        )

        await FallingEdge(dut.qspi_sck_o)

    await Timer(1, unit="ps")

    # The controller must release all four lines for read data.
    assert int(dut.qspi_sio_oe.value) == 0

    high_nibble = (response_byte >> 4) & 0xF
    low_nibble = response_byte & 0xF

    dut.qspi_sio_i.value = high_nibble

    await RisingEdge(dut.qspi_sck_o)
    await FallingEdge(dut.qspi_sck_o)

    dut.qspi_sio_i.value = low_nibble

    await RisingEdge(dut.qspi_sck_o)
    await FallingEdge(dut.qspi_sck_o)

    await wait_for_chip_select(
        dut,
        0b11,
    )

    return transmitted_nibbles


@cocotb.test()
async def test_registers(dut):
    """Verify the small AHB register block."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            HCLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    assert await read_register(dut, REG_CTRL) == 0
    assert await read_register(dut, REG_STATUS) == 0
    assert await read_register(dut, REG_OPCODE) == 0
    assert await read_register(dut, REG_ADDRESS) == 0
    assert await read_register(dut, REG_DATA) == 0

    ctrl_value = (
        CTRL_DIR
        | CTRL_TARGET
        | (3 << CTRL_CLKDIV_SHIFT)
    )

    await write_register(
        dut,
        REG_CTRL,
        ctrl_value,
    )

    await write_register(
        dut,
        REG_OPCODE,
        0xA5,
    )

    await write_register(
        dut,
        REG_ADDRESS,
        0x12_3456,
    )

    await write_register(
        dut,
        REG_DATA,
        0xC3,
    )

    # START is not stored.
    assert await read_register(dut, REG_CTRL) == ctrl_value
    assert await read_register(dut, REG_OPCODE) == 0xA5
    assert await read_register(dut, REG_ADDRESS) == 0x12_3456
    assert await read_register(dut, REG_DATA) == 0xC3

    # First unimplemented register.
    await write_register(
        dut,
        0x14,
        0xFFFF_FFFF,
        expected_hresp=1,
    )

    invalid_read = await read_register(
        dut,
        0x14,
        expected_hresp=1,
    )

    assert invalid_read == 0

    assert int(dut.qspi_sck_o.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b11
    assert int(dut.qspi_sio_oe.value) == 0
    assert int(dut.irq.value) == 0


@cocotb.test()
async def test_quad_write(dut):
    """Verify one arbitrary opcode, address and write byte."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            HCLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    opcode = 0xA5
    address = 0x12_3456
    write_data = 0xC3

    # TARGET=1 selects qspi_ce_n_o[1].
    ctrl = (
        CTRL_TARGET
        | (1 << CTRL_CLKDIV_SHIFT)
    )

    await write_register(dut, REG_OPCODE, opcode)
    await write_register(dut, REG_ADDRESS, address)
    await write_register(dut, REG_DATA, write_data)
    await write_register(dut, REG_CTRL, ctrl)

    monitor = cocotb.start_soon(
        capture_quad_write(
            dut,
            expected_chip_select=0b01,
        )
    )

    await write_register(
        dut,
        REG_CTRL,
        ctrl | CTRL_START,
    )

    nibbles = await monitor

    assert nibbles_to_integer(
        nibbles[0:2]
    ) == opcode

    assert nibbles_to_integer(
        nibbles[2:8]
    ) == address

    assert nibbles_to_integer(
        nibbles[8:10]
    ) == write_data

    status = await wait_for_done(dut)

    assert not (status & STATUS_BUSY)
    assert status & STATUS_DONE
    assert not (status & STATUS_RX_VALID)

    assert await read_register(
        dut,
        REG_DATA,
    ) == write_data


@cocotb.test()
async def test_quad_read(dut):
    """Verify one arbitrary opcode, address and received byte."""

    cocotb.start_soon(
        Clock(
            dut.HCLK,
            HCLK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await reset_dut(dut)

    opcode = 0xD2
    address = 0x65_4321
    response = 0x5A

    # DIR=1 selects read. TARGET=0 selects qspi_ce_n_o[0].
    ctrl = (
        CTRL_DIR
        | (1 << CTRL_CLKDIV_SHIFT)
    )

    await write_register(dut, REG_OPCODE, opcode)
    await write_register(dut, REG_ADDRESS, address)
    await write_register(dut, REG_DATA, 0xEE)
    await write_register(dut, REG_CTRL, ctrl)

    responder = cocotb.start_soon(
        respond_to_quad_read(
            dut,
            response_byte=response,
            expected_chip_select=0b10,
        )
    )

    await write_register(
        dut,
        REG_CTRL,
        ctrl | CTRL_START,
    )

    transmitted_nibbles = await responder

    assert nibbles_to_integer(
        transmitted_nibbles[0:2]
    ) == opcode

    assert nibbles_to_integer(
        transmitted_nibbles[2:8]
    ) == address

    status = await wait_for_done(dut)

    assert not (status & STATUS_BUSY)
    assert status & STATUS_DONE
    assert status & STATUS_RX_VALID

    assert await read_register(
        dut,
        REG_DATA,
    ) == response

    assert int(dut.qspi_sck_o.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b11
    assert int(dut.qspi_sio_oe.value) == 0
