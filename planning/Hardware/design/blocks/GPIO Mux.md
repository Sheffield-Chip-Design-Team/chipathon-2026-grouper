# AHB GPIO Multiplexer

**Owner:** TBD
**Status:** Not started. Per the [Schematic Review](../../Schematic%20Review.md) §4 "Block Level Design Summary", GPIO MUX design is explicitly listed as a TODO item (not yet in the "starting RTL design" set, which currently covers SPI M, SPI S, and QSPI only). No RTL exists yet under `hw/rtl/`.
**Source:** [Schematic Review](../../Schematic%20Review.md) §"Block-Level Design Checklists → 2. AHB GPIO Multiplexer" — the source checklist for this block is a single bullet point; everything else below is inferred from the top-level testbench diagram description and the memory map, and is flagged as an open item where it is not directly stated.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — memory map, pin-sharing context | [GPIO Mux Verification Plan](../../verification/blocks/GPIO%20Mux%20Verification%20Plan.md)

---

## Purpose

Two roles, both stated or implied by the Schematic Review:

1. A general-purpose, firmware-controlled AHB-Lite GPIO peripheral (`GPIO CTRL` in the memory map).
2. A physical-pin router: per the Schematic Review's Top-Level Testbench Architecture diagram, the peripherals with external pins (SPI Slave, SPI Master, QSPI, UART) are each "routed through GPIO IO MUX and MUX CTRL blocks" — implying this block also arbitrates/multiplexes shared physical IO pins across those peripherals (chipathon per-team pad budgets are tight, so pin-sharing across peripherals is the likely motivation, consistent with GrouperSoC's `CLAUDE.md` pad-budget notes). The exact muxing scheme (which pins are shared, priority/ownership rules, register-controlled vs. static) is **not yet documented** — this needs to come out of the "Detailed Requirements Review" TODO the Schematic Review itself calls out.

## Protocols / Standards Conformity

- **Bus side:** AHB-Lite subordinate (register access), consistent with the other 4 peripherals.
- **Pin side:** Not yet documented — depends on the unresolved pin-sharing scheme above.

## Key Functionality

| ID | Requirement |
|---|---|
| `GRPR-GPIO-001` | The block shall host a programmable 2-stage synchroniser on each input (explicit in source). |
| `GRPR-GPIO-002` | The block shall expose AHB-Lite-mapped control/status registers at the `GPIO CTRL` region of the memory map (see [Grouper SoC Specification § Memory Map](../Grouper%20SoC%20Specification.md#memory-map)). |
| `GRPR-GPIO-003` | The block shall route/multiplex physical IO pins shared between SPI Slave, SPI Master, QSPI, and UART, per the Schematic Review's top-level testbench diagram ("GPIO IO MUX + MUX CTRL"). **Open — pin list, ownership/priority rules, and control-register interface are not yet defined.** |

## Block Diagram

Not yet documented.

## Parameters and Configurations

Not yet documented.

## IOs and External Interfaces

Not yet documented — depends on `GRPR-GPIO-003` (which physical pins this block owns/multiplexes).

## Clocking Strategy

Not yet documented. Expected to be single-clock-domain like the other 4 peripherals, since GrouperSoC currently has one clock domain, but not confirmed for this block specifically.

## Reset Strategy

Not yet documented.

## CDC Strategy

`GRPR-GPIO-001`'s 2-stage synchroniser on each input is itself the CDC/metastability mitigation for GPIO inputs (which are asynchronous board-level signals). Whether the SPI/QSPI/UART pins being routed through this mux need their own synchronization here, or whether that stays owned by each peripheral block (as it currently is for UART — see [UART § CDC Strategy](UART.md#cdc-strategy)), is not yet documented.

## Performance Targets

Not yet documented.

## Size Estimate

Not yet documented.

## Open Items

- This entire block is pre-RTL and pre-detailed-requirements per the Schematic Review's own TODO list. Almost everything above beyond the two explicit source bullets (`GRPR-GPIO-001`, and the top-level diagram's routing role) is an open item, not a firm requirement.
- The pin-sharing/muxing scheme needs to be defined before SPI Master/SPI Slave/QSPI physical IO can be finalized in their own block docs — see the open items in [SPI Master](SPI%20Master.md#open-items), [SPI Slave](SPI%20Slave.md#open-items), and [QSPI](QSPI.md#open-items).

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-GPIO-001` | `V-GPIO-CHK-001`, `V-GPIO-STM-001` |
| `GRPR-GPIO-002` | `V-GPIO-STM-002`, `V-GPIO-CHK-002` |
| `GRPR-GPIO-003` | `V-GPIO-STM-003`, `V-GPIO-COV-001` (blocked on the open pin-sharing scheme — see [GPIO Mux Verification Plan](../../verification/blocks/GPIO%20Mux%20Verification%20Plan.md)) |

See [GPIO Mux Verification Plan](../../verification/blocks/GPIO%20Mux%20Verification%20Plan.md) for the full item definitions and test list.
