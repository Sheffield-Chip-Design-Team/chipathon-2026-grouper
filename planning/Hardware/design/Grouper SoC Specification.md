# Grouper SoC Specification

**Status:** Draft, rebuilt from the [Schematic Review](../Schematic%20Review.md) (the one confirmed-authoritative planning document for this repo — see the note at the bottom of this file for why the rest of `planning/` was discarded).

This document is scoped to **integration** requirements — clocking, reset, interconnect, memory map, boot flow, and physical design. Peripheral-internal design lives in the block docs under [`blocks/`](blocks/): [UART](blocks/UART.md), [GPIO Mux](blocks/GPIO%20Mux.md), [SPI Master](blocks/SPI%20Master.md), [SPI Slave](blocks/SPI%20Slave.md), [QSPI](blocks/QSPI.md).

**Related:** [Grouper SoC Verification Plan](../../verification/Grouper%20SoC%20Verification%20Plan.md)

---

## System Overview

GrouperSoC is a picorv32 (RV32IM) based SoC for the 2026 Chipathon (GF180MCU, shared multi-team die, fabricated by wafer.space). It has 5 AHB-Lite peripherals — UART, GPIO Mux, SPI Master, SPI Slave, QSPI — a 2-level AHB-Lite interconnect, and a unified on-chip SRAM built from 4× `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros (4 KiB total).

The current RTL (`hw/rtl/`, top level `picorv32_hello_top`/`picorv32_hello_core`) is a bring-up SoC covering CPU + interconnect + ROM + RAM + UART only — it does not yet implement the target memory map or the full peripheral set described here. Divergences between this spec (the target) and the current RTL (the bring-up snapshot) are called out explicitly below rather than glossed over.

## Boot Sequence

| ID | Requirement |
|---|---|
| `GRPR-SOC-001` | On power-on-reset, the core shall begin executing from the boot ROM at the reset vector. |
| `GRPR-SOC-002` | The boot ROM shall load the program image into RAM over [UART](blocks/UART.md) — UART was chosen over SPI/QSPI for this role because it is simpler to implement in a small hand-written boot ROM. |
| `GRPR-SOC-003` | A Bank Switch Reset shall be implemented as a PCPI (PicoRV32 co-processor) custom instruction that swaps the ROM and RAM regions in the memory map. |
| `GRPR-SOC-004` | After the bank-switch reset, the CPU shall execute the just-loaded program from RAM. |
| `GRPR-SOC-005` | [SPI Master](blocks/SPI%20Master.md) and [QSPI](blocks/QSPI.md) external memory (NOR flash / PSRAM) become available as alternative/extended storage only after the initial UART-loaded program is running (QSPI NOR flash can additionally bypass this UART path entirely and boot directly from flash — see [QSPI § Purpose](blocks/QSPI.md#purpose)). |

```
Power-on Reset
  → Core executes from boot ROM (reset vector)
  → Boot ROM loads program over UART into RAM
  → Bank Switch Reset (PCPI custom instruction swaps ROM/RAM regions)
  → Program execution from RAM
