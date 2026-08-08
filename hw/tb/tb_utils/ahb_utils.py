"""Shared AHB3-Lite bus-driving helpers for hw/tb cocotb testbenches."""

import logging

from cocotb.triggers import RisingEdge, FallingEdge

HTRANS_IDLE = 0b00
HTRANS_NONSEQ = 0b10

HSIZE_BYTE = 0b000
HSIZE_HALF = 0b001
HSIZE_WORD = 0b010

_SIZE_NAMES = {HSIZE_BYTE: "byte", HSIZE_HALF: "half", HSIZE_WORD: "word"}

# A child of the "cocotb" logger, so COCOTB_LOG_LEVEL controls it:
#
#   COCOTB_LOG_LEVEL=DEBUG fusesoc run --no-export <core>
#
# Everything here is DEBUG - raw bus traffic is detail, and this module is
# shared with the UART and SPI-slave testbenches, which should not get noisier
# at the default level.
log = logging.getLogger("cocotb.ahb")


async def _data_phase(dut, op, addr):
    """Ride out the data phase. Returns (HRESP, wait_cycles).

    Every block in this repo except ahb_gpio_ctrl answers in a single cycle
    (HREADYOUT tied to 1), so for those the loop runs exactly once and the
    timing is identical to what it was before wait-state support existed.

    ahb_gpio_ctrl answers an invalid write with the AHB-Lite two-cycle ERROR:
    HREADYOUT low with HRESP high, then HREADYOUT high with HRESP high. HRESP
    is accumulated rather than sampled once at the end so that a single-cycle
    HRESP from the older blocks is not missed either.

    HREADYIN is driven to follow HREADYOUT: on the real fabric the master sees
    the muxed HREADY, so a stalled slave holds it low. It is already 1 for a
    zero-wait-state slave, so this changes nothing for them.
    """
    hresp = 0
    waits = 0
    while True:
        await FallingEdge(dut.HCLK)
        cycle_resp = int(dut.HRESP.value)
        hresp |= cycle_resp
        ready = int(dut.HREADYOUT.value)
        dut.HREADYIN.value = ready
        if ready:
            return hresp, waits
        log.debug(
            "%s 0x%03x   wait state %d: HREADYOUT=0 HRESP=%d",
            op, addr, waits + 1, cycle_resp,
        )
        waits += 1
        await RisingEdge(dut.HCLK)


def _summary(op, addr, hresp, waits, extra=""):
    return "%s 0x%03x %s HRESP=%d%s%s" % (
        op,
        addr,
        extra,
        hresp,
        " ERROR" if hresp else "",
        " (%d wait state%s)" % (waits, "" if waits == 1 else "s") if waits else "",
    )


async def ahb_write(dut, addr, data, size=HSIZE_WORD):
    """Single-beat AHB3-Lite write. Returns HRESP."""
    log.debug("WR 0x%03x <= 0x%08x (%s)", addr, data, _SIZE_NAMES.get(size, size))

    await RisingEdge(dut.HCLK)
    dut.HADDR.value = addr
    dut.HSIZE.value = size
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
    #
    # Dropping here is also what a master must do once a slave errors, and it
    # is safe under wait states: a slave that stalls only samples the address
    # phase once it is ready again, by which point this is IDLE.
    dut.HTRANS.value = HTRANS_IDLE
    dut.HSEL.value = 0
    dut.HWRITE.value = 0

    hresp, waits = await _data_phase(dut, "WR", addr)
    log.debug(_summary("WR", addr, hresp, waits))
    # Deliberately not clearing HWDATA: ahb_uart.sv latches write data one
    # cycle after the address phase, so clearing it here would race the
    # write and corrupt it (same reasoning as hw/dv/uvc/ahb3lite/ahb3lite_driver.py).
    return hresp


async def ahb_read(dut, addr, size=HSIZE_WORD):
    """Single-beat AHB3-Lite read. Returns (data, HRESP)."""
    log.debug("RD 0x%03x    (%s)", addr, _SIZE_NAMES.get(size, size))

    await RisingEdge(dut.HCLK)
    dut.HADDR.value = addr
    dut.HSIZE.value = size
    dut.HTRANS.value = HTRANS_NONSEQ
    dut.HWRITE.value = 0
    dut.HSEL.value = 1
    dut.HREADYIN.value = 1

    await RisingEdge(dut.HCLK)
    # See the comment in ahb_write(): clear the address-phase signals before
    # sampling HRESP, not after, to avoid a false invalid-access trip.
    dut.HTRANS.value = HTRANS_IDLE
    dut.HSEL.value = 0

    hresp, waits = await _data_phase(dut, "RD", addr)
    # Read data is only valid in the cycle the slave reports ready, which is
    # where _data_phase() leaves us.
    data = int(dut.HRDATA.value) & 0xFFFF_FFFF
    log.debug(_summary("RD", addr, hresp, waits, extra="=> 0x%08x" % data))
    return data, hresp
