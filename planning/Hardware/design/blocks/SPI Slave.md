# AHB SPI Slave

**Owner:** Safaa
**Status:** RTL design starting (per [Schematic Review](../../Schematic%20Review.md) §4). No RTL committed yet under `hw/rtl/`.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence, memory map | [SPI Slave Verification Plan](../../verification/blocks/SPI%20Slave%20Verification%20Plan.md)

---

## Purpose

SPI slave interface that lets an external SPI master (a host controller — device not named in the source) communicate with the SoC through the AHB-Lite bus, including a dedicated firmware-load path into RAM (`fw_ld_addr`/`fw_ld_wdata`/`fw_ld_we` signals appear in the block diagram description). This block references the APS6404L datasheet the same way SPI Master and QSPI do — the most consistent reading (not explicitly stated in the source, flagged as inferred) is that this block presents an APS6404L-compatible command interface *to* the external host, so a host that already speaks the PSRAM SPI protocol can read/write GrouperSoC's memory without a bespoke protocol.

## Protocols / Standards Conformity

| ID | Requirement |
|---|---|
| `GRPR-SPIS-001` | AHB-Lite subordinate interface on the CPU side. |
| `GRPR-SPIS-002` | Custom SPI slave interface on the external side: CPOL/CPHA mode 0/3, MSB-first. |
| `GRPR-SPIS-003` | Command set shall be compatible with the APS6404L datasheet's SPI-mode commands (see Purpose note on the inferred host-facing PSRAM-emulation role). |

## Key Functionality

| ID | Requirement |
|---|---|
| `GRPR-SPIS-004` | The block shall receive and transmit data over the SPI interface, with that data accessible through the AHB-Lite bus. |
| `GRPR-SPIS-005` | The block shall support `SPI_READ`, `FAST_READ`, `SPI_WRITE`, and `FAST_WRITE` commands. |

## Block Diagram

Main blocks: Shift Register, Register Bank, AHB Bus Logic, Command FSM Control. A dedicated firmware-load path exists in parallel with normal register access: `SS` (slave select), `fw_ld_addr`, `fw_ld_wdata`, `fw_ld_we`.

**Open question — relationship to the UART boot path.** The [Grouper SoC Specification § Boot Sequence](../Grouper%20SoC%20Specification.md#boot-sequence) states UART is the chosen boot-load peripheral specifically because it's simpler for a hand-written boot ROM than SPI/QSPI, and that SPI/QSPI become available "after the initial program code is loaded." But this block's own diagram shows dedicated firmware-load signals (`fw_ld_*`), which reads like a boot-time capability, not a post-boot one. Whether SPI Slave firmware-load is (a) an alternate/parallel boot path to UART, (b) a mechanism for loading a *second-stage* image after the UART-loaded first stage is running, or (c) leftover from an earlier design iteration, is not resolved by the source material — needs a direct answer before this block's firmware-load path is implemented.

## Parameters and Configurations

| ID | Requirement |
|---|---|
| `GRPR-SPIS-006` | 4 kB allocated memory block (matches the `SPI Slave`/`SPI S`... region size convention used elsewhere in the 4 KiB-per-peripheral memory map — see [Grouper SoC Specification § Memory Map](../Grouper%20SoC%20Specification.md#memory-map)). |
| `GRPR-SPIS-007` | Data shall be transferred byte-by-byte. |
| `GRPR-SPIS-008` | Hardware shall be controlled by reading/writing registers. |

## IOs and External Interfaces

AHB-Lite bus interface plus the external SPI slave pins (`SS`, `SCK`, `MOSI`, `MISO`, per standard SPI slave convention — exact pin names not given in the source). External pin ownership depends on the still-undefined [GPIO Mux](GPIO%20Mux.md) pin-sharing scheme.

## Clocking Strategy

`GRPR-SPIS-009`: Single system clock (`clk`) for everything, per the source.

**Open — internal inconsistency to double-check.** A SPI slave's `SCK` is normally driven by the external master and is therefore asynchronous to the SoC's internal clock; the source's own "single clock domain, no CDC needed" claim (see CDC Strategy below) is atypical for a SPI slave unless `SCK` is somehow phase-locked to `HCLK` by system design (as is true elsewhere in similar designs when the external master and the SoC share a clock reference) or the FSM is intentionally run in the `SCK` domain with a handshake into `HCLK` (undocumented either way). Do not assume single-clock-domain CDC-free operation without confirming which of these is actually true.

## Reset Strategy

`GRPR-SPIS-010`: Active-low reset (`rst_n`) clears and restarts the design and stops any ongoing SPI transfer.

## CDC Strategy

Source states "not needed (single clock domain)" — see the open question under Clocking Strategy above before treating this as settled.

## Performance Targets

| ID | Requirement |
|---|---|
| `GRPR-SPIS-011` | SPI clock speeds up to 10 MHz. |
| `GRPR-SPIS-012` | Firmware-load throughput up to 1.25 MB/s. |
| `GRPR-SPIS-013` | Receives one payload byte every 0.8 µs at maximum SPI clock. |

## Size Estimate

TBD (per source).

## Open Items

- Relationship between this block's firmware-load path and the UART-based boot sequence (see Block Diagram section above) — needs resolution before implementation.
- Clock-domain question for `SCK` vs. `HCLK` (see Clocking Strategy) — the "no CDC needed" claim needs justification or correction.
- External pin ownership depends on the unresolved [GPIO Mux](GPIO%20Mux.md) pin-sharing scheme.
- Size estimate not yet available.

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-SPIS-001` | `V-SPIS-STM-001`, `V-SPIS-CHK-001` |
| `GRPR-SPIS-002` | `V-SPIS-STM-002`, `V-SPIS-COV-001` |
| `GRPR-SPIS-003` | `V-SPIS-STM-003`, `V-SPIS-CHK-002` |
| `GRPR-SPIS-004` | `V-SPIS-STM-004`, `V-SPIS-CHK-003` |
| `GRPR-SPIS-005` | `V-SPIS-STM-005`, `V-SPIS-COV-002` |
| `GRPR-SPIS-006` | `V-SPIS-CHK-004` |
| `GRPR-SPIS-007` | `V-SPIS-STM-006` |
| `GRPR-SPIS-008` | `V-SPIS-STM-007`, `V-SPIS-CHK-005` |
| `GRPR-SPIS-009` | `V-SPIS-CHK-006` (blocked on the open clocking question) |
| `GRPR-SPIS-010` | `V-SPIS-STM-008`, `V-SPIS-CHK-007` |
| `GRPR-SPIS-011` | `V-SPIS-CHK-008` |
| `GRPR-SPIS-012` | `V-SPIS-CHK-009` |
| `GRPR-SPIS-013` | `V-SPIS-CHK-010` |

See [SPI Slave Verification Plan](../../verification/blocks/SPI%20Slave%20Verification%20Plan.md) for the full item definitions and test list.
