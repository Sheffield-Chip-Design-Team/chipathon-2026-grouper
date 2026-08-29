"""Register-field helpers and a wire-level SPI monitor for the ahb_spi_m TB.

The monitor is the part that matters: every functional defect in
hw/rtl/spi_m/spi_m_bugs.md except the pure register ones shows up as a wrong
byte, a wrong bit count or a wrong number of SCK cycles on the wire, and none
of them are visible from the register interface alone.
"""

import logging

import cocotb
from cocotb.triggers import Edge, FallingEdge, RisingEdge, Timer

log = logging.getLogger("cocotb.spi_m")

# ---------------------------------------------------------------------------
# Register offsets
# ---------------------------------------------------------------------------

CTRL = 0x00
CMD = 0x04
STATUS = 0x08
IRQ_STATUS = 0x0C
IRQ_EN = 0x10
ADDR = 0x14
DATA = 0x18

# CTRL fields
CTRL_CPHA = 1 << 0
CTRL_CPOL = 1 << 1
CTRL_ENABLE = 1 << 3
CTRL_CLKDIV_SHIFT = 8
CTRL_IE_COMPLETE = 1 << 16
CTRL_IE_ERR = 1 << 17

# CMD fields
CMD_START = 1 << 0
CMD_OPCODE_SHIFT = 1
CMD_EN = 1 << 9
CMD_ADDR_EN = 1 << 10
CMD_ADDR_BYTES_SHIFT = 11
CMD_DATA_EN = 1 << 13
CMD_DIR_READ = 1 << 14
CMD_DIR_WRITE = 0
CMD_DUMMY_SHIFT = 15
CMD_DATA_LEN_SHIFT = 20
CMD_RX_FLUSH = 1 << 28
CMD_TX_FLUSH = 1 << 29

# STATUS fields
ST_BUSY = 1 << 0
ST_TX_EMPTY = 1 << 1
ST_TX_FULL = 1 << 2
ST_RX_EMPTY = 1 << 3
ST_RX_FULL = 1 << 4

# IRQ_STATUS / IRQ_EN fields
IRQ_TXN_COMPLETE = 1 << 0
IRQ_UNDERRUN = 1 << 1
IRQ_OVERRUN = 1 << 2
IRQ_CFG_ERR = 1 << 3

# APS6404L opcodes -- GRPR-SPIM-006
OP_SPI_READ = 0x03
OP_FAST_READ = 0x0B
OP_SPI_WRITE = 0x02
OP_FAST_WRITE = 0x38

# FAST_READ needs 8 dummy cycles on an APS6404L.
FAST_READ_DUMMY = 8


def ctrl_word(cpol=0, cpha=0, clk_div=1, enable=1, ie_complete=0, ie_err=0):
    """Build a CTRL value. CPOL and CPHA must match (mode 0 or 3 only)."""
    value = (clk_div & 0xFF) << CTRL_CLKDIV_SHIFT
    if cpha:
        value |= CTRL_CPHA
    if cpol:
        value |= CTRL_CPOL
    if enable:
        value |= CTRL_ENABLE
    if ie_complete:
        value |= CTRL_IE_COMPLETE
    if ie_err:
        value |= CTRL_IE_ERR
    return value


def cmd_word(opcode=0, cmd_en=1, addr_en=0, addr_bytes=0, data_en=0,
             dir_read=0, dummy=0, data_len=1, start=1,
             rx_flush=0, tx_flush=0):
    """Build a CMD value. data_len is in bytes; the field holds bytes-1."""
    value = 0
    if start:
        value |= CMD_START
    value |= (opcode & 0xFF) << CMD_OPCODE_SHIFT
    if cmd_en:
        value |= CMD_EN
    if addr_en:
        value |= CMD_ADDR_EN
    value |= (addr_bytes & 0x3) << CMD_ADDR_BYTES_SHIFT
    if data_en:
        value |= CMD_DATA_EN
    if dir_read:
        value |= CMD_DIR_READ
    value |= (dummy & 0x1F) << CMD_DUMMY_SHIFT
    value |= ((data_len - 1) & 0xFF) << CMD_DATA_LEN_SHIFT
    if rx_flush:
        value |= CMD_RX_FLUSH
    if tx_flush:
        value |= CMD_TX_FLUSH
    return value


