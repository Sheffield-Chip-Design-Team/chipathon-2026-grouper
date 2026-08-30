# Grouper SoC Specification

**Status:** Draft, rebuilt from the [Schematic Review](../Schematic%20Review.md) (the one confirmed-authoritative planning document for this repo — see the note at the bottom of this file for why the rest of `planning/` was discarded).

This document is scoped to **integration** requirements — clocking, reset, interconnect, memory map, boot flow, and physical design. Peripheral-internal design lives in the block docs under [`blocks/`](blocks/): [UART](blocks/UART%20Specification.md), [GPIO Mux](blocks/GPIO%20Mux%20Specification.md), [SPI Master](blocks/SPI%20Master%20Specification.md), [SPI Slave](blocks/SPI%20Slave%20Specification.md), [QSPI](blocks/QSPI%20Specification.md).

**Related:** [Grouper SoC Verification Plan](../verification/Grouper%20SoC%20Verification%20Plan.md)

---

## System Overview

GrouperSoC is a picorv32 (RV32IM) based SoC for the 2026 Chipathon (GF180MCU, shared multi-team die, fabricated by wafer.space). It has 5 AHB-Lite peripherals — UART, GPIO Mux, SPI Master, SPI Slave, QSPI — a 2-level AHB-Lite interconnect, and a unified on-chip SRAM built from 4× `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros (4 KiB total).

The current RTL (`hw/rtl/`, top level `picorv32_hello_top`/`picorv32_hello_core`) is a bring-up SoC covering CPU + interconnect + ROM + RAM + UART only — it does not yet implement the target memory map or the full peripheral set described here. Divergences between this spec (the target) and the current RTL (the bring-up snapshot) are called out explicitly below rather than glossed over.

## Boot Sequence

| ID | Requirement |
|---|---|
| `GRPR-SOC-001` | On power-on-reset, the core shall begin executing from the boot ROM at the reset vector. |
| `GRPR-SOC-002` | The boot ROM shall support loading the program image into RAM over [UART](blocks/UART%20Specification.md) — UART was chosen over SPI/QSPI for this role because it is simpler to implement in a small hand-written boot ROM. This is one of two supported load paths; the other is the debug-unit path of `GRPR-SOC-022`. |
| `GRPR-SOC-003` | A Bank Switch Reset shall be implemented as a PCPI (PicoRV32 co-processor) custom instruction that swaps the ROM and RAM regions in the memory map. |
| `GRPR-SOC-004` | After the bank-switch reset, the CPU shall execute the just-loaded program from RAM. |
| `GRPR-SOC-005` | [SPI Master](blocks/SPI%20Master%20Specification.md) and [QSPI](blocks/QSPI%20Specification.md) external memory (NOR flash / PSRAM) become available as alternative/extended storage only after the initial UART-loaded program is running (QSPI NOR flash can additionally bypass this UART path entirely and boot directly from flash — see [QSPI § Purpose](blocks/QSPI%20Specification.md#purpose)). This requirement concerns the SPI *Master* and QSPI storage interfaces; it does not constrain the SPI *Slave* debug-transport boot path of `GRPR-SOC-022`, which is a separate mechanism. |

```
Power-on Reset
  → Debug strap (pad 15) sampled; if high, debug access armed in hardware
  → Core executes from boot ROM (reset vector)
  → Boot ROM arms the debug consent gates and the SPI-slave pads
  │
  ├─ (a) UART path
  │      Boot ROM loads program over UART into RAM
  │
  └─ (b) Debug path
         External host takes a reset-style lock over a debug transport,
         writes the image straight into RAM, sets the bank switch, releases
  │
  → Bank Switch Reset (swaps ROM/RAM regions)
  → Program execution from RAM
