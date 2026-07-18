"""Shared AHB3-Lite bus-driving helpers for hw/tb cocotb testbenches."""

from cocotb.triggers import RisingEdge, FallingEdge

HTRANS_IDLE = 0b00
HTRANS_NONSEQ = 0b10
HSIZE_WORD = 0b010

async def ahb_write(dut, addr, data):
    """Single-beat AHB3-Lite write. Returns HRESP."""
    await RisingEdge(dut.HCLK)
    dut.HADDR.value = addr
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 1
    dut.HWDATA.value = data
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)
    # Drop the address-phase signals *before* sampling HRESP: ahb_uart.sv's
    # invalid-access check is combinational on the live HTRANS/HSEL, so
    # sampling first would still see this transfer as "in progress" and can
    # false-trip on a status bit that this very access just changed (e.g.
    # rx_empty flipping high right as an RXDATA read completes).
    dut.HTRANS.value = HTRANS_IDLE
    dut.HSEL.value = 0
    dut.HWRITE.value = 0
    await FallingEdge(dut.HCLK)
    hresp = int(dut.HRESP.value)
    # Deliberately not clearing HWDATA: ahb_uart.sv latches write data one
    # cycle after the address phase, so clearing it here would race the
    # write and corrupt it (same reasoning as hw/dv/uvc/ahb3lite/ahb3lite_driver.py).
    return hresp


async def ahb_read(dut, addr):
    """Single-beat AHB3-Lite read. Returns (data, HRESP)."""
    await RisingEdge(dut.HCLK)
    dut.HADDR.value = addr
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 0
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)
    # See the comment in ahb_write(): clear the address-phase signals before
    # sampling HRESP, not after, to avoid a false invalid-access trip.
    dut.HTRANS.value = HTRANS_IDLE
    dut.HSEL.value = 0
    await FallingEdge(dut.HCLK)
    data = int(dut.HRDATA.value) & 0xFFFF_FFFF
    hresp = int(dut.HRESP.value)
    return data, hresp