class SpiMonitor:
    """Wire-level SPI slave model and monitor.

    Samples MOSI and drives MISO on the SCK edges implied by CPOL/CPHA:

        mode 0 (CPOL=0, CPHA=0): sample on rising, launch on falling
        mode 3 (CPOL=1, CPHA=1): sample on rising, launch on falling

    In both supported modes the sampling edge is the rising one; they differ
    in the idle level of SCK and hence in which physical edge comes first.

    Records:
      bits         every sampled MOSI bit for the whole CS_N-low window
      sck_cycles   total SCK sampling edges seen while CS_N was low
      cs_windows   one entry per CS_N assertion, so a transfer that repeats
                   (SPIM-ISSUE-005) is visible as more than one window
    """

    def __init__(self, dut, cpol=0, cpha=0, miso_data=None):
        self.dut = dut
        self.cpol = cpol
        self.cpha = cpha
        self.bits = []
        self.sck_cycles = 0
        self.cs_windows = 0
        self._miso = list(miso_data) if miso_data else []
        self._miso_bits = []
        for byte in self._miso:
            for i in range(7, -1, -1):
                self._miso_bits.append((byte >> i) & 1)
        self._miso_index = 0
        self._cs_was_high = True
        self._task = None

    def start(self):
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self):
        if self._task is not None:
            self._task.cancel()

    @property
    def mosi_bytes(self):
        """Sampled MOSI bits regrouped into whole bytes, MSB first."""
        out = []
        for i in range(0, len(self.bits) - 7, 8):
            value = 0
            for bit in self.bits[i:i + 8]:
                value = (value << 1) | bit
            out.append(value)
        return out

    async def _run(self):
        """Sample MOSI on the SCK edge that goes to the active level.

        Driven off HCLK rather than off SCK directly: SCK, MOSI and CS_N all
        change on the same HCLK edge inside the DUT, so an SCK-edge trigger
        races them. Watching HCLK and detecting the SCK transition from the
        previously-sampled values gives the pre-edge MOSI level a real slave
        would capture, with no delta-cycle guesswork.
        """
        dut = self.dut
        cocotb.start_soon(self._drive_miso())

        prev_sck = int(dut.SPI_SCK.value)
        prev_mosi = int(dut.SPI_MOSI.value)
        prev_csn = int(dut.SPI_CS_N.value)

        while True:
            # Read on the HCLK edge itself, BEFORE the DUT's non-blocking
            # updates land: these are the values the wires held during the
            # cycle just ending, which is exactly what a slave sees.
            await RisingEdge(dut.HCLK)
            sck = int(dut.SPI_SCK.value)
            mosi = int(dut.SPI_MOSI.value)
            csn = int(dut.SPI_CS_N.value)

            # The sampling edge drives SCK to its active level: rising when
            # CPOL=0, falling when CPOL=1.
            active = 0 if self.cpol else 1
            sampled = (sck == active) and (prev_sck != active)

            if sampled and prev_csn == 0:
                if self._cs_was_high:
                    self.cs_windows += 1
                    self._cs_was_high = False
                self.bits.append(prev_mosi)
                self.sck_cycles += 1

            if csn == 1:
                self._cs_was_high = True

            prev_sck, prev_mosi, prev_csn = sck, mosi, csn

    async def _track_mosi(self):
        """Keep the value MOSI held before the most recent change."""
        dut = self.dut
        self._mosi_prev = int(dut.SPI_MOSI.value)
        while True:
            await Edge(dut.SPI_MOSI)
            # Everything the sampler needs is the value from *before* this
            # change; publish it only after the sampler has had its turn.
            await Timer(1, unit="ps")
            self._mosi_prev = int(dut.SPI_MOSI.value)

    async def _drive_miso(self):
        """Shift out miso_data on the launch edge, MSB first."""
        dut = self.dut
        if not self._miso_bits:
            return
        # A slave launches MISO on the edge the master does NOT sample on, so
        # the bit is stable across the master's sampling edge.
        launch = 1 if self.cpol else 0
        while True:
            await FallingEdge(dut.SPI_CS_N)
            self._miso_index = 0
            dut.SPI_MISO.value = self._miso_bits[0]
            prev_sck = int(dut.SPI_SCK.value)
            while int(dut.SPI_CS_N.value) == 0:
                await RisingEdge(dut.HCLK)
                sck = int(dut.SPI_SCK.value)
                if (sck == launch) and (prev_sck != launch):
                    self._miso_index += 1
                    if self._miso_index < len(self._miso_bits):
                        dut.SPI_MISO.value = self._miso_bits[self._miso_index]
                prev_sck = sck


async def wait_not_busy(dut, ahb_read, timeout_cycles=20000):
    """Poll STATUS.BUSY until it clears. Returns the number of polls."""
    for i in range(timeout_cycles):
        status, _ = await ahb_read(dut, STATUS)
        if not (status & ST_BUSY):
            return i
        await RisingEdge(dut.HCLK)
    raise TimeoutError("STATUS.BUSY never cleared -- transfer hung")
