"""Top-level SoC testbench (cocotb).

Replicates hw/tb/top/grouper_soc_hello_tb.sv - clock, reset, firmware-id
report, a UART transmit monitor and a UART receive driver - and adds a pad
model plus GPIO pattern generators the firmware can be scored against.

    CORE=sharc:soc_ip:grouper_soc_directed

    FW_TEST=gpio fusesoc run --no-export $CORE                  # plain
    FW_TEST=gpio fusesoc run --no-export --target=debug $CORE   # + ahb_debug
    FW_TEST=gpio fusesoc run --no-export --target=trace $CORE   # + instruction trace

    COCOTB_LOG_LEVEL=DEBUG FW_TEST=gpio fusesoc run --no-export $CORE

FW_TEST picks the firmware top level from sw/tests. The `trace` target writes
cpu.trace, which hw/tb/top/trace_decode.py turns into cpu_trace.dis in the
work root - and whose tail is dumped to the log automatically when a test
fails. See the soc_test decorator below.

Why cocotb rather than the SystemVerilog testbench: the firmware and the
testbench have to agree on a GPIO handshake, and expressing the pattern
generators, the scoreboard and the timeout handling in Python is far less
code than in SystemVerilog.

The DUT is grouper_soc_top, so the top-level input synchronisers are in the
path - grouper_soc_hello_tb.sv drove digital_ss, which sits below them.
"""

import functools
import logging
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import (
    ClockCycles,
    FallingEdge,
    RisingEdge,
    SimTimeoutError,
    Timer,
    with_timeout,
)

from hw.tb.top import trace_decode

log = logging.getLogger("cocotb.soc_tb")

# How many decoded instructions to dump when a test fails.
TRACE_TAIL = 64

CLK_FREQ = 10_000_000                 # must match SYS_CLK_HZ in sw/src/soc.h
CLK_PERIOD_NS = 1e9 / CLK_FREQ

TX_BAUD = 19200                       # must match UART_BAUD_RATE in sw/src/uart/uart.h
RX_BAUD = 19200

# 1/19200 s is 52083.333... ns, which cocotb refuses to round onto the
# simulator's 1 ps grid. Work in whole picoseconds instead - the 0.33 ps
# per bit that rounding loses is nine orders of magnitude below a bit time.

TX_BIT_PS = round(1e12 / TX_BAUD)
RX_BIT_PS = round(1e12 / RX_BAUD)

NUM_GPIO = 16
PAD_MASK = (1 << NUM_GPIO) - 1

# Pad split agreed with sw/tests/test_gpio.c.
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

# Must match GPIO_ECHO_COUNT in sw/tests/test_gpio.c.
GPIO_ECHO_COUNT = 64

# A whole test's worth of simulated time. The firmware prints at 19200 baud,
# so a chatty test is dominated by UART time, not by the CPU.
SIM_TIMEOUT_MS = 200


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
# Bring-up
# --------------------------------------------------------------------------

def report_firmware():
    """Log which firmware is in the ROM.

    build_fw.sh drops fw_id.txt next to the code.hex that ahb_rom loads, both
    resolved against the simulator's working directory.
    """
    try:
        with open("fw_id.txt") as handle:
            log.info("TB_FIRMWARE: %s", handle.readline().strip())
    except FileNotFoundError:
        log.warning("TB_FIRMWARE: unknown (fw_id.txt not found - was build_fw.sh run?)")


async def bring_up(dut):
    """Clock, reset, pad model and UART monitor. Returns (pads, uart)."""
    report_firmware()

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


async def expect_test_result(uart, name):
    """Wait for the harness summary line and require a PASS."""
    line = await uart.wait_for("TEST_RESULT:")
    log.info("%s: %s", name, line)
    assert "PASS" in line, f"{name} reported {line!r}"

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

# Firmware that needs the testbench to do something - drive a console, stream
# GPIO - has its own test below. Everything else only has to run to completion.
FW_TEST = os.environ.get("FW_TEST", "")
DRIVEN_FW = ("uart_echo", "gpio", "qspi")


def soc_test(**kwargs):
    """cocotb.test plus instruction-trace handling.

    Writes the decoded listing after every test, and dumps the tail of it when
    one fails - which is the whole point of running with a trace, and is easy
    to forget to do by hand.

    Both are no-ops unless cpu.trace exists, so the `default` and `debug`
    targets are unaffected and nothing has to tell Python which target is
    running: the file's presence is the signal.
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

        return inner

    return wrap


@soc_test(skip=FW_TEST in DRIVEN_FW)
async def test_firmware_runs(dut):
    """Any self-checking firmware reaches TEST_RESULT: PASS.

    The default for every test in sw/tests that uses the g_test_* harness.
    Select one with FW_TEST, e.g. FW_TEST=fibonnaci. Skipped for firmware that
    needs stimulus, which would otherwise sit here until the timeout.
    """
    _, uart = await bring_up(dut)
    await expect_test_result(uart, FW_TEST or "firmware")


@soc_test(skip=FW_TEST != "uart_echo")
async def test_uart_echo(dut):
    """The interactive echo firmware (sw/tests/test_uart_echo.c).

    Replaces the two `uart_rx_send` bursts that grouper_soc_hello_tb.sv keys
    off uart_tx newlines. Keying off the prompt text instead of a newline
    count is what makes this robust: the firmware can print as much as it
    likes before asking, and the testbench still waits for the right moment.
    """
    _, uart = await bring_up(dut)

    # The firmware prints no prompt - it starts reading immediately after the
    # harness banner, so that is the sync point.
    await uart.wait_for("TEST_BEGIN: uart_echo")
    await uart_rx_send_str(dut, "World\n")

    await uart.wait_for("Hello World!")
    await uart_rx_send_str(dut, "exit\n")

    await uart.wait_for("Bye!")

    await expect_test_result(uart, "uart_echo")


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


@soc_test(skip=FW_TEST != "gpio")
async def test_gpio_patterns(dut):
    """Stream GPIO patterns at the CPU and score what it echoes back.

    The firmware drives the high byte with whatever it reads on the low byte
    (sw/tests/test_gpio.c). Each pattern is held until the echo appears, so
    nothing is dropped and the check is exact rather than statistical.
    """
    pads, uart = await bring_up(dut)

    # Phase 1 of the firmware is self-checking against the pad model above.
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
    await expect_test_result(uart, "gpio")


@soc_test(skip=FW_TEST != "qspi")
async def test_qspi(dut):
    """Verify CPU-driven QSPI traffic reaches the external pads."""

    _, uart = await bring_up(dut)

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