```

## Memory Map

Target memory map, per the Schematic Review §3b:

| Start Address | End Address | Size | Description |
|---|---|---|---|
| `0x0000_1000` | `0x0000_1FFF` | 4 KiB | ROM (reset vector; swapped with RAM by the Bank Switch Reset instruction) |
| `0x0000_2000` | `0x0000_2FFF` | 4 KiB | RAM |
| `0x0000_3000` | `0x0000_3FFF` | 4 KiB | UART |
| `0x0000_4000` | `0x0000_4FFF` | 4 KiB | GPIO CTRL |
| `0x0000_5000` | `0x0000_5FFF` | 4 KiB | QSPI |
| `0x0000_6000` | `0x0000_6FFF` | 4 KiB | SPI M |
| `0x0000_7000` | `0x0000_7FFF` | 4 KiB | SPI S |
| `0x0001_0000` | `0x0001_FFFF` | 64 KiB | External peripheral |

`GRPR-SOC-006`: The SoC shall implement the memory map above.

**Divergence from current RTL.** `hw/rtl/interconnect/ahb_interconnect.sv` (the bring-up decoder) currently implements a different, simpler map: ROM `0x0000_0000`–`0x7FFF_FFFF`, RAM `0x8000_0000`–`0x8FFF_FFFF`, UART `0x9000_0000`–`0x9000_000F` (plus an optional debug slave at `0xF000_0000`–`0xFFFF_FFFF` under `` `DEFINE_PERIPH` ``). This bring-up decode has none of the 4 KiB-per-peripheral structure above and was never intended to be final — it will need to be replaced with the target map as SPI Master/Slave, QSPI, and GPIO Mux land.

## Interconnect Architecture

| ID | Requirement |
|---|---|
| `GRPR-SOC-007` | The interconnect shall be a 2-level, single-master AHB-Lite fabric. |
| `GRPR-SOC-008` | **L1 fabric** — a register stage breaking up the long combinatorial path between the CPU address bus and the RAM address line. **Not yet present in the current bring-up RTL** — `hw/rtl/sram/ahb_ram.sv` is currently decoded directly off the L2 decoder with no separate L1 register stage. |
| `GRPR-SOC-009` | **L2 fabric** — an AHB-Lite decoder fanning out to the remaining peripherals. `hw/rtl/interconnect/ahb_interconnect.sv` + `hw/rtl/periph/periph_ss.sv` |
| `GRPR-SOC-010` | Single master: PicoRV32, via a custom AHB-Lite wrapper (`hw/rtl/cpu/cpu_ss.sv`) converting picorv32's native `mem_*`/`mem_la_*` interface to AHB-Lite. No arbitration is needed (single master). |

**Open item — CPU ISA variant mismatch.** The Schematic Review's interconnect diagram labels the CPU "RV32EMC" (implying the E — reduced register — and C — compressed — extensions). The actual RTL configuration (`hw/rtl/cpu/cpu_ss.sv`) instantiates picorv32 with `ENABLE_REGS_16_31=1` (full 32 registers, not the E variant), `COMPRESSED_ISA=0` (no C extension), and `ENABLE_MUL=1`/`ENABLE_DIV=1` (M extension enabled) — i.e. the real core is **RV32IM** (for the software demo), not RV32EMC.

## Clocking / Reset Architecture

| ID | Requirement |
|---|---|
| `GRPR-SOC-011` | The SoC shall operate from a 16MHz single clock domain (no divided/gated internal clock domains in the current design). |

| `GRPR-SOC-012` | Reset shall be active-low (`HRESETn`/`rst_n`), asynchronous assert / synchronous de-assert, distributed to all synchronous logic. |


## Boot Flow 
TODO



## Interrupt Handling Scheme
TODO



## GPIO Multiplexing Scheme
TODO



## Debug/Test Features
TODO



## Physical Design Requirements

| ID | Requirement |
|---|---|
| `GRPR-SOC-013` | Target process: GF180MCU, fabricated via the 2026 Chipathon / wafer.space shared-die shuttle. |
| `GRPR-SOC-014` | Unified CPU SRAM: 4 KiB total, implemented as 4× `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros (1024 × 8-bit words each, with byte/bit write enables) — see `ip/gf180mcu_ocd_ip_sram/`. |
| `GRPR-SOC-015` | GrouperSoC's RTL occupies a bounded area/pad allocation within a shared multi-team chipathon die. Exact pad list and die placement are **not yet documented** 
| `GRPR-SOC-016` | Total gate-equivalent (GE) area is the sum of the 5 peripheral block estimates plus CPU/interconnect/SRAM overhead (not separately estimated yet). Of the 5 blocks, only [SPI Master](blocks/SPI%20Master.md#size-estimate) has a stated estimate (1,500–2,000 GE); UART, GPIO Mux, SPI Slave, and QSPI are all TBD pending RTL/synthesis. **ESTIMATE: 1.4 * 1.4mm** 

## System Integration Requirements Trace

Each integration requirement above depends on requirements defined in the block-level docs:

| Integration Req | Depends on Block Requirements |
|---|---|
| `GRPR-SOC-002` (UART boot load) | `GRPR-UART-001`…`GRPR-UART-011` (full UART register/protocol behavior) |
| `GRPR-SOC-005` (post-boot external storage) | `GRPR-SPIM-001`…`GRPR-SPIM-015`, `GRPR-QSPI-001`…`GRPR-QSPI-021` |
| `GRPR-SOC-006` (target memory map) | `GRPR-UART-001` (UART register region), `GRPR-SPIS-006` (SPI Slave 4 KiB region), block address decode in each of the 5 block docs |
| `GRPR-SOC-009` (L2 fabric / peripheral fan-out) | All 5 blocks' `GRPR-*-001`-class AHB-Lite subordinate requirements |
| `GRPR-SOC-011`/clock-plan open item | `GRPR-SPIM-010`, `GRPR-QSPI-016` (both blocked on the same unresolved clock-frequency question) |
| `GRPR-SOC-015` (pad budget) | External-pin requirements in [SPI Master](blocks/SPI%20Master.md#ios-and-external-interfaces), [SPI Slave](blocks/SPI%20Slave.md#ios-and-external-interfaces), [QSPI](blocks/QSPI.md#ios-and-external-interfaces), and the [GPIO Mux](blocks/GPIO%20Mux.md#purpose) pin-sharing role that ties them together |

## Open Items (integration-level)

- Boot ROM / reset-vector address discrepancy (`0x0001_0000` vs `0x0000_1000`) — see Boot Sequence.

- L1 register-stage fabric doesn't exist in current RTL — see Interconnect Architecture.

- CPU ISA label mismatch (RV32EMC diagram label vs. actual RV32IM RTL config) — see Interconnect Architecture.

- No pad list / die placement — see Physical Design Requirements.
- No total area estimate — 4 of 5 blocks have no GE figure yet.

- GPIO Mux pin-sharing scheme (which physical pins are shared across SPI M/S, QSPI, UART, and how ownership/priority is arbitrated) is undocumented — see [GPIO Mux § Open Items](blocks/GPIO%20Mux.md#open-items).

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-SOC-001` | `V-SOC-STM-001`, `V-SOC-CHK-001` |
| `GRPR-SOC-002` | `V-SOC-STM-002`, `V-SOC-CHK-002` |
| `GRPR-SOC-003` | `V-SOC-STM-003`, `V-SOC-CHK-003` |
| `GRPR-SOC-004` | `V-SOC-CHK-004` |
| `GRPR-SOC-005` | `V-SOC-STM-004`, `V-SOC-CHK-005` |
| `GRPR-SOC-006` | `V-SOC-STM-005`, `V-SOC-COV-001` |
| `GRPR-SOC-007` | `V-SOC-CHK-006` |
| `GRPR-SOC-008` | `V-SOC-CHK-007` (blocked — L1 fabric not yet implemented) |
| `GRPR-SOC-009` | `V-SOC-STM-006`, `V-SOC-CHK-008` |
| `GRPR-SOC-010` | `V-SOC-CHK-009` |
| `GRPR-SOC-011` | `V-SOC-CHK-010` (blocked on open clock-plan question) |
| `GRPR-SOC-012` | `V-SOC-STM-007`, `V-SOC-CHK-011` |
| `GRPR-SOC-013`–`GRPR-SOC-016` | *(physical design — not covered by functional verification; tracked as synthesis/PD signoff items, not simulation checks)* |

See [Grouper SoC Verification Plan](../../verification/Grouper%20SoC%20Verification%20Plan.md) for the full item definitions and test list.

---
