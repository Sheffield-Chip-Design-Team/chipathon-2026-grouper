# AHB SPI Slave

**Owner:** Thiri
**Status:** RTL design starting (per [Schematic Review](../../Schematic%20Review.md) §4). No RTL committed yet under `hw/rtl/`.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence, memory map | [SPI Slave Verification Plan](../../verification/blocks/SPI%20Slave%20Verification%20Plan.md)

---

## Purpose

SPI slave interface that lets an external SPI master (a host controller — device not named in the source) communicate with the SoC through the AHB-Lite bus, including a dedicated firmware-load path into RAM (`fw_ld_addr`/`fw_ld_wdata`/`fw_ld_we` signals appear in the block diagram description). This block references the APS6404L datasheet the same way SPI Master and QSPI do — the most consistent reading (not explicitly stated in the source, flagged as inferred) is that this block presents an APS6404L-compatible command interface *to* the external host, so a host that already speaks the PSRAM SPI protocol can read/write GrouperSoC's memory without a bespoke protocol.

## Protocols / Standards Conformity

| ID | Requirement |
|---|---|
| `GRPR-SPIS-001` | AHB-Lite subordinate interface on the CPU side. |
| `GRPR-SPIS-002` | Custom SPI slave interface on the external side: CPOL/CPHA mode 0/3, MSB-first transfer on MISO. |
| `GRPR-SPIS-003` | Command set shall be compatible with the APS6404L datasheet's SPI-mode commands (see Purpose note on the inferred host-facing PSRAM-emulation role). |

## Key Functionality

| ID | Requirement |
|---|---|
| `GRPR-SPIS-004` | The block shall receive and transmit data over the SPI interface, with that data accessible through the AHB-Lite bus. |
| `GRPR-SPIS-005` | The block shall support `SPI_READ`, `FAST_READ`, `SPI_WRITE`, and `FAST_WRITE` commands. |

## Block Diagram

Main blocks: Shift Register, Register Bank, AHB Bus Logic, Command FSM Control. A dedicated firmware-load path exists in parallel with normal register access: `SS` (slave select)

TODO

## uARCH Diagram

TODO


## Parameters and Configurations

FIXME

| ID | Requirement |
|---|---|
| `GRPR-SPIS-007` |  |
| `GRPR-SPIS-008` |  |

## IOs and External Interfaces

AHB-Lite bus interface plus the external SPI slave pins (`SS`, `SCK`, `MOSI`, `MISO`, per standard SPI slave convention — exact pin names not given in the source). External pin ownership depends on the still-undefined [GPIO Mux](GPIO%20Mux.md) pin-sharing scheme.

## Register Map

| Offset | Name | Access | Reset | Purpose |
|--------|------|--------|-------|---------|
| 0x00 | CTRL | R/W | 0x0000_0000 | Enable and reset SPI slave |
| 0x04 | STATUS | RO | 0x0000_0000 | Current SPI status |
| 0x08 | TXDATA | WO | - | Data sent to external SPI master |
| 0x0C | RXDATA | RO | - | Data received from external SPI master |

Unlisted bits are reserved: read 0, write 0.

## CTRL — 0x00

| Bits | Field | Access | Description |
|------|-------|--------|-------------|
| 0 | ENABLE | R/W | Enable SPI slave peripheral |
| 1 | SOFT_RESET | WO | Software reset the SPI slave state machine to its default state |
| 2 | CPHA  | R/W |  |
| 3 | CPOL  | R/W |  |
| 31:4 | Reserved | - | Read 0, write 0 |

Writing 1 to SOFT_RESET resets the SPI slave state machine. The bit self-clears after the reset completes.

## STATUS — 0x04

| Bits | Field | Access | Description |
|------|-------|--------|-------------|
| 0 | BUSY | RO | SPI transaction in progress |
| 1 | RX_VALID | RO | New received byte available |
| 2 | TX_READY | RO | Ready to provide transmit byte |
| 31:3 | Reserved | - | Read 0 |

Reset value 0x04 reflects TX_READY = 1 and BUSY = RX_VALID = 0.

## TXDATA — 0x08

| Bits | Field | Access | Description |
|------|-------|--------|-------------|
| 7:0 | DATA | WO | Byte returned to the external SPI master |
| 31:8 | Reserved | - | Read 0, write 0 |

## RXDATA — 0x0C

| Bits | Field | Access | Description |
|------|-------|--------|-------------|
| 7:0 | DATA | RO | Last byte received from the external SPI master |
| 31:8 | Reserved | - | Read 0 |

## Clocking Strategy

`GRPR-SPIS-009`: Single system clock (`clk`) for everything, per the source.

## Reset Strategy

`GRPR-SPIS-010`: Active-low reset (`rst_n`) clears and restarts the design and stops any ongoing SPI transfer.

## CDC Strategy

`GRPR-SPIS-004`: MOSI shall be externally synchronised in the GPIO MUX.

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
