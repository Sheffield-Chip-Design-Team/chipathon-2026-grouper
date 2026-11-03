"""Checking the QSPI memory-aperture decode and address translation."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

HTRANS_IDLE = 0b00
HTRANS_NONSEQ = 0b10
HSIZE_WORD = 0b010

HCLK_PERIOD_NS = 10

QSPI_CTRL_BASE = 0x8000_5000
QSPI_MEM_BASE = 0x8002_0000
QSPI_MEM_SIZE = 0x0080_0000
QSPI_MEM_LAST = QSPI_MEM_BASE + QSPI_MEM_SIZE - 1

QSPI_SENTINEL = 0x5153_5049


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

    for prefix in ("uart", "gpio_ctrl", "spi_m", "spi_s", "ext_periph"):
        getattr(dut, f"{prefix}_HRDATA").value = 0
        getattr(dut, f"{prefix}_HREADYOUT").value = 1
        getattr(dut, f"{prefix}_HRESP").value = 0

    dut.qpsi_HRDATA.value = QSPI_SENTINEL
    dut.qpsi_HREADYOUT.value = 1
    dut.qpsi_HRESP.value = 0

    for _ in range(3):
        await RisingEdge(dut.HCLK)

    dut.HRESETn.value = 1

    await RisingEdge(dut.HCLK)
    await Timer(1, unit="ps")


async def present_address(dut, address):
    dut.HADDR.value = address
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HSIZE.value = HSIZE_WORD
    dut.HWRITE.value = 0

    await Timer(1, unit="ps")


@cocotb.test()
async def test_control_and_memory_aperture_selects_are_distinct(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())

    await reset_dut(dut)

    await present_address(dut, QSPI_CTRL_BASE)

    assert int(dut.qpsi_HSEL.value) == 1
    assert int(dut.qpsi_HMEMSEL.value) == 0

    await present_address(dut, QSPI_MEM_BASE)

    assert int(dut.qpsi_HSEL.value) == 0
    assert int(dut.qpsi_HMEMSEL.value) == 1
    assert int(dut.qpsi_HMEMADDR.value) == 0


@cocotb.test()
async def test_aperture_translation_covers_full_8_mib(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())

    await reset_dut(dut)

    for offset in (0x000000, 0x000004, 0x123456, 0x7FFFFC, 0x7FFFFF):
        await present_address(dut, QSPI_MEM_BASE + offset)

        assert int(dut.qpsi_HMEMSEL.value) == 1
        assert int(dut.qpsi_HMEMADDR.value) == offset

    await present_address(dut, QSPI_MEM_LAST + 1)

    assert int(dut.qpsi_HMEMSEL.value) == 0


@cocotb.test()
async def test_memory_aperture_uses_qspi_response_slot(dut):
    cocotb.start_soon(Clock(dut.HCLK, HCLK_PERIOD_NS, unit="ns").start())

    await reset_dut(dut)

    await present_address(dut, QSPI_MEM_BASE + 0x100)

    assert int(dut.qpsi_HMEMSEL.value) == 1

    await RisingEdge(dut.HCLK)

    dut.HTRANS.value = HTRANS_IDLE

    await Timer(1, unit="ps")

    assert int(dut.HREADY.value) == 1
    assert int(dut.HRESP.value) == 0
    assert int(dut.HRDATA.value) == QSPI_SENTINEL