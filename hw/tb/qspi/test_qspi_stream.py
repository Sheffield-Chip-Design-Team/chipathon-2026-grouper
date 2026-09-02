"""Directed tests for the Stage 2 QSPI streaming primitive.

Stage 2 deliberately tests only the serial engine's ability to continue a
DATA transfer without repeating COMMAND, ADDRESS or DUMMY. The existing AHB
manual register interface remains non-streaming until the memory-mapped path
is added in a later stage.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, ValueChange

CLK_PERIOD_NS = 10


def ahb_word_to_wire(value):
    return int.from_bytes((value & 0xFFFFFFFF).to_bytes(4, "little"), "big")


def groups_to_int(groups, width):
    value = 0
    mask = (1 << width) - 1
    for group in groups:
        value = (value << width) | (group & mask)
    return value


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.dir.value = 0
    dut.addr_en.value = 0
    dut.data_en.value = 0
    dut.target.value = 0
    dut.quad_mode.value = 1
    dut.cpol.value = 0
    dut.cpha.value = 0
    dut.clkdiv.value = 1
    dut.dummy.value = 0
    dut.opcode.value = 0
    dut.address.value = 0
    dut.write_data.value = 0
    dut.stream_enable.value = 0
    dut.stream_next.value = 0
    dut.stream_stop.value = 0
    dut.stream_write_data.value = 0
    dut.qspi_sio_i.value = 0

    for _ in range(5):
        await RisingEdge(dut.clk)

    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def wait_ce(dut, value):
    while int(dut.qspi_ce_n_o.value) != value:
        await ValueChange(dut.qspi_ce_n_o)
    await Timer(1, unit="ps")


async def start_stream(dut, *, read, opcode, address, write_data=0, target=0):
    dut.dir.value = int(read)
    dut.addr_en.value = 1
    dut.data_en.value = 1
    dut.target.value = target
    dut.quad_mode.value = 1
    dut.cpol.value = 0
    dut.cpha.value = 0
    dut.clkdiv.value = 1
    dut.dummy.value = 0
    dut.opcode.value = opcode
    dut.address.value = address
    dut.write_data.value = write_data
    dut.stream_enable.value = 1
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0


async def pulse_stream_next(dut, write_data=0):
    dut.stream_write_data.value = write_data
    dut.stream_next.value = 1
    await RisingEdge(dut.clk)
    dut.stream_next.value = 0


async def pulse_stream_stop(dut):
    dut.stream_stop.value = 1
    await RisingEdge(dut.clk)
    dut.stream_stop.value = 0


async def capture_quad_groups(dut, count, ce_value=0b10):
    await wait_ce(dut, ce_value)
    groups = []

    for index in range(count):
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")
        assert int(dut.qspi_ce_n_o.value) == ce_value
        assert int(dut.qspi_sio_oe.value) == 0b1111
        groups.append(int(dut.qspi_sio_o.value) & 0xF)
        if index != (count - 1):
            await FallingEdge(dut.qspi_sck_o)

    return groups


async def drive_quad_word(dut, value):
    wire = ahb_word_to_wire(value)
    groups = [(wire >> shift) & 0xF for shift in range(28, -1, -4)]

    for index, group in enumerate(groups):
        dut.qspi_sio_i.value = group
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")
        assert int(dut.qspi_sio_oe.value) == 0
        if index != (len(groups) - 1):
            await FallingEdge(dut.qspi_sck_o)


async def capture_command_address(dut, count=8, ce_value=0b10):
    await wait_ce(dut, ce_value)
    groups = []

    for _ in range(count):
        await RisingEdge(dut.qspi_sck_o)
        await Timer(1, unit="ps")
        assert int(dut.qspi_sio_oe.value) == 0b1111
        groups.append(int(dut.qspi_sio_o.value) & 0xF)
        await FallingEdge(dut.qspi_sck_o)

    return groups


@cocotb.test()
async def test_streaming_quad_write_continues_data_without_repeating_header(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    first_word = 0x1122_3344
    second_word = 0xA1B2_C3D4

    first_capture = cocotb.start_soon(capture_quad_groups(dut, 16))
    await start_stream(dut, read=False, opcode=0xA5, address=0x12_3456, write_data=first_word)
    first_groups = await first_capture

    assert groups_to_int(first_groups[:2], 4) == 0xA5
    assert groups_to_int(first_groups[2:8], 4) == 0x12_3456
    assert groups_to_int(first_groups[8:], 4) == ahb_word_to_wire(first_word)

    await RisingEdge(dut.word_done)
    await Timer(1, unit="ps")
    assert int(dut.busy.value) == 1
    assert int(dut.done.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b10

    second_capture = cocotb.start_soon(capture_quad_groups(dut, 8))
    await pulse_stream_next(dut, second_word)
    second_groups = await second_capture
    assert groups_to_int(second_groups, 4) == ahb_word_to_wire(second_word)

    await RisingEdge(dut.word_done)
    await Timer(1, unit="ps")
    assert int(dut.qspi_ce_n_o.value) == 0b10

    await pulse_stream_stop(dut)
    await RisingEdge(dut.done)
    await Timer(1, unit="ps")
    assert int(dut.busy.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b11


@cocotb.test()
async def test_streaming_quad_read_returns_each_word_before_transaction_end(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    first_word = 0x1234_5678
    second_word = 0x89AB_CDEF

    header_capture = cocotb.start_soon(capture_command_address(dut))
    await start_stream(dut, read=True, opcode=0xEB, address=0x01_0203)
    header = await header_capture

    assert groups_to_int(header[:2], 4) == 0xEB
    assert groups_to_int(header[2:], 4) == 0x01_0203

    await drive_quad_word(dut, first_word)
    await RisingEdge(dut.word_done)
    await Timer(1, unit="ps")
    assert int(dut.rx_valid.value) == 1
    assert int(dut.read_data.value) == first_word
    assert int(dut.done.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b10

    await pulse_stream_next(dut)
    await drive_quad_word(dut, second_word)
    await RisingEdge(dut.word_done)
    await Timer(1, unit="ps")
    assert int(dut.rx_valid.value) == 1
    assert int(dut.read_data.value) == second_word
    assert int(dut.qspi_ce_n_o.value) == 0b10

    await pulse_stream_stop(dut)
    await RisingEdge(dut.done)
    await Timer(1, unit="ps")
    assert int(dut.busy.value) == 0
    assert int(dut.qspi_ce_n_o.value) == 0b11
