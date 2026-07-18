# AHB QSPI

**Owner:** Tristan
**Status:** RTL scaffold committed. Register map under design review; functional QSPI RTL not yet implemented.
**Source:** [Schematic Review](../../Schematic%20Review.md) §"Block-Level Design Checklists → 5. AHB QSPI", with corrections noted below.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence, memory map | [QSPI Verification Plan](../../../verification/blocks/QSPI%20Verification%20Plan.md)

---

## Purpose

AHB-Lite-controlled QPI master compatible with the APS6404L PSRAM and Micron N25Q032A NOR flash (read-only). Provides external memory for extended non-volatile/volatile storage after the initial UART boot stage. Per the boot-flow note in the Schematic Review (§3a): **NOR flash can bypass the UART-based boot-ROM code loading entirely** (boot directly from external flash), while **PSRAM extends the default UART-loaded boot flow** (extra storage available to firmware once running). Both roles are legitimate, Grouper-specific, and not part of the contamination noted above.

## Protocols / Standards Conformity

| ID | Requirement |
|---|---|
| `GRPR-QSPI-001` | AMBA 3 AHB-Lite interface on the SoC side. |
| `GRPR-QSPI-002` | Compatible with Micron N25Q032A (SPI, Quad), read-only. |
| `GRPR-QSPI-003` | Compatible with APS6404L PSRAM, which boots in SPI mode and is then configured into quad mode by the CPU. |
| `GRPR-QSPI-004` | Normal transfers use four-bit QPI mode; boot flow starts in single-bit SPI mode before CPU-driven reconfiguration into quad mode. |
| `GRPR-QSPI-005` | NOR flash access shall support bypassing the UART boot-ROM code-loading path (direct boot from flash). |
| `GRPR-QSPI-006` | PSRAM access shall be available to firmware as extended storage after the UART-loaded boot stage completes. |

## Key Functionality

| ID | Requirement |
|---|---|
| `GRPR-QSPI-007` | Single and Quad SPI support. |
| `GRPR-QSPI-008` | Manual command execution with read-back via a single command/data/control register interface, for both write and read. |
| `GRPR-QSPI-009` | Programmable clock divider, plus CPHA/CPOL (likely mode 0/3 only). |
| `GRPR-QSPI-010` | Configuration bit for single/quad SPI mode. |
| `GRPR-QSPI-011` | Configuration fields for the read command (8-bit) and write command (8-bit) opcodes. |
| `GRPR-QSPI-012` | Configuration bit to enable AHB writes to flash (in the AHB wrapper) — presumably a write-protect/enable gate distinct from the PSRAM path. |
| `GRPR-QSPI-013` | Fast-read dummy-cycle count shall be configurable. |

## Block Diagram

Main blocks: Control/Status Registers, Init + QPI Transaction FSM, Buffer/Address Control, Command/Address Data Path, SCK + SIO Direction Control. External connections route via the [GPIO Mux](GPIO%20Mux.md) to the APS6404L PSRAM and NOR flash. Key signals: `qspi_ce_n`, `qspi_sck`, `qspi_sio_i/o/oe[3:0]`; device pins `CE#`, `SCK`, `SIO[3:0]`.

## Parameters and Configurations

| ID | Requirement |
|---|---|
| `GRPR-QSPI-014` | APS6404L interface: capacity 64 Mbit / 8 MB, 23-bit byte addressing, four-bit QPI data interface, target QPI clock 32 MHz (subject to the same clock-plan open item as SPI Master — see below). Memory refresh is handled internally by the PSRAM. |

## IOs and External Interfaces

| Port | Direction | Width | Description |
|---|---|---|---|
| `HADDR`/`HBURST`/`HMASTLOCK`/`HPROT`/`HSIZE`/`HTRANS`/`HWDATA`/`HWRITE` | in | — | AHB-Lite master-driven signals |
| `HRDATA`/`HREADYOUT`/`HRESP` | out | — | AHB-Lite subordinate response |
| `HREADYIN`/`HSEL` | in | — | AHB-Lite decoder signals |
| `mosi_o` | out | — | Master OUT, Slave IN |
| `qspi_sio_i`  | in  | 4 | Master IN, Slave OUT |
| `qspi_sio_o`  | out | 4 | Master OUT, Slave IN |
| `qspi_sio_oe` | out | 4 | Chip Select Output|
| `irq`    | out | — | Combined interrupt output|

- **Internal Core command interface:** `cmd_en` (chip-enable for transaction duration), `cmd_read` (1-cycle pulse), `cmd_write` (1-cycle pulse), `cmd_wdata[7:0]`, `cmd_rdata[7:0]`, `cmd_ready`.
- **External QSPI interface** — described in the source as "three four-bit SIO buses" connecting through the GPIO mux onto the same four physical bidirectional `SIO[3:0]` pins. **Open — the source doesn't explain why there are three logical 4-bit buses onto one physical 4-bit bus (e.g. one per external device — NOR flash, PSRAM, and a third — vs. some other split); needs clarification from whoever owns this block.**

## Proposed Register Map

The QSPI block occupies a 4 KiB AHB-Lite peripheral region. The initial
microarchitecture proposes five 32-bit, word-aligned registers.

