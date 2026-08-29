"""Top-level SoC testbench (cocotb).

Replicates hw/tb/top/grouper_soc_hello_tb.sv - clock, reset, firmware-id
report, a UART transmit monitor and a UART receive driver - and adds a pad
model plus GPIO pattern generators the firmware can be scored against.

    CORE=sharc:soc_ip:grouper_soc_directed

    FW_TEST=gpio_echo fusesoc run --no-export $CORE                  # plain
    FW_TEST=gpio_echo fusesoc run --no-export --target=debug $CORE   # + ahb_debug
    FW_TEST=gpio_echo fusesoc run --no-export --target=trace $CORE   # + instruction trace

    COCOTB_LOG_LEVEL=DEBUG FW_TEST=gpio_echo fusesoc run --no-export $CORE

FW_TEST picks the firmware top level from sw/tests. The `trace` target writes
cpu.trace, which hw/tb/top/trace_decode.py turns into cpu_trace.dis in the
work root - and whose tail is dumped to the log automatically when a test
fails. See the soc_test decorator below.

The DUT is grouper_soc_top, so the top-level input synchronisers are in the
path.
"""

import contextlib
import functools
import logging
import os

import cocotb
import cocotb.utils
from cocotb.clock import Clock
from cocotb.queue import Queue, QueueEmpty

from cocotb.triggers import (
    ClockCycles,
    FallingEdge,
    RisingEdge,
    SimTimeoutError,
    Timer,
    with_timeout,
)

from hw.tb.models.aps6404l import (
    FAST_READ_WAIT as APS_FAST_READ_WAIT,
    OP_FAST_READ as APS_OP_FAST_READ,
    OP_READ as APS_OP_READ,
    OP_RESET as APS_OP_RESET,
    OP_RESET_EN as APS_OP_RESET_EN,
    OP_WRITE as APS_OP_WRITE,
)
from hw.tb.models.spi_psram_pads import PsramPadSlave
from hw.tb.tb_utils import bootloader
from hw.tb.top import trace_decode

log = logging.getLogger("cocotb.soc_tb")

# How many decoded instructions to dump when a test fails.
TRACE_TAIL = 64

CLK_FREQ = 10_000_000                 # must match SYS_CLK_HZ in sw/src/config.h
CLK_PERIOD_NS = 1e9 / CLK_FREQ

DEFAULT_BAUD = 19200                  # the default of UART_BAUD_RATE in sw/src/drivers/uart/uart.h

def firmware_baud():
    """The baud the firmware in the ROM was built for.

    UART_BAUD_RATE is a compile-time constant, and the build scripts can
    override it (--baud/FW_BAUD) so a simulated load does not cost a second of
    simulated time. They publish what they used as uart_baud.txt next to the
    code.hex they publish, both resolved against the simulator's working
    directory - so this is read at time zero rather than baked in at
    elaboration, for the same reason report_firmware() reads fw_id.txt.
    """
    try:
        with open("uart_baud.txt") as handle:
            return int(handle.readline().strip())
    except (FileNotFoundError, ValueError):
        return DEFAULT_BAUD

TX_BAUD = firmware_baud()
RX_BAUD = TX_BAUD

# 1/19200 s is 52083.333... ns, which cocotb refuses to round onto the
# simulator's 1 ps grid. Work in whole picoseconds instead - the 0.33 ps
# per bit that rounding loses is nine orders of magnitude below a bit time.

TX_BIT_PS = round(1e12 / TX_BAUD)
RX_BIT_PS = round(1e12 / RX_BAUD)

NUM_GPIO = 16
PAD_MASK = (1 << NUM_GPIO) - 1

# Pad split agreed with sw/tests/test_gpio_regs.c and test_gpio_echo.c.
IN_PADS = 0x00FF                      # testbench drives these
OUT_PADS = 0xFF00                     # firmware drives these

# QSPI alternate-function pad assignment.
QSPI_SCK   = 8
QSPI_CE_N0 = 9
QSPI_CE_N1 = 10
QSPI_SIO0  = 11
QSPI_SIO1  = 12
QSPI_SIO2  = 13
QSPI_SIO3  = 14

# Must match GPIO_ECHO_COUNT in sw/tests/test_gpio_echo.c.
GPIO_ECHO_COUNT = 64

# A whole test's worth of simulated time. The firmware prints at 19200 baud,
# so a chatty test is dominated by UART time, not by the CPU.
SIM_TIMEOUT_MS = 200

# How long to wait for a freshly bank-switched image to report itself. Much
# shorter than SIM_TIMEOUT_MS: by this point the UART is running at the fast
# simulation baud and the image only has to reach its first print, so anything
# beyond a few ms means it is not running at all - and every idle millisecond
# here is ~10k clocks of wall time spent proving nothing.
BOOT_TIMEOUT_MS = 20

# --------------------------------------------------------------------------
# Pad model
# --------------------------------------------------------------------------

class PadModel:
    """A minimal GPIO pad cell, enough to make the firmware self-checking.

    - A pad the SoC drives (`gpio_oe`) loops back to its own input, so
      firmware can verify what it drove by reading GPIO_IN.
    - A pad whose input buffer is off (`gpio_ie` low) reads 0. ahb_gpio_ctrl
      relies on exactly this when it declines to mask GPIO_IN with GPIO_IE.
    - Anything else follows whatever the testbench is driving.

    Pull-ups and pull-downs are not modelled; `gpio_pu`/`gpio_pd` are only
    observed, not acted on.
    """

    def __init__(self, dut):
        self.dut = dut
        self.drive = 0                # what the testbench puts on the pads

    def start(self):
        cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            await RisingEdge(self.dut.clk)
            oe = int(self.dut.gpio_oe.value)
            ie = int(self.dut.gpio_ie.value)
            out = int(self.dut.gpio_out.value)
            self.dut.gpio_in.value = ie & ((out & oe) | (self.drive & ~oe)) & PAD_MASK

    def set_pads(self, value, mask=PAD_MASK):
        """Drive `value` onto the pads selected by `mask`."""
        self.drive = (self.drive & ~mask) | (value & mask)
        log.debug("pads <= 0x%04x (mask 0x%04x)", value & mask, mask)

    def driven_out(self):
        """What the SoC is currently driving, on the pads it has enabled."""
        return int(self.dut.gpio_out.value) & int(self.dut.gpio_oe.value) & PAD_MASK

