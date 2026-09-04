"""SoC-level acceptance tests for the Debug Unit against the real CPU and a
real SPI-wire host, proving the whole debug path end to end:

Run with:
  fusesoc run --no-export --target=debug_unit sharc:soc_ip:grouper_soc_directed
"""

import logging

import cocotb
from cocotb.triggers import ClockCycles

from hw.tb.debug.spi_pad_master import SpiPadMaster
from hw.tb.top.test_soc import (
    SIM_TIMEOUT_MS,
    bootloader,
    bootloader_boot,
    bring_up,
    preload_ram,
)

log = logging.getLogger("cocotb.debug_soc")

# STATUS bit positions (Debug Unit.md § STATUS), matching
# hw/tb/debug/debug_utils.py's own constants.
STATUS_LOCK_ACTIVE = 1 << 0
STATUS_CPU_HALTED = 1 << 3

# The word sw/tests/test_debug_heartbeat.c increments, and the address the
# freeze test BUS_READs to watch it. After the bootloader's bank switch RAM
# answers at zero, which is also where ram.ld links that image, so this one
# address is correct for the CPU and the debug host alike. Kept in sync with
# HEARTBEAT_ADDR in sw/tests/test_debug_heartbeat.c.
HEARTBEAT_ADDR = 0x0000_0980

async def wait_lock_active(master, tries=8):
    """Poll BUS_STATUS over the wire until LOCK_ACTIVE reads back set.

    BUS_LOCK's SPI frame completing only means dbg_ctrl accepted the
    request; LOCK_ACTIVE follows a cycle later (GRPR-DBG-009 raises
    LOCK_PENDING for one cycle first, so any address-phase CPU access can
    retire before ownership moves). A real host learns that the lock took
    by reading STATUS, and that is exactly what this does -- no VPI, and
    each retry is a further real frame on the wire, so the lock has more
    time to settle with every attempt.
    """
    for _ in range(tries):
        status = await master.status_frame()
        log.debug(f"Polling STATUS: 0x{status:08X}")
        if status & STATUS_LOCK_ACTIVE:
            return status
    raise TimeoutError(
        f"STATUS.LOCK_ACTIVE still clear after {tries} BUS_STATUS reads "
        f"(last status 0x{status:08X})"
    )


async def start_debug_session(dut, pads, mode_bit=0):
    """DBG_ENABLE then BUS_LOCK, the two-step host sequence GRPR-SPIS-043
    describes. Returns the SpiPadMaster, already past both steps and ready
    to frame BUS_WRITE/BUS_READ/BUS_STATUS/DBG_RESUME/BUS_UNLOCK."""
    master = SpiPadMaster(dut, pads)
    await master.idle()
    await master.dbg_enable_frame()
    log.debug("DBG_ENABLE FRAME sent.")
    await master.bus_lock_frame(mode_bit=mode_bit)
    log.debug("BUS_LOCK FRAME sent.")
    await wait_lock_active(master, tries=50)  # give the CPU time to retire any in-flight access
    return master


async def boot_heartbeat(dut):
    """Bring the SoC up and get sw/tests/test_debug_heartbeat.c running.

    The image goes into the SRAM macros through the backdoor (preload_ram,
    VPI) rather than over the UART. That is test *setup*, not the thing
    under test: getting the same 1968 bytes in through the bootloader's
    'W' command costs ~65 ms of simulated time and several minutes of wall
    clock per run, and every assertion this file makes about the Debug Unit
    is still driven and checked entirely over the SPI wire afterwards. The
    UART path itself is covered by test_soc.py's own boot tests.

    The bank switch is still done for real, through the bootloader's 'B'
    command on the UART, since that is what starts the CPU on the image.
    Returns (pads, uart).
    """
    pads, uart = await bring_up(dut)

    # The bootloader greets before it will take a command.
    await uart.wait_for("hi", timeout_ms=SIM_TIMEOUT_MS)

    await preload_ram(dut)
    await bootloader_boot(dut)

    # After the bank switch RAM answers at zero, so the heartbeat counter is
    # at HEARTBEAT_ADDR for the CPU and for the debug host alike. Give the
    # CPU time to reach the loop and put a first value there.
    await ClockCycles(dut.clk, 200)
    return pads, uart


async def read_word(master, address):
    """One BUS_READ of a 32-bit little-endian word, as an int."""
    got = await master.read_frame(address, 4)
    return int.from_bytes(bytes(got), "little")