| Offset | Name | Access | Purpose |
|---|---|---|---|
| `0x00` | `CTRL` | R/W | Persistent mode, clock, opcode and protection configuration |
| `0x04` | `CMD` | R/W | Manual transaction descriptor and start control |
| `0x08` | `STATUS` | RO | Live transaction state and error reporting |
| `0x0C` | `ADDR` | R/W | External memory command address |
| `0x10` | `DATA` | R/W | Manual write data and read-back data |

The exact field positions, reset values and status/event behaviour remain
subject to design review.

## Clocking Strategy

`GRPR-QSPI-016`: QSPI control/transfer logic and SCK run from the system clock (source names this "`IQ_CLK`", which is Trouper terminology dropped here — see clock-plan open item in [SPI Master § Parameters](SPI%20Master.md#parameters-and-configurations), same 32 MHz-vs-other-values inconsistency applies to QSPI). SCK runs at the configured QPI clock rate during memory transfers and remains low while idle.

## Reset Strategy

`GRPR-QSPI-017`: Single reset, active-low async assert / sync de-assert. 
`GRPR-QSPI-018`: At startup, SCK shall run at a reduced rate (~500 kHz per source) with synchronisers enabled for reliable transfers; frequency can be raised and the 2-FF synchroniser disabled afterward for performance.

## CDC Strategy

`GRPR-QSPI-018`: Single clock domain with optional input synchronisers, handled externally in the [GPIO Mux](GPIO%20Mux.md) (consistent with SPI Master's CDC note). Cross-domain controls are registered or handshaked.

## Performance Targets

| ID | Requirement |
|---|---|
| `GRPR-QSPI-019` | QPI clock target 32 MHz (subject to the clock-plan open item). |
| `GRPR-QSPI-020` | Raw four-bit link bandwidth: 16 MB/s (arithmetic consequence of `GRPR-QSPI-019`, generically true regardless of use case). |
| `GRPR-QSPI-021` | Initialisation time ≤ 1 ms. |

## Size Estimate

TBD after RTL synthesis (per source).

## Open Items

- `GRPR-QSPI-015` — status register bit list needs a from-scratch definition for GrouperSoC's actual (non-replay) use case.
- IOs — the "three four-bit SIO buses onto one physical bus" description needs clarification.
- Clock frequency inconsistency shared with SPI Master (see [SPI Master § Parameters](SPI%20Master.md#parameters-and-configurations)) applies here too.
- No sustained-throughput / storage-sizing requirement currently exists for QSPI's real (non-replay) use case — needs deriving if one is actually needed.
- External pin ownership depends on the unresolved [GPIO Mux](GPIO%20Mux.md) pin-sharing scheme.
- Size estimate not yet available.

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-QSPI-001` | [`V-QSPI-STM-001`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-001), [`V-QSPI-CHK-001`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-001) |
| `GRPR-QSPI-002` | [`V-QSPI-STM-002`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-002), [`V-QSPI-CHK-002`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-002) |
| `GRPR-QSPI-003` | [`V-QSPI-STM-003`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-003), [`V-QSPI-CHK-003`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-003) |
| `GRPR-QSPI-004` | [`V-QSPI-STM-004`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-004), [`V-QSPI-COV-001`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-cov-001) |
| `GRPR-QSPI-005` | [`V-QSPI-STM-005`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-005), [`V-QSPI-CHK-004`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-004) |
| `GRPR-QSPI-006` | [`V-QSPI-STM-006`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-006), [`V-QSPI-CHK-005`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-005) |
| `GRPR-QSPI-007` | [`V-QSPI-STM-007`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-007), [`V-QSPI-COV-002`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-cov-002) |
| `GRPR-QSPI-008` | [`V-QSPI-STM-008`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-008), [`V-QSPI-CHK-006`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-006) |
| `GRPR-QSPI-009` | [`V-QSPI-STM-009`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-009), [`V-QSPI-COV-003`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-cov-003) |
| `GRPR-QSPI-010` | [`V-QSPI-STM-010`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-010) |
| `GRPR-QSPI-011` | [`V-QSPI-STM-011`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-011) |
| `GRPR-QSPI-012` | [`V-QSPI-STM-012`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-012), [`V-QSPI-CHK-007`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-007) |
| `GRPR-QSPI-013` | [`V-QSPI-STM-013`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-013) |
| `GRPR-QSPI-014` | [`V-QSPI-CHK-008`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-008) |
| `GRPR-QSPI-015` | [`V-QSPI-CHK-009`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-009) (blocked on open status-bit definition) |
| `GRPR-QSPI-016` | [`V-QSPI-CHK-010`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-010) (blocked on open clock-plan question) |
| `GRPR-QSPI-017` | [`V-QSPI-STM-014`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-stm-014), [`V-QSPI-CHK-011`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-011) |
| `GRPR-QSPI-018` | [`V-QSPI-CHK-012`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-012) |
| `GRPR-QSPI-019` | [`V-QSPI-CHK-013`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-013) |
| `GRPR-QSPI-020` | [`V-QSPI-CHK-014`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-014) |
| `GRPR-QSPI-021` | [`V-QSPI-CHK-015`](../../verification/blocks/QSPI%20Verification%20Plan.md#v-qspi-chk-015) |

See [QSPI Verification Plan](../../../verification/blocks/QSPI%20Verification%20Plan.md) for the full item definitions and test list.