# Check Pad Configuration
def check_pad_config(dut):
    """The pad-electrical registers reach the pad interface.

    These only leave the SoC, so firmware cannot check them - it writes a
    distinct nibble pattern to each and this confirms it arrives.
    """
    for name, expected in (
        ("gpio_pu", 0x000F),
        ("gpio_pd", 0x00F0),
        ("gpio_cs", 0x0F00),
        ("gpio_sl", 0xF000),
    ):
        actual = int(getattr(dut, name).value) & PAD_MASK
        log.info("CHECK %-10s got 0x%04x  expected 0x%04x", name, actual, expected)
        assert actual == expected, f"{name}: got {actual:#06x}, expected {expected:#06x}"

# --------------------------------------------------------------------------
# GPIO pattern generators
# --------------------------------------------------------------------------
#
# Each yields 8-bit values for the low byte. Consecutive values must differ:
# the firmware detects a new pattern by watching GPIO_IN change rather than by
# a separate strobe, which keeps a pad free and the handshake simple.

def walking_ones(width=8, laps=1):
    """0x01, 0x02, 0x04 ... one hot, rotating left."""
    for _ in range(laps):
        for i in range(width):
            yield 1 << i


def walking_zeros(width=8, laps=1):
    """The inverse: a single low bit sweeping through a field of ones."""
    mask = (1 << width) - 1
    for _ in range(laps):
        for i in range(width):
            yield mask ^ (1 << i)


def knight_rider(width=8, sweeps=2):
    """A single bit bouncing off both ends, without repeating at the turn."""
    for _ in range(sweeps):
        for i in range(width):
            yield 1 << i
        for i in range(width - 2, 0, -1):
            yield 1 << i


def counter(count, start=0, step=1, width=8):
    """A plain ramp - catches bit-ordering and lane mistakes."""
    mask = (1 << width) - 1
    for i in range(count):
        yield (start + i * step) & mask


def gray_code(count, width=8):
    """Exactly one bit changes per step, so a glitchy input path shows up."""
    mask = (1 << width) - 1
    for i in range(count):
        yield (i ^ (i >> 1)) & mask


def lfsr8(count, seed=0xACE1 & 0xFF):
    """Maximal-length 8-bit LFSR (taps x^8+x^6+x^5+x^4+1, 0xB8).

    Pseudo-random but fully deterministic, so a failure is reproducible.
    Cycles through all 255 non-zero states before repeating.
    """
    state = seed or 1
    for _ in range(count):
        yield state
        lsb = state & 1
        state >>= 1
        if lsb:
            state ^= 0xB8


def checkerboard(count):
    """0xAA / 0x55 - every pad toggles on every step, worst case for coupling."""
    for i in range(count):
        yield 0xAA if i % 2 == 0 else 0x55


def dedupe(values):
    """Drop consecutive duplicates, which the change-detect handshake cannot see."""
    last = None
    for v in values:
        if v != last:
            yield v
            last = v


def pattern_stream(count=GPIO_ECHO_COUNT):
    """The stimulus the firmware is scored against, in order."""
    def gen():
        yield from walking_ones()
        yield from walking_zeros()
        yield from knight_rider(sweeps=1)
        yield from gray_code(12)
        yield from checkerboard(6)
        yield from counter(12, start=0x31, step=7)
        yield from lfsr8(24)

    out = []
    for value in dedupe(gen()):
        out.append(value)
        if len(out) == count:
            return out

    raise AssertionError(
        f"pattern_stream only produced {len(out)} distinct values, need {count}"
    )



# --------------------------------------------------------------------------
# UART
# --------------------------------------------------------------------------

