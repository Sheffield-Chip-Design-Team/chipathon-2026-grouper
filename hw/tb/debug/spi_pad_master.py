"""A pad-level SPI master, driving the SPI Slave through GPIO pads 0-2.

hw/tb/spi_s/spi_s_utils.py's `_shift_byte`/`dbg_*_frame` helpers speak the
same wire protocol (SPI Slave Specification.md § Debug Command Encoding) but
drive `dut.spi_s_ss`/`spi_s_sck`/`spi_s_mosi` directly against the block-level DUT
(ahb_spi_s). At the SoC level those pins sit behind io_ss's mux on GPIO pads
0-3 (docs/hardware/design/Grouper SoC Specification.md § GPIO Multiplexing
Scheme), so a SoC-level SPI host has to drive `gpio_in` bits instead -- this
module is that same protocol, retargeted to pads.

DBG_ENABLE/BUS_LOCK/BUS_WRITE/BUS_READ/BUS_STATUS/BUS_UNLOCK are all exercised
over the wire by hw/tb/top/test_debug.py, framed exactly as spi_s_core.sv
decodes them (GRPR-SPIS-041/-044): DBG_ENABLE and BUS_LOCK arm the consent
gates and take the bus, BUS_WRITE/BUS_READ then reach any 32-bit address in
the CPU's own memory map, BUS_STATUS reads this block's own STATUS register,
and BUS_UNLOCK returns the bus. A response-bearing command (BUS_READ,
BUS_STATUS) only has anything to drive on pad 3 (MISO) while a lock is
active -- its output-enable follows dbg_lock_active (GRPR-GPIO-016), which
only a lock asserts -- so callers frame those *before* BUS_UNLOCK, not after.
"""

import logging

from cocotb.triggers import ClockCycles

log = logging.getLogger("cocotb.spi_pad_master")

# GPIO pad assignment (hw/rtl/io_ss.sv's PIN_SPI_S_* localparams).
PIN_SPI_S_SS = 0
PIN_SPI_S_SCK = 1
PIN_SPI_S_MOSI = 2
PIN_SPI_S_MISO = 3

# Dedicated debug opcodes (SPI Slave Specification.md § Debug Command
# Encoding), matching hw/tb/spi_s/spi_s_utils.py's OP_* constants.
OP_BUS_WRITE = 0x51
OP_BUS_READ = 0x52
OP_BUS_STATUS = 0x53
OP_DBG_ENABLE = 0x55
OP_DBG_RESUME = 0x57
OP_BUS_LOCK = 0x5A
OP_BUS_UNLOCK = 0xA5

str_opcodes = {
    OP_BUS_WRITE: "OP_BUS_WRITE",
    OP_BUS_READ: "OP_BUS_READ",
    OP_BUS_STATUS: "OP_BUS_STATUS",
    OP_DBG_ENABLE: "OP_DBG_ENABLE",
    OP_DBG_RESUME: "OP_DBG_RESUME",
    OP_BUS_LOCK: "OP_BUS_LOCK",
    OP_BUS_UNLOCK: "OP_BUS_UNLOCK",
}


