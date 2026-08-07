# Dry-run boot ROM.
#
# The only thing in the ROM for the LibreLane dry run
# (librelane/classic/dry_run_config.yaml): jump straight into the RAM window
# at 0x0000_2000 (the decode in hw/rtl/interconnect/ahb_interconnect_ss.sv)
# on reset, and again on an interrupt.
#
# The dry-run RAM is a counter placeholder, not a memory (see the `DRY_RUN
# branch in hw/rtl/memory/ahb_ram.sv), so this is a structural boot path used
# to keep the fetch path real for synthesis and PnR - it is not a working
# boot. sw/src/start.S remains the real reset handler for simulation.
#
# .option norvc keeps every instruction 4 bytes wide even though the CPU is
# built RV32EMC, so the IRQ entry lands exactly on PROGADDR_IRQ (0x10) without
# hand-counting compressed encodings. Only x0-x15 are used, as RV32E requires.

    .option norvc

    .equ RAM_BASE,     0x00002000      # ahb_interconnect_ss.sv RAM window
    .equ PROGADDR_IRQ, 0x00000010      # cpu_ss.sv picorv32 parameter

    .section .text.start, "ax"
    .globl _start

_start:                                # 0x00 - PROGADDR_RESET
    lui  t0, %hi(RAM_BASE)
    jr   t0

    nop
    nop

_irq:                                  # 0x10 - PROGADDR_IRQ
    lui  t0, %hi(RAM_BASE)
    addi t0, t0, PROGADDR_IRQ
    jr   t0

    # Pad to the full 64 B of the dry-run ROM (ahb_rom.sv MEM_WIDTH = 6) so
    # every memory[] word the generated code.vmem has to drive is present -
    # an undriven word is a "used but has no driver" warning out of Yosys.
    .org 64, 0x00
