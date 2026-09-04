"""Attach an APS6404L model to the SoC's GPIO pads.

hw/tb/models/aps6404l.py decodes the protocol; this drives it from the wires.
The SPI master reaches the outside world through the GPIO mux (io_ss) rather
than through dedicated ports, so at the top level the device hangs off pads
4-7 - the alternate-function assignment in hw/rtl/io_ss.sv:

    pad 4  SPI_M_SS    SoC output   CE#
    pad 5  SPI_M_SCK   SoC output   SCLK
    pad 6  SPI_M_MOSI  SoC output   SI
    pad 7  SPI_M_MISO  SoC input    SO

Sampling is driven off the SoC clock rather than off SCK directly, for the
same reason hw/tb/spi_m/spi_m_utils.py does it: SCK, MOSI and CS# all change
on the same clock edge inside the DUT, so triggering on an SCK edge races
them. Reading all three on the clock edge, and detecting the SCK transition
from the previously-sampled values, gives the pre-edge levels a real device
would capture with no delta-cycle guesswork.

MISO goes back through the testbench's PadModel rather than onto gpio_in
directly: PadModel recomputes gpio_in from its own `drive` value every clock
edge, so writing gpio_in here would be overwritten within the cycle.
"""

import logging

import cocotb
from cocotb.triggers import RisingEdge

from hw.tb.models.aps6404l import APS6404L

log = logging.getLogger("cocotb.spi_psram_pads")

# Alternate-function pad assignment, from hw/rtl/io_ss.sv.
PIN_SPI_M_SS = 4
PIN_SPI_M_SCK = 5
PIN_SPI_M_MOSI = 6
PIN_SPI_M_MISO = 7

SPI_M_PADS_MASK = (
    (1 << PIN_SPI_M_SS)
    | (1 << PIN_SPI_M_SCK)
    | (1 << PIN_SPI_M_MOSI)
    | (1 << PIN_SPI_M_MISO)
)


class PsramPadSlave:
    """Drive an APS6404L from the SoC's GPIO pads.

    `pads` is the test's PadModel; the device's SO bit is published through
    its set_pads() so the pad cell stays the single owner of gpio_in.
    """

    def __init__(self, dut, pads, cpol=0, device=None):
        self.dut = dut
        self.pads = pads
        self.cpol = cpol
        self.device = device if device is not None else APS6404L()
        self._task = None

        # Wire-level observability, alongside the model's decoded view.
        self.sck_cycles = 0
        self.cs_windows = 0

    # The decoded view lives on the device; forward it so a test does not
    # have to know which half of the pair holds what.
    @property
    def transactions(self):
        return self.device.transactions

    def check_termination(self):
        self.device.check_termination()

    def last(self, opcode=None):
        return self.device.last(opcode)

    def start(self):
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self):
        if self._task is not None:
            self._task.cancel()

    def _pad_out(self, pin):
        return (int(self.dut.gpio_out.value) >> pin) & 1

    def _pad_oe(self, pin):
        return (int(self.dut.gpio_oe.value) >> pin) & 1

    def _drive_miso(self, bit):
        self.pads.set_pads(bit << PIN_SPI_M_MISO, 1 << PIN_SPI_M_MISO)

    async def _run(self):
        dut = self.dut

        # The device requires CE# high before any operation (datasheet
        # section 8.4). Until io_ss hands the pads over, gpio_oe is low and
        # the model simply sees no edges.
        await RisingEdge(dut.clk)
        prev_sck = self._pad_out(PIN_SPI_M_SCK)
        prev_mosi = self._pad_out(PIN_SPI_M_MOSI)
        prev_csn = self._pad_out(PIN_SPI_M_SS)
        cs_was_high = True

        # The sampling edge takes SCK to its active level: rising for mode 0
        # (CPOL=0), falling for mode 3. In both, the device launches SO on
        # the opposite edge so it is stable across the master's sample.
        active = 0 if self.cpol else 1

        while True:
            await RisingEdge(dut.clk)

            # Read the values the wires held during the cycle just ending,
            # before this edge's non-blocking updates land.
            selected = self._pad_oe(PIN_SPI_M_SS)
            sck = self._pad_out(PIN_SPI_M_SCK)
            mosi = self._pad_out(PIN_SPI_M_MOSI)
            csn = self._pad_out(PIN_SPI_M_SS)

            if not selected:
                # Pads not yet in alternate-function mode - nothing to do.
                prev_sck, prev_mosi, prev_csn = sck, mosi, csn
                continue

            sampling = (sck == active) and (prev_sck != active)

            if prev_csn == 0 and sampling:
                # Counted on the first sampled bit rather than on CS# going
                # low: io_ss hands the pads over with CS# still reading low
                # for a cycle before the block drives it, and counting that
                # would report a window that never carried any traffic.
                if cs_was_high:
                    cs_was_high = False
                    self.cs_windows += 1

                self.sck_cycles += 1
                self.device.feed_bit(prev_mosi)
                self._drive_miso(self.device.miso)

            if csn == 1 and not cs_was_high:
                # CS# has gone high: end the transaction and park SO low.
                cs_was_high = True
                self.device.cs_high()
                self._drive_miso(0)

            prev_sck, prev_mosi, prev_csn = sck, mosi, csn