@cocotb.test()
async def test_debug_write_reaches_ram(dut):
    """The real DBG_ENABLE -> BUS_LOCK -> BUS_WRITE -> BUS_READ -> BUS_UNLOCK
    sequence, driven at the pad level, lands in the same RAM the CPU reads -
    end to end through io_ss, ahb_spi_s, the debug port, and cpu_ss's
    ownership mux.

    The write is confirmed with a real BUS_READ over the wire rather than by
    reading the RAM macro arrays over VPI: that keeps the whole test to the
    chip's own pins, so it runs unchanged against a gate-level netlist.
    """
    pads, uart = await bring_up(dut)

    payload = [0xDE, 0xAD, 0xBE, 0xEF]
    address = bootloader.RAM_BASE + 0x100  # well inside the RAM window

    master = await start_debug_session(dut, pads)
    await master.write_frame(address, payload)
    got = await master.read_frame(address, len(payload))
    await master.bus_unlock_frame()

    assert got == payload, (
        f"BUS_WRITE at 0x{address:08X} read back as {[hex(b) for b in got]}, "
        f"expected {[hex(b) for b in payload]}"
    )


@cocotb.test()
async def test_debug_read_from_ram(dut):
    """A real BUS_READ, framed while still locked, returns the same bytes a
    prior BUS_WRITE put there - end to end over the wire in both directions,
    with no VPI readback standing in for either half.

    Distinct from test_debug_write_reaches_ram in what it pins down: this one
    walks a multi-byte burst across consecutive addresses (GRPR-SPIS-034's
    auto-increment), so a response that is correct only for its first byte
    fails here.
    """
    pads, uart = await bring_up(dut)

    payload = [0x12, 0x34, 0x56, 0x78]
    address = bootloader.RAM_BASE + 0x200

    master = await start_debug_session(dut, pads)
    await master.write_frame(address, payload)
    got = await master.read_frame(address, len(payload))
    await master.bus_unlock_frame()

    assert got == payload, (
        f"BUS_READ at 0x{address:08X} returned {[hex(b) for b in got]}, "
        f"expected {[hex(b) for b in payload]}"
    )


@cocotb.test()
async def test_debug_freeze_pauses_and_resumes_cpu(dut):
    """A freeze-flavour BUS_LOCK actually stalls fetch/execute on the real
    CPU, and DBG_RESUME actually lets it continue.

    Both halves are observed over the wire, with no VPI:

      - The debug port's own claim, read for real over BUS_STATUS:
        CPU_HALTED set under the freeze, clear after DBG_RESUME, with
        LOCK_ACTIVE surviving the resume (GRPR-DBG-027 - resuming and
        releasing the bus are separate operations).
      - The *architectural* effect, read by BUS_READing the counter
        sw/tests/test_debug_heartbeat.c keeps incrementing in RAM: it holds
        still across a gap while frozen, and moves again once resumed. That
        is the same fact picorv32's reg_pc would show, but reached through
        the chip's pins, so it survives at gate level where there is no
        reg_pc to look at.

    Reading the heartbeat while the CPU is frozen is safe because the debug unit
    owns the bus, and nothing else is writing to that word.
    """

    pads, uart = await boot_heartbeat(dut)

    master = await start_debug_session(dut, pads, mode_bit=0)  # freeze

    status = await master.status_frame()
    
    assert status & STATUS_LOCK_ACTIVE, f"STATUS.LOCK_ACTIVE not set: 0x{status:08X}"
    assert status & STATUS_CPU_HALTED, f"STATUS.CPU_HALTED not set: 0x{status:08X}"

    frozen_1 = await read_word(master, HEARTBEAT_ADDR)
    await ClockCycles(dut.clk, 200)  # plenty for a running CPU to move on
    frozen_2 = await read_word(master, HEARTBEAT_ADDR)

    assert frozen_1 == frozen_2, (
        f"heartbeat at 0x{HEARTBEAT_ADDR:08X} moved while frozen: "
        f"0x{frozen_1:08X} -> 0x{frozen_2:08X}"
    )

    # DBG_RESUME clears the freeze; STATUS is read while still locked, which
    # is what makes both halves of GRPR-DBG-027 observable -- CPU_HALTED goes
    # away, LOCK_ACTIVE does not.
    await master.resume_frame()

    status = await master.status_frame()
    assert not (status & STATUS_CPU_HALTED), (
        f"STATUS.CPU_HALTED still set after DBG_RESUME: 0x{status:08X}"
    )
    assert status & STATUS_LOCK_ACTIVE, (
        f"STATUS.LOCK_ACTIVE cleared by DBG_RESUME: 0x{status:08X} "
        f"(GRPR-DBG-027: resuming and releasing the bus are separate operations)"
    )

    # DBG_RESUME un-freezes the CPU and unlocking the bus gives the CPU bus access again
    await master.bus_unlock_frame()
    await ClockCycles(dut.clk, 400)  # the CPU is now genuinely free-running

    # Re-lock to read the counter: pad 3 (MISO) is only driven while
    # dbg_lock_active (GRPR-GPIO-016),
    
    # Freeze lock, so the CPU retains state 
    await master.bus_lock_frame(mode_bit=0)
    await wait_lock_active(master, tries=50)

    running = await read_word(master, HEARTBEAT_ADDR)
    await master.bus_unlock_frame()

    assert running != frozen_2, (
        f"heartbeat at 0x{HEARTBEAT_ADDR:08X} did not move after DBG_RESUME: "
        f"still 0x{running:08X}"
    )
