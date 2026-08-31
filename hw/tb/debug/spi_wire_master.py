"""An SPI master driving spi_ss/spi_sck/spi_mosi directly, mode 0.

Same wire protocol as hw/tb/debug/spi_pad_master.py (SPI Slave
Specification.md § Debug Command Encoding) but against pins rather than
through io_ss's pad mux, for hw/tb/debug/test_spi_dbg.py.

Timing, which is the whole point of this model existing separately:

Mode 0 (CPOL=0, CPHA=0) puts one bit per SCK period. The slave launches a new
MISO bit on the *falling* edge (spi_s_core.sv's launch_edge), so the bit that
edge produced is stable across the whole period that follows it -- and the
period a bit belongs to starts *before* that period's SCK pulse, not after:

    SCK   ‾‾\_________/‾‾‾‾‾‾‾‾‾\_________/‾‾‾
            ^                    ^
            |                    +-- launches bit n+1
            +----------------------- launches bit n
          ^                        ^
          |                        +-- sample bit n+1 here
          +--------------------------- sample bit n here (top of its period)

So this model samples at the *top* of each bit period, before driving that
period's own SCK pulse. Sampling after the pulse instead reads the bit the
*next* falling edge launches, shifting the whole response left by one
position -- a STATUS of 0x00000009 decodes as 0x12.

Where in the period does not otherwise matter: MISO was measured constant
across an entire SCK phase (hw/tb/debug/test_spi_dbg.py's traces), so there is
no metastable point to avoid; what matters is only *which* period is read.

`sck_half` is in clk cycles per half SCK period.
"""

import logging

from cocotb.triggers import ClockCycles

log = logging.getLogger("cocotb.spi_wire_master")

# Dedicated debug opcodes, matching hw/tb/debug/spi_pad_master.py's OP_*.
OP_BUS_WRITE = 0x51
OP_BUS_READ = 0x52
OP_BUS_STATUS = 0x53
OP_DBG_ENABLE = 0x55
OP_DBG_RESUME = 0x57
OP_BUS_LOCK = 0x5A
OP_BUS_UNLOCK = 0xA5


class SpiWireMaster:
    """External SPI host, mode 0, driving the DUT's SPI pins directly.

    Each bit is one SCK period of 2*sck_half clk cycles: MISO sampled at the
    top of the period, then SCK low for the first half (MOSI set up at its
    start) and SCK high for the second.
    """

    def __init__(self, dut, clk=None, sck_half=4):
        assert sck_half >= 1, "need at least one clk cycle per half SCK period"
        self.dut = dut
        self.clk = clk if clk is not None else dut.clk
        self.sck_half = sck_half

    async def idle(self):
        self.dut.spi_ss.value = 1
        self.dut.spi_sck.value = 0
        self.dut.spi_mosi.value = 0
        await ClockCycles(self.clk, 2)

    async def _shift_byte(self, value, capture=False):
        """Clock one byte out MSB-first, returning the byte shifted in.

        MISO is read at the middle of each SCK-high phase -- see this
        module's docstring for why that point specifically.
        """
        received = 0
        for i in range(7, -1, -1):
            # Sample first: the slave launched this bit on the falling edge
            # that ended the previous period, so it is already stable on the
            # wire before this period's SCK pulse. Sampling after the pulse
            # instead reads the *next* bit, shifting the whole response left
            # by one position -- a STATUS of 0x09 decoding as 0x12.
            if capture:
                received = (received << 1) | int(self.dut.spi_miso.value)

            # SCK low half: present this bit on MOSI.
            self.dut.spi_mosi.value = (value >> i) & 1
            self.dut.spi_sck.value = 0
            await ClockCycles(self.clk, self.sck_half)

            # SCK high half: the master's sample edge for MOSI.
            self.dut.spi_sck.value = 1
            await ClockCycles(self.clk, self.sck_half)

        self.dut.spi_sck.value = 0
        return received

    async def _frame(self, body):
        """SS low, `body`, SS high -- one complete frame."""
        self.dut.spi_ss.value = 0
        await ClockCycles(self.clk, self.sck_half)
        result = await body()
        await ClockCycles(self.clk, self.sck_half)
        self.dut.spi_ss.value = 1
        await ClockCycles(self.clk, self.sck_half)
        return result

    async def dbg_enable_frame(self):
        """OP_DBG_ENABLE: opcode only. Arms CTRL.LOCK_EN/DBG_EN together
        (GRPR-DBG-044); a BUS_LOCK is still needed to take the bus."""
        await self._frame(lambda: self._shift_byte(OP_DBG_ENABLE))

    async def bus_lock_frame(self, mode_bit=0):
        """OP_BUS_LOCK + 1 flags byte. Bit 0 picks the flavour for this lock
        (0 = freeze, 1 = reset, GRPR-DBG-019)."""
        async def body():
            await self._shift_byte(OP_BUS_LOCK)
            await self._shift_byte(mode_bit & 0x01)
        await self._frame(body)

    async def bus_unlock_frame(self):
        """OP_BUS_UNLOCK: opcode only. Returns bus ownership to the CPU."""
        await self._frame(lambda: self._shift_byte(OP_BUS_UNLOCK))

    async def write_frame(self, address, payload):
        """OP_BUS_WRITE + 32-bit address + payload bytes."""
        async def body():
            await self._shift_byte(OP_BUS_WRITE)
            for shift in (24, 16, 8, 0):
                await self._shift_byte((address >> shift) & 0xFF)
            for byte in payload:
                await self._shift_byte(byte)
        await self._frame(body)

    async def read_frame(self, address, count):
        """OP_BUS_READ + 32-bit address + one dummy byte (GRPR-SPIS-046,
        covering the debug-port round trip) + `count` response bytes.

        Returns the response as a list of ints, in transfer order.
        """
        async def body():
            await self._shift_byte(OP_BUS_READ)
            for shift in (24, 16, 8, 0):
                await self._shift_byte((address >> shift) & 0xFF)
            await self._shift_byte(0x00)  # dummy
            return [await self._shift_byte(0x00, capture=True) for _ in range(count)]
        return await self._frame(body)

    async def status_frame(self):
        """OP_BUS_STATUS + one dummy byte + the fixed 4-byte STATUS word,
        MSB-first (GRPR-SPIS-046). Returns the 32-bit value."""
        async def body():
            await self._shift_byte(OP_BUS_STATUS)
            await self._shift_byte(0x00)  # dummy
            value = 0
            for _ in range(4):
                value = (value << 8) | await self._shift_byte(0x00, capture=True)
            return value
        return await self._frame(body)

    async def resume_frame(self):
        """OP_DBG_RESUME: opcode only. Returns the CPU to free-running
        execution and clears STATUS.CPU_HALTED (GRPR-DBG-027); leaves bus
        ownership unchanged."""
        await self._frame(lambda: self._shift_byte(OP_DBG_RESUME))