class UartMonitor:
    """Decodes the DUT's uart_tx and republishes it as lines.

    The equivalent of the `uart_tx_recv` task and its mailbox in
    grouper_soc_hello_tb.sv. Bytes are echoed to the log as they arrive so a
    hung run still shows how far the firmware got.
    """

    def __init__(self, dut):
        self.dut = dut
        self.lines = []
        self.text = ""
        self._partial = ""
        self.framing_errors = 0
        # Every received byte, for callers that need the raw stream rather than
        # lines of text - the bootloader's 'R' response is binary and contains
        # newlines like any other value. Line assembly still happens below, so
        # a test can use either view.
        self.bytes = Queue()
        # While set, bytes go to the queue only. A read response is machine
        # code: decoding it as text logs line noise, and its 0x0a bytes would
        # split it into "lines" at arbitrary points and leave a half-formed one
        # to corrupt the next real message. See binary_mode().
        self.binary = False

    def start(self):
        cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            value, ok = await self._recv_byte()
            if not ok:
                self.framing_errors += 1
                if self.framing_errors == 1:
                    log.error(
                        "uart_tx framing error - DUT baud rate does not match "
                        "TX_BAUD (%d). Check CLK_FREQ here against SYS_CLK_HZ "
                        "in sw/src/soc.h",
                        TX_BAUD,
                    )
                continue

            self.bytes.put_nowait(value)

            if self.binary:
                continue

            char = chr(value)
            self.text += char
            if char == "\n":
                log.info("Grouper [UART] : %s", self._partial)
                self.lines.append(self._partial)
                self._partial = ""
            elif char != "\r":
                self._partial += char

    async def _recv_byte(self):
        """One byte, LSB first, sampled in the middle of each bit period.

        Mirrors the SystemVerilog task exactly, including its quirk: a bad
        start bit is reported but does not by itself reject the byte - only
        the stop bit gates acceptance.
        """
        await FallingEdge(self.dut.uart_tx)
        await Timer(TX_BIT_PS // 2, unit="ps")

        if int(self.dut.uart_tx.value) != 0:
            log.debug("uart_tx: bad start bit")

        value = 0
        for i in range(8):
            await Timer(TX_BIT_PS, unit="ps")
            value |= int(self.dut.uart_tx.value) << i

        await Timer(TX_BIT_PS, unit="ps")
        ok = int(self.dut.uart_tx.value) == 1
        return value, ok

    @contextlib.contextmanager
    def binary_mode(self):
        """Treat everything received inside the block as data, not text."""
        self.binary = True
        try:
            yield self
        finally:
            self.binary = False

    def drain_bytes(self):
        """Discard anything queued on the raw byte stream. Returns the count.

        The byte queue and the line view are fed from the same decoder, so
        text the test consumed as lines - the bootloader's greeting, most
        obviously - is still sitting in the queue afterwards. A binary
        response read on top of that comes out shifted by however many bytes
        were left over. Drain immediately before asking for one.
        """
        dropped = 0
        while True:
            try:
                self.bytes.get_nowait()
            except QueueEmpty:
                if dropped:
                    log.debug("discarded %d stale byte(s) before a binary read", dropped)
                return dropped
            dropped += 1

    async def recv_bytes(self, count, timeout_ms=SIM_TIMEOUT_MS):
        """Exactly `count` raw bytes off the DUT's uart_tx.

        For binary responses. Anything already queued is consumed first, so a
        caller that sends a request and then calls this cannot lose a response
        that arrived while it was still sending.
        """
        async def collect():
            out = bytearray()
            while len(out) < count:
                out.append(await self.bytes.get())
            return bytes(out)

        try:
            return await with_timeout(collect(), timeout_ms, "ms")
        except SimTimeoutError:
            raise AssertionError(
                f"timed out after {timeout_ms} ms waiting for {count} bytes on "
                f"the UART. The bootloader sends nothing until a command is "
                f"complete, so a short response usually means it is still "
                f"waiting for the rest of one"
            ) from None

    async def wait_for(self, needle, timeout_ms=SIM_TIMEOUT_MS):
        """Block until a complete line containing `needle` has been received.

        Waiting for a whole line rather than for the text to appear matters:
        the last character of a match arrives one bit time before the newline
        that publishes the line, so polling `self.text` and then looking the
        line up would lose that race.
        """
        log.debug("waiting for UART line containing %r", needle)

        async def poll():
            seen = 0
            while True:
                for line in self.lines[seen:]:
                    if needle in line:
                        return line
                seen = len(self.lines)
                await Timer(TX_BIT_PS, unit="ps")

        try:
            return await with_timeout(poll(), timeout_ms, "ms")
        except SimTimeoutError:
            last = repr(self.lines[-1]) if self.lines else "(nothing)"
            raise AssertionError(
                f"timed out after {timeout_ms} ms waiting for {needle!r} on the "
                f"UART. Last line seen: {last}"
            ) from None

async def uart_rx_send(dut, char):
    """Send one byte into the DUT's uart_rx, LSB first."""
    value = ord(char) if isinstance(char, str) else char
    log.debug("uart_rx <= %r", chr(value))

    dut.uart_rx.value = 0
    await Timer(RX_BIT_PS, unit="ps")
    for i in range(8):
        dut.uart_rx.value = (value >> i) & 1
        await Timer(RX_BIT_PS, unit="ps")
    dut.uart_rx.value = 1
    await Timer(RX_BIT_PS, unit="ps")

async def uart_rx_send_str(dut, text):
    for char in text:
        await uart_rx_send(dut, char)

async def uart_rx_send_bytes(dut, data):
    """Send a raw byte string into the DUT's uart_rx, back to back.

    No flow control, which is safe here: at CLK_FREQ the CPU has thousands of
    cycles per bit time, so the bootloader always drains its RX FIFO long
    before the next byte lands.
    """
    for value in data:
        await uart_rx_send(dut, value)

# --------------------------------------------------------------------------
# QSPI
# --------------------------------------------------------------------------

def pad_out(dut, pin):
    return (int(dut.gpio_out.value) >> pin) & 1


def pad_oe(dut, pin):
    return (int(dut.gpio_oe.value) >> pin) & 1


async def wait_qspi_select(dut):
    """Wait until PSRAM CE# is asserted and QSPI owns the pads."""

    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")

        if (
            pad_oe(dut, QSPI_SCK)
            and pad_oe(dut, QSPI_CE_N0)
            and pad_out(dut, QSPI_CE_N0) == 0
        ):
            return


async def wait_qspi_deselect(dut):
    """Wait until PSRAM CE# returns high."""

    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")

        if pad_out(dut, QSPI_CE_N0) == 1:
            return


async def wait_qspi_rising_edge(dut):
    """Detect one rising QSPI SCK edge using the SoC clock."""

    previous = pad_out(dut, QSPI_SCK)

    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")

        current = pad_out(dut, QSPI_SCK)

        if previous == 0 and current == 1:
            return

        previous = current


async def capture_single_spi_byte(dut):
    """Capture one MSB-first byte transmitted on SIO0 in SPI mode 0."""

    await wait_qspi_select(dut)

    value = 0

    for _ in range(8):
        await wait_qspi_rising_edge(dut)

        assert pad_oe(dut, QSPI_SIO0) == 1

        value = (
            (value << 1)
            | pad_out(dut, QSPI_SIO0)
        )

    await wait_qspi_deselect(dut)

    return value


async def capture_quad_transaction(dut, groups=10):
    """Capture MSB-first 4-bit groups from SIO[3:0]."""

    await wait_qspi_select(dut)

    values = []

    for _ in range(groups):
        await wait_qspi_rising_edge(dut)

        sio_oe = (
            int(dut.gpio_oe.value)
            >> QSPI_SIO0
        ) & 0xF

        assert sio_oe == 0xF

        nibble = (
            int(dut.gpio_out.value)
            >> QSPI_SIO0
        ) & 0xF

        values.append(nibble)

    await wait_qspi_deselect(dut)

    return values

# --------------------------------------------------------------------------
# Bootloader
# --------------------------------------------------------------------------
#
# The ROM bootloader's half of this lives in sw/boot/bootloader.c and the wire
# format in hw/tb/tb_utils/bootloader.py, which sw/scripts/load_fw.py uses to
# do the same job against real silicon over a serial port.

# Words per 'W'/'R' command. The protocol has no per-word acknowledgement, so
# chunking is what turns "the image is wrong somewhere" into "the image is
# wrong in this 64-word block", and gives progress on a long load.
LOAD_CHUNK_WORDS = 64

async def bootloader_write(dut, uart, addr, words, verify=True):
    """Write `words` to `addr` through the bootloader, optionally reading back."""
    await uart_rx_send_bytes(dut, bootloader.frame_write(addr, words))

    if not verify:
        return

    # A 'W' is not acknowledged, so nothing should have arrived since the last
    # readback - but the greeting the test synchronised on did, and anything
    # the bootloader prints in future would too. Drop it before the response
    # starts, or the words come back rotated by the leftovers.
    uart.drain_bytes()

    # binary_mode keeps the response out of the line logger: it is machine
    # code, and the 0x0a bytes in it would otherwise be logged as "lines".
    with uart.binary_mode():
        await uart_rx_send_bytes(dut, bootloader.frame_read(addr, len(words)))
        raw = await uart.recv_bytes(bootloader.read_response_len(len(words)))

    got = bootloader.parse_words(raw, len(words))
    log.debug("readback %#010x:\n%s", addr, bootloader.format_words(got, addr))

    complaint = bootloader.compare_words(words, got, addr)
    if complaint is not None:
        log.error(
            "readback failed at %#010x: %s\n%s",
            addr, complaint, bootloader.format_diff(words, got, addr),
        )
        raise AssertionError(f"readback failed: {complaint}")


async def load_firmware(dut, uart, image="firmware.bin", addr=bootloader.RAM_BASE,
                        verify=True):
    
    """Load a RAM-linked firmware image into RAM over the UART.

    `image` defaults to the firmware.bin that build_fw.sh publishes into the
    work root, which is also the simulator's working directory.

    Returns the number of words written. Does not boot it - call
    bootloader_boot() for that, once anything else the test wants to set up is
    in place.
    """
    words = bootloader.image_words(image)
    bootloader.check_image(words, addr)

    log.info(
        "loading %s: %d bytes to %#010x at %d baud",
        image, len(words) * bootloader.WORD_BYTES, addr, RX_BAUD,
    )

    for start, chunk in bootloader.chunks(words, LOAD_CHUNK_WORDS):
        await bootloader_write(
            dut, uart, addr + start * bootloader.WORD_BYTES, chunk, verify=verify
        )
        log.debug("loaded %d/%d words", start + len(chunk), len(words))

    log.info("loaded %d words%s", len(words), " (verified)" if verify else "")
    return len(words)


# --------------------------------------------------------------------------
# Backdoor RAM preload
# --------------------------------------------------------------------------
#
# Sending the image over the UART costs ~280 ms of simulated time and ~18 minutes of wall
# clock. So the `default` target writes it straight into the SRAM macros and
# then still sends 'B' - the bank switch, the CPU reset and the refetch from
# RAM all stay under test, and only the bulk transfer is skipped. `boot` is the
# target that still does it the honest way.

RAM_LANES = 4

def ram_lane_arrays(dut):
    """Handles to the four byte-lane SRAM macro arrays.

    Needs the signals to be public, which the `default` target arranges with
    verilator's --public-flat-rw. Without it the traversal fails, so say so
    rather than letting an AttributeError surface with no explanation.
    """
    try:
        ram = dut.u_grouper_soc_dig_ss.u_ram_ss
        return [
            ram.gen_macro_ram.gen_sram[j].u_wrapper.u_sram_macro.mem
            for j in range(RAM_LANES)
        ]
    except AttributeError as exc:
        raise AssertionError(
            f"cannot reach the SRAM macro arrays for a backdoor preload ({exc}). "
            f"This needs verilator's --public-flat-rw, which the `default` "
            f"target sets, and USE_MACRO_RAM=1 in hw/rtl/ram_ss.sv"
        ) from None


async def preload_ram(dut, image="firmware.bin", addr=bootloader.RAM_BASE):
    """Write a RAM-linked image into the SRAM macros without using the UART.

    Returns the number of words written. Leaves the bank switch alone - the
    caller still boots through the bootloader.
    """
    words = bootloader.image_words(image)
    bootloader.check_image(words, addr)

    base = (addr - bootloader.RAM_BASE) // bootloader.WORD_BYTES
    lanes = ram_lane_arrays(dut)

    log.info(
        "preloading %s: %d bytes to %#010x (backdoor, no UART)",
        image, len(words) * bootloader.WORD_BYTES, addr,
    )

    for index, word in enumerate(words):
        for lane in range(RAM_LANES):
            lanes[lane][base + index].value = (word >> (8 * lane)) & 0xFF

    # Let the scheduled writes land before anything reads the array.
    await ClockCycles(dut.clk, 2)

    log.info("preloaded %d words", len(words))
    return len(words)


async def verify_ram(dut, words, addr=bootloader.RAM_BASE):
    """Read the macro arrays back and check them against `words`.

    Cheap - no simulated time - so the preload path keeps the same guarantee
    the UART path gets from its readback.
    """
    base = (addr - bootloader.RAM_BASE) // bootloader.WORD_BYTES
    lanes = ram_lane_arrays(dut)

    got = []
    for index in range(len(words)):
        value = 0
        for lane in range(RAM_LANES):
            value |= int(lanes[lane][base + index].value) << (8 * lane)
        got.append(value)

    complaint = bootloader.compare_words(words, got, addr)
    if complaint is not None:
        log.error(
            "preload verify failed: %s\n%s",
            complaint, bootloader.format_diff(words, got, addr),
        )
        raise AssertionError(f"preload verify failed: {complaint}")


def cpu_state(dut):
    """A snapshot of cpu_ss's bank switch and CPU handshake, or None.

    Only reachable when the target made signals public (--public-flat-rw, i.e.
    the `default` target). Returns None rather than raising so it can be called
    from an error path without masking the original failure.
    """
    try:
        cpu = dut.u_grouper_soc_dig_ss.u_cpu_ss
        state = {
            "bank_switch": int(cpu.bank_switch.value),
            "cpu_rst_n": int(cpu.cpu_rst_n.value),
            "trap": int(cpu.trap.value),
            "mem_valid": int(cpu.mem_valid.value),
            "mem_addr": int(cpu.mem_addr.value),
            "mem_la_addr": int(cpu.mem_la_addr.value),
            "mem_rdata": int(cpu.mem_rdata.value),
        }
    except (AttributeError, ValueError):
        return None

    # picorv32 internals. Worth the separate try: reg_pc is what says *where*
    # a trap happened, and irq_mask says whether an illegal instruction would
    # have been catchable as IRQ 1 or had to become a trap - it resets to all
    # ones, so anything faulting before start.S unmasks traps the core.
    try:
        core = cpu.u_cpu
        state.update({
            "reg_pc": int(core.reg_pc.value),
            "irq_mask": int(core.irq_mask.value),
            "irq_state": int(core.irq_state.value),
        })
    except (AttributeError, ValueError):
        pass

    return state


def log_cpu_state(dut, when):
    """Log a cpu_state() snapshot, if this target can see one."""
    state = cpu_state(dut)
    if state is None:
        log.debug("cpu state (%s): not visible - needs --public-flat-rw", when)
        return None

    extra = ""
    if "reg_pc" in state:
        extra = (f" reg_pc={state['reg_pc']:#010x} irq_mask={state['irq_mask']:#010x}"
                 f" irq_state={state['irq_state']}")

    log.debug(
        "cpu state (%s): bank_switch=%d cpu_rst_n=%d trap=%d mem_valid=%d "
        "mem_addr=%#010x mem_la_addr=%#010x mem_rdata=%#010x%s",
        when, state["bank_switch"], state["cpu_rst_n"], state["trap"],
        state["mem_valid"], state["mem_addr"], state["mem_la_addr"],
        state["mem_rdata"], extra,
    )
    return state


async def trace_memory_select(dut, cycles=24):
    """Log cpu_ss's memory decode cycle by cycle, from the bank switch on.

    The decode is what turns a fetch address into a ROM, RAM or AHB access
    (hw/rtl/cpu_ss.sv). When an image fails to boot after the switch this says
    whether the fetch was routed to RAM at all, what word address it presented,
    and what came back - which no amount of staring at reg_pc will tell you.
    """
    try:
        cpu = dut.u_grouper_soc_dig_ss.u_cpu_ss
        probes = {
            name: getattr(cpu, name)
            for name in ("bank_switch", "cpu_rst_n", "rom_sel", "ram_sel",
                         "ram_sel_r", "ram_read", "ram_addr", "ram_rdata",
                         "rom_rdata", "mem_la_read", "mem_rdata",
                         "ram_write", "ram_wdata", "mem_wstrb", "mem_addr",
                         "mem_la_addr")
        }
    except AttributeError as exc:
        log.debug("memory decode not visible (%s) - needs --public-flat-rw", exc)
        return

    # The bootloader still has to decode the 'B' and execute the store, which
    # takes longer than the byte did to arrive - so find the switch rather
    # than assuming it has already happened.
    for _ in range(20000):
        await RisingEdge(dut.clk)
        try:
            hit = int(probes["mem_addr"].value) == 0x7fff_fffc
        except ValueError:
            hit = False
        if hit or int(probes["bank_switch"].value) == 1:
            break
    else:
        log.error("bank_switch never went high - the bootloader did not take the 'B'")
        return

    log.debug("cycle-by-cycle memory decode from the bank switch:")
    for index in range(cycles):
        await RisingEdge(dut.clk)
        values = {}
        for name, handle in probes.items():
            try:
                values[name] = int(handle.value)
            except ValueError:       # x/z during reset
                values[name] = -1
        log.debug(
            "  %2d bank=%d rst_n=%d ram_sel=%d ram_sel_r=%d rd=%d wr=%d "
            "wstrb=%x ram_addr=%#05x ram_wdata=%#010x ram_rdata=%#010x "
            "mem_addr=%#010x la_addr=%#010x mem_rdata=%#010x",
            index, values["bank_switch"], values["cpu_rst_n"],
            values["ram_sel"], values["ram_sel_r"], values["ram_read"],
            values["ram_write"], values["mem_wstrb"], values["ram_addr"],
            values["ram_wdata"], values["ram_rdata"], values["mem_addr"],
            values["mem_la_addr"], values["mem_rdata"],
        )


def watch_bus_error(dut):
    """Report the AHB address phase that led to each bus error.

    A single-cycle snapshot is not enough: cpu_ss drives HADDR straight from
    picorv32's look-ahead address, so by the time HRESP comes back HADDR has
    already moved on to the next access. Keeping a few cycles of history is
    what shows which transfer actually failed, and whether HREADY stretched
    the address phase out from under it.
    """
    try:
        cpu = dut.u_grouper_soc_dig_ss.u_cpu_ss
        probes = {n: getattr(cpu, n) for n in
                  ("bus_error", "HADDR", "HTRANS", "HWRITE", "HREADY", "HRESP",
                   "ahb_sel", "ahb_sel_r", "mem_la_addr", "mem_addr")}
    except AttributeError:
        return

    async def run():
        history = []
        seen = 0
        while True:
            await RisingEdge(dut.clk)
            values = {}
            for name, handle in probes.items():
                try:
                    values[name] = int(handle.value)
                except ValueError:
                    values[name] = -1
            history.append((cocotb.utils.get_sim_time("ns"), values))
            if len(history) > 8:
                history.pop(0)

            if values["bus_error"] != 1:
                continue
            seen += 1
            if seen > 3:            # three is plenty to see the pattern
                continue

            log.info("BUS ERROR #%d - preceding AHB cycles:", seen)
            for when, past in history:
                log.info(
                    "    %9.0fns HADDR=%#010x HTRANS=%d HWRITE=%d HREADY=%d "
                    "HRESP=%d ahb_sel=%d/%d la_addr=%#010x mem_addr=%#010x",
                    when, past["HADDR"], past["HTRANS"], past["HWRITE"],
                    past["HREADY"], past["HRESP"], past["ahb_sel"],
                    past["ahb_sel_r"], past["mem_la_addr"], past["mem_addr"],
                )

    cocotb.start_soon(run())


async def bootloader_boot(dut):
    """Swap the banks and reboot into the loaded image.

    Nothing comes back from this command directly: cpu_ss takes the write,
    holds the CPU in reset for a cycle and releases it with RAM mapped at zero,
    so the next thing on the UART is whatever the loaded image prints.
    """
    log.info("bank switch: rebooting into RAM")
    await uart_rx_send_bytes(dut, bootloader.frame_boot())

# --------------------------------------------------------------------------
# Bring-up
# --------------------------------------------------------------------------

def firmware_id():
    """What the build scripts recorded about the image in the ROM.

    build_fw.sh and build_bootloader.sh both drop fw_id.txt next to the
    code.hex that rom_ss loads, all resolved against the simulator's working
    directory.
    """
    try:
        with open("fw_id.txt") as handle:
            return handle.readline().strip()
    except FileNotFoundError:
        return ""


def report_firmware():
    """Log which firmware is in the ROM."""
    name = firmware_id()
    if name:
        log.info("TB_FIRMWARE: %s", name)
    else:
        log.warning("TB_FIRMWARE: unknown (fw_id.txt not found - was build_fw.sh run?)")


async def bring_up(dut):
    """Clock, reset, pad model and UART monitor. Returns (pads, uart)."""
    report_firmware()

    # Start the clock
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    dut.uart_rx.value = 1
    dut.gpio_in.value = 0

    dut.async_rst_n.value = 1
    await Timer(1, unit="ns")
    dut.async_rst_n.value = 0
    await Timer(123, unit="ns")
    await RisingEdge(dut.clk)
    dut.async_rst_n.value = 1
    await RisingEdge(dut.clk)
    log.debug("reset released")

    pads = PadModel(dut)
    pads.start()

    uart = UartMonitor(dut)
    uart.start()

    return pads, uart


async def expect_test_result(uart, name, timeout_ms=SIM_TIMEOUT_MS):
    """Wait for the harness summary line and require a PASS."""
    line = await uart.wait_for("TEST_RESULT:", timeout_ms=timeout_ms)
    log.info("%s: %s", name, line)
    assert "PASS" in line, f"{name} reported {line!r}"

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

# Firmware that needs the testbench to do something - drive a console, stream
# GPIO - has its own test below. Everything else only has to run to completion.
FW_TEST = os.environ.get("FW_TEST", "")
DRIVEN_FW = ("uart_echo", "gpio_echo", "qspi", "spi_m")

# Whether the ROM holds the bootloader rather than an application image, which
# is what the `boot` target builds. The file's presence and content is the
# signal, the same way cpu.trace tells soc_test whether a trace was recorded -
# so nothing has to pass the target name through to Python.
#
# It splits the tests cleanly in two: with the bootloader in ROM no application
# ever starts on its own, so every other test here would sit waiting for output
# that cannot arrive.
ROM_IS_BOOTLOADER = "bootloader" in firmware_id()

# Whether to skip the UART transfer and write the image into the SRAM macros
# directly. The `default` target drops ram_preload.txt in the work root,
# because that target is also the only one that passes verilator
# --public-flat-rw - without which the backdoor is not reachable at all. So the
# marker and the ability to act on it always arrive together.
RAM_PRELOAD = (
    os.path.exists("ram_preload.txt")
    or os.environ.get("RAM_PRELOAD", "") not in ("", "0")
)


async def settle(dut):
    """Advance to a clock edge before letting the regression end."""
    try:
        await with_timeout(RisingEdge(dut.clk), 10 * CLK_PERIOD_NS, "ns")
    except SimTimeoutError:
        log.debug("settle: no clock edge - ending without one")
    except Exception as exc: 
        log.debug("settle: %s", exc)


def soc_test(**kwargs):
    """cocotb.test plus instruction-trace handling.

    Writes the decoded listing after every test, and dumps the tail of it when
    one fails - which is the whole point of running with a trace, and is easy
    to forget to do by hand.

    Both are no-ops unless cpu.trace exists, so the `default` and `debug`
    targets are unaffected and nothing has to tell Python which target is
    running: the file's presence is the signal.

    It also ends every test on a clock edge - see settle().
    """
    def wrap(fn):
        @cocotb.test(**kwargs)
        @functools.wraps(fn)
        async def inner(dut):
            try:
                await fn(dut)
            except Exception:
                trace_decode.log_tail(TRACE_TAIL)
                raise
            finally:
                trace_decode.write_listing()
                await settle(dut)

        return inner

    return wrap


@soc_test(skip=not (ROM_IS_BOOTLOADER and RAM_PRELOAD))
async def test_preloaded_boot(dut):
    """The bank switch boots an image that was placed in RAM by the backdoor.

    The `default` target. Same ending as test_bootloader_load - greeting,
    'B', then the image has to report itself - but the image gets into RAM by
    a direct write to the SRAM macros instead of ~600 UART writes. That trades
    ~18 minutes of wall clock for a few seconds, at the cost of not exercising
    the bootloader's 'W' path, which the `boot` target still covers.
    """
    pads, uart = await bring_up(dut)
    watch_bus_error(dut)

    await uart.wait_for(bootloader.GREETING)

    words = bootloader.image_words("firmware.bin")
    await preload_ram(dut)
    await verify_ram(dut, words)

    # Independent check of the preload. verify_ram reads back through the same
    # VPI handles it wrote, so it cannot detect the handles resolving somewhere
    # other than where the CPU reads - all four lanes landing on one macro, for
    # instance. Asking the bootloader to read the words back exercises the real
    # functional path: a load through cpu_ss, ram_ss and the macro read port.
    probe = min(8, len(words))
    uart.drain_bytes()
    with uart.binary_mode():
        await uart_rx_send_bytes(
            dut, bootloader.frame_read(bootloader.RAM_BASE, probe)
        )
        raw = await uart.recv_bytes(bootloader.read_response_len(probe))

    through_cpu = bootloader.parse_words(raw, probe)
    complaint = bootloader.compare_words(words[:probe], through_cpu,
                                         bootloader.RAM_BASE)
    if complaint is not None:
        log.error(
            "the CPU does not see the preloaded image: %s\n%s",
            complaint,
            bootloader.format_diff(words[:probe], through_cpu, bootloader.RAM_BASE),
        )
        raise AssertionError(
            f"preload did not reach the memory the CPU reads: {complaint}"
        )
    log.info("preload confirmed through the CPU read path (%d words)", probe)

   # log_cpu_state(dut, "before bank switch")
    await bootloader_boot(dut)

    # Debug the bank switch
    await trace_memory_select(dut, cycles=48)

    # Debug + logging
    previous = 0
    for cycles in (2, 4, 8, 16, 32, 64, 256, 1024):
        await ClockCycles(dut.clk, cycles - previous)
        previous = cycles
        log_cpu_state(dut, f"+{cycles} clk after bank switch")

    # Driven firmware is handed to its driver here rather than being expected
    # to report on its own - see score_firmware(). BOOT_TIMEOUT_MS still bounds
    # the self-reporting case, where the image only has to reach its first
    # print.
    try:
        await score_firmware(dut, pads, uart, timeout_ms=BOOT_TIMEOUT_MS)
    except AssertionError:
        log_cpu_state(dut, "at timeout")
        raise


@soc_test(skip=not ROM_IS_BOOTLOADER or RAM_PRELOAD)
async def test_bootloader_load(dut):
    """The ROM bootloader loads an image into RAM over the UART and runs it.

    The `boot` target of hw/tb/top/grouper_soc_directed.core: the ROM holds
    sw/boot/bootloader.c and build_fw.sh has published a RAM-linked
    firmware.bin next to it. This is the only way to run firmware bigger than
    the 1 KiB ROM, so it exercises the whole path - greeting, write, readback,
    bank switch, and then the loaded image proving itself exactly as it would
    if it had booted from ROM.

    A readback failure and a boot failure mean different things, so they are
    separated: the first says the link dropped something, the second says the
    image or the bank switch is wrong.
    """
    pads, uart = await bring_up(dut)

    # The bootloader prints this once its UART is up and it is ready for a
    # command. Sending before it appears would be dropped.
    await uart.wait_for(bootloader.GREETING)

    await load_firmware(dut, uart, verify=True)
    await bootloader_boot(dut)

    await score_firmware(dut, pads, uart)


@soc_test(skip=FW_TEST in DRIVEN_FW or ROM_IS_BOOTLOADER)
async def test_firmware_runs(dut):
    """Any self-checking firmware reaches TEST_RESULT: PASS.

    The default for every test in sw/tests that uses the g_test_* harness.
    Select one with FW_TEST, e.g. FW_TEST=fibonnaci. Skipped for firmware that
    needs stimulus, which would otherwise sit here until the timeout.
    """
    _, uart = await bring_up(dut)
    await expect_test_result(uart, FW_TEST or "firmware")


# --------------------------------------------------------------------------
# Stimulus drivers
# --------------------------------------------------------------------------
#
# Firmware that needs the testbench to do something lives here rather than
# inside a single cocotb test, because there are two ways to arrive at a
# running image:
#
#   fw_rom/debug/trace   the application is in the ROM and runs from reset, so
#                        the per-firmware tests below drive it directly.
#   default/boot         the ROM holds the bootloader, and an application only
#                        starts part way through test_preloaded_boot /
#                        test_bootloader_load, after the bank switch.
#
# Both paths score the same image, so each driver is written once and called
# from either. Before this split the bootloader paths ended in a bare
# expect_test_result(), which no driven firmware can ever satisfy: uart_echo
# sits in g_getline() and gpio_echo sits in its echo loop, so neither reaches
# TEST_RESULT without stimulus, and the leg failed on the boot timeout.


async def drive_uart_echo(dut, uart):
    """The interactive echo firmware (sw/tests/test_uart_echo.c).

    Replaces the two `uart_rx_send` bursts that grouper_soc_hello_tb.sv keys
    off uart_tx newlines. Keying off the prompt text instead of a newline
    count is what makes this robust: the firmware can print as much as it
    likes before asking, and the testbench still waits for the right moment.
    """
    # The firmware prints no prompt - it starts reading immediately after the
    # harness banner, so that is the sync point.
    await uart.wait_for("TEST_BEGIN: uart_echo")
    await uart_rx_send_str(dut, "World\n")

    await uart.wait_for("Hello World!")
    await uart_rx_send_str(dut, "exit\n")

    await uart.wait_for("Bye!")

    await expect_test_result(uart, "uart_echo")


async def drive_gpio_patterns(dut, pads, uart):
    """Stream GPIO patterns at the CPU and score what it echoes back.

    The firmware drives the high byte with whatever it reads on the low byte
    (sw/tests/test_gpio_echo.c). Each pattern is held until the echo appears,
    so nothing is dropped and the check is exact rather than statistical.
    """
    # The firmware writes the pad-electrical registers before it starts.
    await uart.wait_for("GPIO_ECHO_READY")

    # Checked here rather than in its own test: booting the SoC costs ~17 ms
    # of simulated time, and this needs no stimulus of its own.
    check_pad_config(dut)

    log.info("firmware ready, streaming %d patterns", GPIO_ECHO_COUNT)

    patterns = pattern_stream()

    for i, pattern in enumerate(patterns):
        pads.set_pads(pattern, mask=IN_PADS)

        expected = (pattern << 8) & OUT_PADS

        async def echoed():
            while (int(dut.gpio_out.value) & OUT_PADS) != expected:
                await ClockCycles(dut.clk, 1)

        try:
            await with_timeout(echoed(), 200, "us")
        except SimTimeoutError:
            got = (int(dut.gpio_out.value) & OUT_PADS) >> 8
            raise AssertionError(
                f"pattern {i + 1}/{len(patterns)}: drove 0x{pattern:02x} on pads "
                f"7:0, firmware echoed 0x{got:02x} on pads 15:8"
            )

        log.debug("pattern %2d/%d: 0x%02x echoed", i + 1, len(patterns), pattern)

    log.info("all %d patterns echoed correctly", len(patterns))

    await uart.wait_for("GPIO_ECHO_DONE")
    await expect_test_result(uart, "gpio_echo")


async def drive_qspi(dut, uart):
    """Verify CPU-driven QSPI traffic reaches the external pads."""

    # First transaction from test_qspi.c:
    # bare 0x35 command in single-bit SPI mode.
    opcode = await capture_single_spi_byte(dut)

    log.info(
        "QSPI single-bit command: 0x%02x",
        opcode,
    )

    assert opcode == 0x35

    # Second transaction:
    # A5 + 123456 + C3 in quad mode.
    groups = await capture_quad_transaction(
        dut,
        groups=10,
    )

    log.info(
        "QSPI quad groups: %s",
        " ".join(f"{x:x}" for x in groups),
    )

    expected = [
        0xA, 0x5,              # opcode A5
        0x1, 0x2, 0x3,
        0x4, 0x5, 0x6,        # address 123456
        0xC, 0x3,              # data C3
    ]

    assert groups == expected, (
        f"QSPI transaction mismatch: "
        f"got {groups}, expected {expected}"
    )

    await uart.wait_for("QSPI_TRANSACTION_DONE")
    await expect_test_result(uart, "qspi")

async def drive_spi_m(dut, pads, uart):
    """Run sw/tests/test_spi_m.c against an APS6404L model on the pads.

    The firmware is self-checking - it reads back what it wrote and reports
    through the usual TEST_RESULT line. What this adds is the other side of
    the wire: a real device model, so the checks below are against what an
    APS6404L would actually have seen and returned rather than against a
    loopback. That is what makes it evidence for GRPR-SPIM-004.
    """
    psram = PsramPadSlave(dut, pads).start()

    await uart.wait_for("SPI_M_TRANSACTION_DONE")
    await expect_test_result(uart, "spi_m")

    psram.stop()

    # Datasheet section 8.6: every read and write must end on a byte boundary
    # with CE# raised immediately after.
    psram.device.check_termination()

    opcodes = [record["opcode"] for record in psram.transactions]
    log.info("APS6404L saw: %s", " ".join(f"0x{op:02x}" for op in opcodes))

    # The firmware's sequence: Reset Enable, Reset, Write, Read, Fast Read.
    assert opcodes == [
        APS_OP_RESET_EN, APS_OP_RESET,
        APS_OP_WRITE, APS_OP_READ, APS_OP_FAST_READ,
    ], f"unexpected APS6404L command sequence: {opcodes}"

    payload = bytes((0xDE, 0xAD, 0xBE, 0xEF))
    address = 0x012345

    written = psram.device.last(APS_OP_WRITE)
    assert written["address"] == address, (
        f"write went to 0x{written['address']:06x}, expected 0x{address:06x}"
    )
    assert written["written"] == payload, (
        f"device received {written['written'].hex()}, expected {payload.hex()}"
    )

    # The model's own memory is the independent check that the address phase
    # and the data phase agreed.
    assert psram.device.read_memory(address, len(payload)) == payload

    for opcode in (APS_OP_READ, APS_OP_FAST_READ):
        record = psram.device.last(opcode)
        assert record["address"] == address, (
            f"0x{opcode:02x} read from 0x{record['address']:06x}, "
            f"expected 0x{address:06x}"
        )
        assert record["read"].startswith(payload), (
            f"0x{opcode:02x} returned {record['read'].hex()}, "
            f"expected it to start with {payload.hex()}"
        )

    log.info("APS6404L: %d SCK cycles over %d CS# windows",
             psram.sck_cycles, psram.cs_windows)

    # One window per transaction, and every phase exactly 8 SCK per byte
    # (GRPR-SPIM-016) with no stray edges: two bare commands, then
    # command+address+data twice, then the same again with the 8 wait cycles
    # 'h0B requires.
    expected_cycles = (
        8 + 8
        + (8 + 24 + 8 * len(payload))
        + (8 + 24 + 8 * len(payload))
        + (8 + 24 + APS_FAST_READ_WAIT + 8 * len(payload))
    )
    assert psram.cs_windows == len(opcodes), (
        f"{psram.cs_windows} CS# windows for {len(opcodes)} transactions"
    )
    assert psram.sck_cycles == expected_cycles, (
        f"{psram.sck_cycles} SCK cycles, expected {expected_cycles}"
    )


async def score_firmware(dut, pads, uart, timeout_ms=SIM_TIMEOUT_MS):
    """Score whatever image is running now.

    Driven firmware gets the stimulus it is waiting for; everything else only
    has to reach TEST_RESULT on its own. This is the single place that knows
    which is which, so the ROM-boot tests below and the two bootloader tests
    above agree on how a given FW_TEST is judged.

    timeout_ms applies only to the self-reporting case - a driven image is
    paced by its own handshake, and each driver sets whatever bound it needs.
    """
    if FW_TEST == "uart_echo":
        await drive_uart_echo(dut, uart)
    elif FW_TEST == "gpio_echo":
        await drive_gpio_patterns(dut, pads, uart)
    elif FW_TEST == "qspi":
        await drive_qspi(dut, uart)
    elif FW_TEST == "spi_m":
        await drive_spi_m(dut, pads, uart)
    else:
        await expect_test_result(uart, FW_TEST or "firmware", timeout_ms=timeout_ms)


# --------------------------------------------------------------------------
# Driven firmware, booted straight from the ROM
# --------------------------------------------------------------------------
#
# The fw_rom/debug/trace targets. Under default/boot the same drivers are
# reached through score_firmware() instead, so these skip when the ROM holds
# the bootloader - otherwise they would sit waiting for an application that
# has not been loaded yet.

@soc_test(skip=FW_TEST != "uart_echo" or ROM_IS_BOOTLOADER)
async def test_uart_echo(dut):
    """sw/tests/test_uart_echo.c, running from the ROM."""
    _, uart = await bring_up(dut)
    await drive_uart_echo(dut, uart)


@soc_test(skip=FW_TEST != "gpio_echo" or ROM_IS_BOOTLOADER)
async def test_gpio_patterns(dut):
    """sw/tests/test_gpio_echo.c, running from the ROM."""
    pads, uart = await bring_up(dut)
    await drive_gpio_patterns(dut, pads, uart)


@soc_test(skip=FW_TEST != "qspi" or ROM_IS_BOOTLOADER)
async def test_qspi(dut):
    """sw/tests/test_qspi.c, running from the ROM."""
    _, uart = await bring_up(dut)
    await drive_qspi(dut, uart)


@soc_test(skip=FW_TEST != "spi_m" or ROM_IS_BOOTLOADER)
async def test_spi_m(dut):
    """sw/tests/test_spi_m.c against an APS6404L model, running from the ROM."""
    pads, uart = await bring_up(dut)
    await drive_spi_m(dut, pads, uart)