```

Path (b) is reachable only after the boot ROM has run far enough to arm the
gates (`GRPR-SOC-023`), so it is not a cold-silicon recovery mechanism. See
[Debug Unit `DBG-SPEC-001`](blocks/Debug%20Unit.md#open-items).

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
| `0x0000_8000` | `0x0000_8FFF` | 4 KiB | [Debug Unit](blocks/Debug%20Unit.md) |
| `0x0001_0000` | `0x0001_FFFF` | 64 KiB | External peripheral |

`GRPR-SOC-006`: The SoC shall implement the memory map above.

**Divergence from current RTL.** `hw/rtl/interconnect/ahb_interconnect.sv` (the bring-up decoder) currently implements a different, simpler map: ROM `0x0000_0000`–`0x7FFF_FFFF`, RAM `0x8000_0000`–`0x8FFF_FFFF`, UART `0x9000_0000`–`0x9000_000F` (plus an optional debug slave at `0xF000_0000`–`0xFFFF_FFFF` under `` `DEFINE_PERIPH` ``). This bring-up decode has none of the 4 KiB-per-peripheral structure above and was never intended to be final — it will need to be replaced with the target map as SPI Master/Slave, QSPI, and GPIO Mux land.

## Interconnect Architecture

| ID | Requirement |
|---|---|
| `GRPR-SOC-007` | The interconnect shall be a 2-level AHB-Lite fabric with a single manager *at a time*. Two managers are possible — the CPU and the [Debug Unit](blocks/Debug%20Unit.md) — but never concurrently: ownership transfers wholesale and exclusively, so the fabric itself still sees one manager and needs no arbitration. |
| `GRPR-SOC-008` | **L1 fabric** — a register stage breaking up the long combinatorial path between the CPU address bus and the RAM address line. **Not yet present in the current bring-up RTL** — `hw/rtl/sram/ahb_ram.sv` is currently decoded directly off the L2 decoder with no separate L1 register stage. |
| `GRPR-SOC-009` | **L2 fabric** — an AHB-Lite decoder fanning out to the remaining peripherals. `hw/rtl/interconnect/ahb_interconnect.sv` + `hw/rtl/periph/periph_ss.sv` |
| `GRPR-SOC-010` | The default manager is PicoRV32, via a custom AHB-Lite wrapper (`hw/rtl/cpu/cpu_ss.sv`) converting picorv32's native `mem_*`/`mem_la_*` interface to AHB-Lite. The [Debug Unit](blocks/Debug%20Unit.md) may take ownership from it under `GRPR-DBG-006`. **No arbiter is implemented, and none shall be**: ownership is exclusive and swaps as a unit, so at most one manager is ever active. |

**Open item — CPU ISA variant mismatch.** The Schematic Review's interconnect diagram labels the CPU "RV32EMC" (implying the E — reduced register — and C — compressed — extensions). The actual RTL configuration (`hw/rtl/cpu/cpu_ss.sv`) instantiates picorv32 with `ENABLE_REGS_16_31=1` (full 32 registers, not the E variant), `COMPRESSED_ISA=0` (no C extension), and `ENABLE_MUL=1`/`ENABLE_DIV=1` (M extension enabled) — i.e. the real core is **RV32IM** (for the software demo), not RV32EMC.

## Clocking / Reset Architecture

| ID | Requirement |
|---|---|
| `GRPR-SOC-011` | The SoC shall operate from a 16MHz single clock domain (no divided/gated internal clock domains in the current design). |

| `GRPR-SOC-012` | Reset shall be active-low (`HRESETn`/`rst_n`), asynchronous assert / synchronous de-assert, distributed to all synchronous logic. |


## Boot Flow

Two paths load a program image into RAM. Both end the same way, at the bank
switch, so only the load differs.

**(a) UART path** — the default, and the only one available before the boot ROM
has run. The ROM polls the UART for the command protocol implemented in
`sw/boot/bootloader.c` (`'R'` read, `'W'` write, `'B'` bank-switch and reboot),
writes the image into RAM, then swaps banks.

**(b) Debug-transport path** — an external host takes a reset-style lock
through a debug transport, writes the image straight into RAM through the
[Debug Unit](blocks/Debug%20Unit.md), sets the bank-switch register, and
releases the lock. The CPU comes out of reset executing the loaded image. No
UART traffic is involved and the CPU is held throughout, so there is no
contention for RAM.

| ID | Requirement |
|---|---|
| `GRPR-SOC-022` | The SoC shall support an alternate boot path in which an external host acquires a reset-style lock through a debug transport, writes a program image into RAM, sets the bank-switch register, and releases the lock, after which the CPU executes the loaded image. This path shall not require the UART load of `GRPR-SOC-002`. |
| `GRPR-SOC-023` | The boot ROM shall arm the debug consent gates (`CTRL.LOCK_EN` in the Debug Unit, `CTRL.DEBUG_PORT_EN` in the transport) and assign the transport's pads their alternate function, before entering its UART load loop, so that the path of `GRPR-SOC-022` is reachable on a chip strapped for normal boot. This shall not raise the boot ROM's stack usage above zero bytes. |
| `GRPR-SOC-024` | GPIO pad 15 shall be sampled at reset release as a debug strap. When sampled high, the SoC shall arm debug access in hardware: pads 0–3 shall be given their SPI-slave alternate function, and the Debug Unit's `CTRL.LOCK_EN` and the transport's `CTRL.DEBUG_PORT_EN` shall come out of reset set. When sampled low, reset values shall be as specified elsewhere in this document and pad 15 shall behave as ordinary GPIO. |
| `GRPR-SOC-025` | The sampled strap value shall be captured in a register readable by firmware and by the Debug Unit, and shall not change until the next reset. Pad 15 shall be usable as ordinary GPIO after the sample without affecting the captured value. |
| `GRPR-SOC-026` | Debug access armed by the strap shall be revocable by firmware: a write clearing `CTRL.LOCK_EN` or `CTRL.DEBUG_PORT_EN` shall take effect normally regardless of how they were armed. The strap sets the reset value; it does not lock the gates open. |

The zero-stack constraint in `GRPR-SOC-023` is not incidental:
`sw/scripts/build_bootloader.sh` enforces a `-fstack-usage` budget of 0 and the
bootloader is written to hold it (leaf-only, `always_inline`, `-ffixed-s0
-ffixed-s1`). A single non-inlined call added to the ROM breaks the build. Any
arming code must be inline register writes.

**Cold-silicon access via the debug strap.** Path (b) has two ways in. On a
normally strapped chip the boot ROM arms the gates (`GRPR-SOC-023`), so debug
access becomes available shortly after reset but does depend on the ROM
running. Holding **GPIO pad 15 high at reset** instead arms debug access in
hardware (`GRPR-SOC-024`) — pads 0–3 take their SPI-slave function and both
consent gates come up set — with no firmware involvement at all. That makes the
path usable on a chip whose ROM does not execute, which is the case that
matters for bring-up and recovery.

Strapping is a deliberate middle ground. Arming debug unconditionally would let
stray pad activity at power-on halt the CPU; requiring firmware alone would
make a non-booting chip unreachable. A strap costs one pad — the spare — and
puts the choice in the hands of whoever builds the board. Note that it is an
access-control decision, not an authentication one: a board that strapped debug
on is open to anyone who can reach its pins (`GRPR-DBG-INFO-002`).



## Interrupt Handling Scheme
TODO


## GPIO Multiplexing Scheme

### Pin Assignment

15 of the 16 pads carry an alternate function. Direction is given from the pad's point of view.

| Pad | Alternate Function | Alternative Function Direction |
|---|---|---|
| 0 | `spi_s_ss` | in |
| 1 | `spi_s_sck` | in |
| 2 | `spi_s_mosi` | in |
| 3 | `spi_s_miso` | out |
| 4 | `spi_m_ss` | out |
| 5 | `spi_m_sck` | out |
| 6 | `spi_m_mosi` | out |
| 7 | `spi_m_miso` | in |
| 8 | `qspi_sck` | out |
| 9 | `qspi_ce_n[0]` | out |
| 10 | `qspi_ce_n[1]` | out |
| 11 | `qspi_sio[0]` | bidir |
| 12 | `qspi_sio[1]` | bidir |
| 13 | `qspi_sio[2]` | bidir |
| 14 | `qspi_sio[3]` | bidir |
| 15 | `dbg_strap` — sampled at reset, then GPIO | in |

**Pad ownership at reset.** All pads default to GPIO, not to their alternate
function — with one exception. Pad 15, otherwise the spare, is sampled at reset
as the **debug strap** (`GRPR-SOC-024`). When it is high at reset release, the
SoC arms debug access in hardware: pads 0–3 take their SPI-slave alternate
function and the debug consent gates come up set, with no firmware involvement.
When it is low — the normal case, and the state a pull-down gives — everything
behaves exactly as before and pad 15 reverts to ordinary GPIO after the sample.

This is what makes the debug boot path reachable on cold silicon, including on
a chip whose boot ROM does not run.


## Debug/Test Features

Debug access is provided by the [Debug Unit](blocks/Debug%20Unit.md), reached
through a debug transport — initially the
[SPI Slave](blocks/SPI%20Slave%20Specification.md). The unit can take the
system bus from the CPU, drive any peripheral or memory location, and control
CPU execution: halt, read back state, single-step, redirect, and resume.

*(Not to be confused with `ahb_debug`, the simulation-only printf and trace
sink built under `DEBUG_PERIPH`. That block does not exist in silicon.)*

| ID | Requirement |
|---|---|
| `GRPR-SOC-017` | The SoC shall instantiate a debug unit positioned so that both the CPU's AHB manager port and the CPU's RAM port pass through it. The unit is in series on those paths, not a leaf peripheral on the fabric. |
| `GRPR-SOC-018` | The debug unit shall additionally be an AHB subordinate on the peripheral fabric, occupying its own 4 KiB decode window, so firmware can read its status and configure its consent gates. |
| `GRPR-SOC-019` | The CPU subsystem shall expose the hooks the debug unit requires: a stall input, a reset input, a runtime reset vector, an instruction-retirement indication, a program-counter output, and a register-file read port. |
| `GRPR-SOC-020` | CPU freeze shall be implemented by gating the CPU's memory-interface ready signal, **not** by holding AHB `HREADY` low. The CPU does not stall on ROM- or RAM-sourced accesses, so `HREADY` alone would not stop it. |
| `GRPR-SOC-021` | Single-step shall release the freeze for exactly one instruction retirement and reassert it. The retirement indication shall come from the CPU, not be inferred from bus activity — not every instruction produces a bus transfer, and some produce several, so a bus-activity heuristic miscounts. |

### CPU requirements

The debug unit's CPU-facing requirements need core support that upstream
picorv32 does not provide. `ip/picorv32` is a team fork
(`Sheffield-Chip-Design-Team/picorv32`), so these are available to implement,
at an area cost that should be measured before they are committed to.

| ID | Requirement |
|---|---|
| `GRPR-CPU-001` | The CPU shall expose a debug register read port — an index input and a 32-bit data output returning the selected general-purpose register. On this RV32E configuration (`ENABLE_REGS_16_31 = 0`) only `x0`–`x15` exist. |
| `GRPR-CPU-003` | The CPU shall expose its current program counter and an instruction-retirement indication for debug use. |

`GRPR-CPU-003` deserves scrutiny on area. picorv32's existing `trace_valid`
output is the obvious retirement signal, but it exists only when the core is
built with `ENABLE_TRACE`, which is currently off in silicon
(`hw/rtl/cpu_ss.sv`). Enabling it adds trace logic to the CPU. Single-stepping
is the more valuable of the two features and should not be made to depend on
trace — if trace is dropped for area, a dedicated retirement output is needed
instead. See [Debug Unit `DBG-SPEC-006`](blocks/Debug%20Unit.md#open-items).

**Topology note.** Placing the debug unit in series on the CPU's RAM path adds
delay to what `GRPR-SOC-008` already identifies as the long combinational path
in the design. The ownership mux should be combinational and thin; a registered
mux would break `cpu_ss`'s single-cycle RAM assumption and require that logic
reworked. Flag this for the P&R flow — see
[Debug Unit `DBG-SPEC-003`](blocks/Debug%20Unit.md#open-items).


## Physical Design Requirements

| ID | Requirement |
|---|---|
| `GRPR-SOC-013` | Target process: GF180MCU, fabricated via the 2026 Chipathon / wafer.space shared-die shuttle. |
| `GRPR-SOC-014` | Unified CPU SRAM: 4 KiB total, implemented as 4× `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros (1024 × 8-bit words each, with byte/bit write enables) — see `ip/gf180mcu_ocd_ip_sram/`. |
| `GRPR-SOC-015` | GrouperSoC needs **20 signal pads**: 1 clock, 1 reset, 1 UART RX (input-only), and 17 bidirectional (16 GPIO + 1 UART TX). See the Pad List below. Die placement within the shared multi-team die is still TBD. |
| `GRPR-SOC-016` | Total gate-equivalent (GE) area is the sum of the 5 peripheral block estimates plus CPU/interconnect/SRAM overhead (not separately estimated yet). Of the 5 blocks, only [SPI Master](blocks/SPI%20Master%20Specification.md#size-estimate) has a stated estimate (1,500–2,000 GE); UART, GPIO Mux, SPI Slave, and QSPI are all TBD pending RTL/synthesis. **ESTIMATE: 1.4 * 1.4mm** |

### Pad List

Derived from `hw/pd/grouper_soc_chip_core.sv` (pad↔SoC wiring) and `hw/pd/grouper_soc_chip_top.sv` (pad cell types). Side placement is for the **1x1** slot, per `librelane/chip/slots/slot_1x1.yaml`.

#### Dedicated pads

| Pad | Cell | Dir | Function | Side |
|---|---|---|---|---|
| `clk_PAD` | `gf180mcu_fd_io__in_s` | in | System clock. Schmitt-trigger input; `PU`/`PD` tied off. | South |
| `rst_n_PAD` | `gf180mcu_fd_io__in_c` | in | Asynchronous reset, active low. `PU`/`PD` tied off. | South |

#### Input-only pads

| Pad | Cell | Dir | Function | Side |
|---|---|---|---|---|
| `input_PAD[0]` | `gf180mcu_fd_io__in_c` | in | `uart_rx` | West |
| `input_PAD[n:1]` | `gf180mcu_fd_io__in_c` | — | Unused. `input_pu`/`input_pd` tied 0, value unread. | West |

#### Bidirectional pads

All `gf180mcu_fd_io__bi_24t`. For pads 0–14 the GPIO controller drives every pad control (`out`/`oe`/`cs`/`sl`/`ie`/`pu`/`pd`), and `GPIO_ALTSEL` selects between the GPIO register value and the alternate function — see [Pin Assignment](#pin-assignment).

| Pad | GPIO | Alternate Function | Alt Dir | Side |
|---|---|---|---|---|
| `bidir_PAD[0]` | `gpio[0]` | `spi_s_ss`   | in | South |
| `bidir_PAD[1]` | `gpio[1]` | `spi_s_sck`  | in | South |
| `bidir_PAD[2]` | `gpio[2]` | `spi_s_mosi` | in | South |
| `bidir_PAD[3]` | `gpio[3]` | `spi_s_miso` | out | South |
| `bidir_PAD[4]` | `gpio[4]` | `spi_m_ss`   | out | South |
| `bidir_PAD[5]` | `gpio[5]` | `spi_m_sck`  | out | South |
| `bidir_PAD[6]` | `gpio[6]` | `spi_m_mosi` | out | South |
| `bidir_PAD[7]` | `gpio[7]` | `spi_m_miso` | in | South |
| `bidir_PAD[8]` | `gpio[8]` | `qspi_sck`   | out | South |
| `bidir_PAD[9]` | `gpio[9]` | `qspi_ce_n[0]` | out | South |
| `bidir_PAD[10]` | `gpio[10]` | `qspi_ce_n[1]` | out | South |
| `bidir_PAD[11]` | `gpio[11]` | `qspi_sio[0]` | bidir | South |
| `bidir_PAD[12]` | `gpio[12]` | `qspi_sio[1]` | bidir | South |
| `bidir_PAD[13]` | `gpio[13]` | `qspi_sio[2]` | bidir | South |
| `bidir_PAD[14]` | `gpio[14]` | `qspi_sio[3]` | bidir | East |
| `bidir_PAD[15]` | `gpio[15]` | none — GPIO only | — | East |
| `bidir_PAD[16]` | — | `uart_tx` | out | East |
| `bidir_PAD[n:17]` | — | Unused | — | East / North |

`bidir_PAD[16]` is a permanent output: `oe` tied 1, `ie`/`cs`/`sl`/`pu`/`pd` tied 0. Spare pads above it are driven low (`out=0`, `oe=1`) with `ie=0` so they never float.


## System Integration Requirements Trace

Each integration requirement above depends on requirements defined in the block-level docs:

| Integration Req | Depends on Block Requirements |
|---|---|
| `GRPR-SOC-002` (UART boot load) | `GRPR-UART-001`…`GRPR-UART-011` (full UART register/protocol behavior) |
| `GRPR-SOC-005` (post-boot external storage) | `GRPR-SPIM-001`…`GRPR-SPIM-015`, `GRPR-QSPI-001`…`GRPR-QSPI-021` |
| `GRPR-SOC-006` (target memory map) | `GRPR-UART-001` (UART register region), `GRPR-SPIS-006` (SPI Slave 4 KiB region), block address decode in each of the 5 block docs |
| `GRPR-SOC-009` (L2 fabric / peripheral fan-out) | All 5 blocks' `GRPR-*-001`-class AHB-Lite subordinate requirements |
| `GRPR-SOC-011`/clock-plan open item | `GRPR-SPIM-010`, `GRPR-QSPI-016` (both blocked on the same unresolved clock-frequency question) |
| `GRPR-SOC-015` (pad budget) | External-pin requirements in [SPI Master](blocks/SPI%20Master%20Specification.md#ios-and-external-interfaces), [SPI Slave](blocks/SPI%20Slave%20Specification.md#ios-and-external-interfaces), [QSPI](blocks/QSPI%20Specification.md#ios-and-external-interfaces), and the [GPIO Mux](blocks/GPIO%20Mux%20Specification.md#purpose) pin-sharing role that ties them together |
| `GRPR-SOC-017`/`-018` (debug unit placement and window) | `GRPR-DBG-001`, `GRPR-DBG-002`, `GRPR-DBG-008` |
| `GRPR-SOC-019`…`-021` (CPU hooks, freeze, step) | `GRPR-DBG-019`…`-027`, `GRPR-CPU-001`/`-003` |
| `GRPR-SOC-022` (alternate boot path) | `GRPR-DBG-006`…`-020`, `GRPR-SPIS-014`…`-019` |
| `GRPR-SOC-023` (boot ROM arms the gates) | `GRPR-DBG-007`, `GRPR-SPIS-016`, `GRPR-SPIS-020` |
| `GRPR-SOC-024`…`-026` (debug strap) | `GRPR-DBG-007`, `GRPR-DBG-022`, `GRPR-SPIS-016`, and the [GPIO Mux](blocks/GPIO%20Mux%20Specification.md) pad-assignment behaviour |

## Open Items (integration-level)

- **Debug strap needs a board-level pull-down.** `GRPR-SOC-024` arms debug
  access when pad 15 is high at reset, so a floating pad 15 could arm it by
  accident. The pad's own programmable pull-down is not established until
  firmware configures it, which is after the sample. This needs either a
  reset-default pull-down on that pad or a stated board requirement — decide
  which before tape-out.
- **Debug unit area is unbudgeted.** The block adds a register file, an AHB
  manager FSM, two ownership muxes, and CPU-side changes, on a die where the
  SPI Master slot is budgeted at 1706 GE. Needs a synthesis estimate before the
  specification is frozen.
- **In-series topology timing.** See the note in § Debug/Test Features and
  [Debug Unit `DBG-SPEC-003`](blocks/Debug%20Unit.md#open-items).

- Boot ROM / reset-vector address discrepancy (`0x0001_0000` vs `0x0000_1000`) — see Boot Sequence.

- L1 register-stage should be moved away from AHB bus.

- CPU ISA label mismatch (RV32EMC diagram label vs. actual RV32IM RTL config) — see Interconnect Architecture.

- Die placement within the shared multi-team die is undecided. The pad list itself is now documented — see [Pad List](#pad-list).
- No total area estimate — 4 of 5 blocks have no GE figure yet.

- GPIO Mux pin-sharing scheme (which physical pins are shared across SPI M/S, QSPI, UART, and how ownership/priority is arbitrated) is undocumented — see [GPIO Mux § Open Items](blocks/GPIO%20Mux%20Specification.md#open-items).

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
| `GRPR-SOC-017` | `V-SOC-CHK-017` (debug unit is in series on both CPU paths) |
| `GRPR-SOC-018` | `V-SOC-CHK-018` (decode window reachable from firmware) |
| `GRPR-SOC-019` | `V-SOC-CHK-019` (CPU hooks present and connected) |
| `GRPR-SOC-020` | `V-SOC-STM-017`, `V-SOC-CHK-020` (freeze stops a CPU running from ROM/RAM, which `HREADY` alone would not) |
| `GRPR-SOC-021` | `V-SOC-STM-018`, `V-SOC-CHK-021` (exact instruction counts, against the real CPU) |
| `GRPR-SOC-022` | `V-SOC-STM-019`, `V-SOC-CHK-022` — the alternate-boot acceptance test: load an image over a debug transport, bank switch, release, confirm it executes |
| `GRPR-SOC-023` | `V-SOC-CHK-023` (gates armed by the ROM; bootloader stack usage still 0) |
| `GRPR-SOC-024` | `V-SOC-STM-020`, `V-SOC-CHK-024` — strap high and low at reset; with it high, debug is reachable **with the boot ROM held or absent**, which is the case this requirement exists for |
| `GRPR-SOC-025` | `V-SOC-CHK-025` (strap value latched, readable, stable while pad 15 is driven as GPIO afterwards) |
| `GRPR-SOC-026` | `V-SOC-CHK-026` (firmware can clear a strap-armed gate) |
| `GRPR-SOC-012` | `V-SOC-STM-007`, `V-SOC-CHK-011` |
| `GRPR-SOC-013`–`GRPR-SOC-016` | *(physical design — not covered by functional verification; tracked as synthesis/PD signoff items, not simulation checks)* |

See [Grouper SoC Verification Plan](../verification/Grouper%20SoC%20Verification%20Plan.md) for the full item definitions and test list.

---