class SpiPadMaster:
    """Drives GPIO pads 0-2 as an external SPI host, mode 0.

    `dut` must already have GPIO pads 0-2 selected to the SPI Slave's
    alternate function (GPIO_ALTSEL bits 0-2 set) before any frame is sent -
    this class does not set that up itself, since how it gets set (a real
    AHB write, or a VPI poke standing in for the reset-default ALTSEL this
    session's spec work calls for but this RTL pass does not implement) is
    the caller's decision.

    Takes a `pads` (hw.tb.top.test_soc.PadModel) rather than writing
    `dut.gpio_in` directly: that signal already has a continuous driver in
    PadModel._run(), so writing it from two places would race every cycle.
    `pads.set_pads()` is the same interface test_soc.py's own GPIO tests use.
    """

    def __init__(self, dut, pads, clk=None, sck_half=4):
        assert sck_half >= 2, "need >= 2 core clocks per half period to sample mid-phase"
        self.dut = dut
        self.pads = pads
        self.clk = clk if clk is not None else dut.clk
        self.sck_half = sck_half

    def _set_pad(self, pin, value):
        self.pads.set_pads(value << pin, mask=1 << pin)

    async def idle(self):
        self._set_pad(PIN_SPI_S_SS, 1)
        self._set_pad(PIN_SPI_S_SCK, 0)
        self._set_pad(PIN_SPI_S_MOSI, 0)
        await ClockCycles(self.clk, self.sck_half)

    async def _shift_byte(self, value, capture=False):
        """Clock one byte out MSB-first, mode 0 (CPOL=0, CPHA=0).

        One bit per SCK period of 2*sck_half core clocks: SCK low for the
        first half with MOSI set up at its start, SCK high for the second.

        `capture=True` also samples MISO (pad 3) and returns the assembled
        byte -- via `pads.driven_out()`, which is what the SoC is actually
        driving on its enabled pads, rather than `gpio_in` (loopback, and
        IE-gated the way an external host's own read would be, neither of
        which apply to reading back what this block itself put on the wire).

        MISO is sampled at the *top* of each bit period, before this
        iteration drives its own SCK pulse. The slave launches a new MISO bit
        on the falling edge (spi_s_core.sv's launch_edge), so the bit
        belonging to a period is already on the pad when that period starts;
        sampling after the pulse instead reads the bit the *next* falling
        edge produces, shifting the whole response left by one position -- a
        STATUS of 0x00000009 decoding as 0x12.

        That margin is the point of `sck_half` being 4 rather than 1. An
        earlier version of this driver ran SCK at one bit per 3 core clocks,
        which left the sample point one clock from a transition -- and the
        pad path adds a clock of its own, because every transition here goes
        through PadModel (test_soc.py), which applies `set_pads()` to gpio_in
        only on the following RisingEdge. At 3 clocks per bit that one clock
        is a third of a bit period, so the capture landed on the wrong bit
        entirely and a STATUS of 0x00000009 read back as 0x04. Real hardware
        has no such hazard: a real host clocks SCK far slower than the core
        clock, so the same relationship has tens of clocks of margin, and
        there is no PadModel in silicon at all -- the delay is an artefact of
        driving gpio_in from Python without racing the DUT's own driver.
        Widening the period restores that margin instead of trying to
        compensate for the delay by counting clocks.

        The wire-level equivalent of this driver, with no pad model in the
        path, is hw/tb/debug/spi_wire_master.py (sharc:soc_ip:spi_dbg_directed).
        """
        received = 0
        for i in range(7, -1, -1):
            # SCK low half: present this bit on MOSI. The slave launched its
            # MISO bit on the falling edge that started this phase, so by the
            # midpoint below it is settled on the pad (one PadModel clock
            # later than the DUT drove it).
            self._set_pad(PIN_SPI_S_MOSI, (value >> i) & 1)
            self._set_pad(PIN_SPI_S_SCK, 0)
            await ClockCycles(self.clk, self.sck_half // 2)
            if capture:
                received = (received << 1) | (
                    (self.pads.driven_out() >> PIN_SPI_S_MISO) & 1
                )
            await ClockCycles(self.clk, self.sck_half - (self.sck_half // 2))

            # SCK high half: the slave's own sample edge for MOSI.
            self._set_pad(PIN_SPI_S_SCK, 1)
            await ClockCycles(self.clk, self.sck_half)

        self._set_pad(PIN_SPI_S_SCK, 0)
        return received

    async def _frame(self, body):
        """Drive one complete frame: SS low, `body` (an async callback that
        shifts whatever bytes the opcode needs, and may return a value),
        SS high. Returns whatever `body` returned."""
        self._set_pad(PIN_SPI_S_SS, 0)
        await ClockCycles(self.clk, self.sck_half)
        result = await body()
        await ClockCycles(self.clk, self.sck_half)
        self._set_pad(PIN_SPI_S_SS, 1)
        await ClockCycles(self.clk, self.sck_half)
        return result

    async def dbg_enable_frame(self):
        """OP_DBG_ENABLE: opcode only, no payload, no response
        (GRPR-SPIS-043). Arms CTRL.LOCK_EN/CTRL.DBG_EN together
        (GRPR-DBG-044's DBG_ENABLE debug-port command); a subsequent
        BUS_LOCK still has to be sent to actually take the bus."""

        log.debug("Sending DBG_ENABLE FRAME.")
        await self._frame(lambda: self._shift_byte(OP_DBG_ENABLE))
        log.debug("Sending DBG_ENABLE Finished.")

    async def bus_lock_frame(self, mode_bit=0):
        """OP_BUS_LOCK: 1 flags byte. Bit 0 selects the lock flavour for
        this lock (0 = freeze, 1 = reset, GRPR-DBG-019); this transport
        always presents wdata[8]=1 (GRPR-SPIS-047), so the byte always
        supplies an explicit flavour."""
        async def body():
            log.debug(f"Sending LOCK FRAME: [{"FREEZE" if not mode_bit else "RESET"} mode] .")
            await self._shift_byte(OP_BUS_LOCK)
            await self._shift_byte(mode_bit & 0x01)
            log.debug(f"LOCK FRAME Complete!")
        await self._frame(body)

    async def bus_unlock_frame(self):
        """OP_BUS_UNLOCK: opcode only, no payload. Returns bus ownership to
        the CPU (GRPR-DBG-013) regardless of CPU state."""
        await self._frame(lambda: self._shift_byte(OP_BUS_UNLOCK))

    async def write_frame(self, address, payload, opcode=OP_BUS_WRITE):
        """One complete BUS_WRITE frame: opcode + 32-bit address + payload,
        reaching any address in the CPU's own memory map (GRPR-SPIS-045) --
        unlike the legacy 24-bit SPI_WRITE, no bank-switch trick is needed
        to land in RAM."""
        async def body():

            # Assemble Data from payload bytes into a single 32-bit integer for logging purposes
            data32 = 0
            for byte in payload:
                data32 = (data32 << 8) | (byte & 0xFF)
            payload_hex = " ".join(f"{byte:02X}" for byte in payload)

            log.debug(f"Sending FRAME: [{str_opcodes.get(opcode)}, to 0x{address:08X}]")
            await self._shift_byte(opcode)
            for shift in (24, 16, 8, 0):
                await self._shift_byte((address >> shift) & 0xFF)
            for byte in payload:
                await self._shift_byte(byte)
            log.debug(
                f"Sent FRAME: [{str_opcodes.get(opcode)}: PAYLOAD:0x{data32:08X} "
                f"({payload_hex}) to 0x{address:08X}]"
            )
        await self._frame(body)

    async def read_frame(self, address, count):
        """One complete BUS_READ frame: opcode + 32-bit address + one dummy
        byte (GRPR-SPIS-046, covering the debug-port round trip) + `count`
        response bytes captured from MISO. Only produces a real response
        while a lock is active (see this module's docstring) -- callers
        frame this before BUS_UNLOCK.

        Returns the response as a list of ints, one per byte, MSB-first per
        byte in transfer order (i.e. the same order BUS_WRITE's own
        `payload` argument uses)."""
        async def body():
            await self._shift_byte(OP_BUS_READ)
            for shift in (24, 16, 8, 0):
                await self._shift_byte((address >> shift) & 0xFF)
            await self._shift_byte(0x00)  # dummy byte
            return [await self._shift_byte(0x00, capture=True) for _ in range(count)]
        return await self._frame(body)

    async def status_frame(self):
        """One complete BUS_STATUS frame: opcode + one dummy byte + the
        fixed 4-byte STATUS word, MSB-first (GRPR-SPIS-046). Only produces
        a real response while a lock is active -- callers frame this before
        BUS_UNLOCK. Returns the 32-bit STATUS value."""
        async def body():
            await self._shift_byte(OP_BUS_STATUS)
            await self._shift_byte(0x00)  # dummy byte
            value = 0
            for _ in range(4):
                value = (value << 8) | await self._shift_byte(0x00, capture=True)
            return value
        return await self._frame(body)

    async def resume_frame(self):
        """OP_DBG_RESUME: opcode only, no payload. Returns the CPU to
        free-running execution from its current PC and clears
        STATUS.CPU_HALTED (GRPR-DBG-027); leaves bus ownership unchanged --
        resuming and releasing the bus are separate operations, so a
        BUS_UNLOCK is still needed afterward to hand the bus back."""
        await self._frame(lambda: self._shift_byte(OP_DBG_RESUME))
