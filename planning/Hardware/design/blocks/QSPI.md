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
| `GRPR-QSPI-011` | A per-transaction `FAST_TXN_EN` field shall select between fixed normal and fast read/write command variants. Command opcodes are selected internally according to the target device and operating mode. |
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

## Register Map

| Offset | Name | Access | Reset | Purpose |
| --- | --- | --- | --- | --- |
| `0x00` | `CTRL` | R/W | TBD | Static mode, clock, interrupt and protection configuration |
| `0x04` | `CMD` | R/W | `0x0000_0000` | Per-transfer descriptor and `START` |
| `0x08` | `STATUS` | Mixed | `0x0000_0000` | Live transaction state and latched events |
| `0x0C` | `ADDR` | R/W | `0x0000_0000` | External-memory address payload |
| `0x10` | `DATA` | R/W | `0x0000_0000` | Manual transmit and receive data |

Unlisted bits are reserved: write 0, read 0.

## CTRL — 0x00

Persistent configuration. Normally written during initialisation rather than
for every transfer.

| Bits | Field | Access | Description |
| --- | --- | --- | --- |
| `0` | `CPHA` | R/W | Clock phase |
| `1` | `CPOL` | R/W | Clock polarity |
| `2` | `QUAD_MODE` | R/W | `0` = single-bit SPI, `1` = four-bit QPI |
| `3` | `FLASH_WRITE_EN` | R/W | Enables the AHB wrapper's NOR-flash write path |
| `4` | `IE_DONE` | R/W | Interrupt enable for `STATUS.DONE` |
| `5` | `IE_ERR` | R/W | Interrupt enable for status error bits |
| `7:6` | Reserved | — | Write zero, read zero |
| `15:8` | `CLKDIV` | R/W | `SCK = fclk / (2 × (CLKDIV + 1))` |
| `31:16` | Reserved | — | Write zero, read zero |

`QUAD_MODE` implements `GRPR-QSPI-007` and `GRPR-QSPI-010`.

`CLKDIV`, `CPOL`, and `CPHA` implement `GRPR-QSPI-009`.

`FLASH_WRITE_EN` implements `GRPR-QSPI-012`.

The reset value of `CLKDIV` remains TBD until the system-clock plan is
confirmed. All other control fields reset to zero.

Writing `CTRL` while `STATUS.BUSY = 1` is ignored and sets
`STATUS.CFG_ERR`.

## CMD — 0x04

Write with `START = 1` to launch one transaction. Single-store kickoff.

| Bits | Field | Access | Description |
| --- | --- | --- | --- |
| `0` | `START` | R/W | Self-clearing. Always reads zero |
| `1` | `DIR` | R/W | `0` = write, `1` = read |
| `2` | `ADDR_EN` | R/W | Emit the three-byte address phase from `ADDR` |
| `3` | `DATA_EN` | R/W | Emit a one-byte data phase |
| `4` | `TARGET` | R/W | `0` = PSRAM, `1` = NOR flash |
| `5` | `FAST_TXN_EN` | R/W | `0` = normal transaction, `1` = fast transaction |
| `7:6` | Reserved | — | Write zero, read zero |
| `12:8` | `DUMMY` | R/W | `0–31` dummy SCK cycles before the data phase |
| `15:13` | Reserved | — | Write zero, read zero |
| `31:16` | Reserved | — | Write zero, read zero |

`DUMMY` begins at bit 8 and is contained entirely within byte `[15:8]`.

The command opcode is selected internally from the supported fixed command set
using `TARGET`, `DIR`, `FAST_TXN_EN`, and `QUAD_MODE`.

| `DIR` | `FAST_TXN_EN` | Transaction type |
| --- | --- | --- |
| `0` | `0` | Normal write |
| `0` | `1` | Fast write |
| `1` | `0` | Normal read |
| `1` | `1` | Fast read |

The fixed command mapping and any device-control commands required during
initialisation are handled internally by the transaction-control logic.

Phase order:

```text
COMMAND → ADDRESS → DUMMY → DATA
```

The address and data phases may be omitted using `ADDR_EN` and `DATA_EN`.

`DUMMY` is ignored for transaction types that do not require dummy cycles.

Writing `START = 1` while `STATUS.BUSY = 1` does not begin another
transaction and sets `STATUS.CFG_ERR`.

`FAST_TXN_EN` implements `GRPR-QSPI-011`.

`DUMMY` implements `GRPR-QSPI-013`.

## STATUS — 0x08

| Bits | Field | Access | Description |
| --- | --- | --- | --- |
| `0` | `BUSY` | R/O | Transaction in progress |
| `1` | `INIT_DONE` | R/O | Startup initialisation completed |
| `2` | `DONE` | W1C | Transaction completed |
| `3` | `RX_VALID` | W1C | `DATA` contains valid received data |
| `4` | `CFG_ERR` | W1C | Illegal configuration or `START` while busy |
| `5` | `WRITE_BLOCKED` | W1C | Invalid or disabled NOR-flash write was requested |
| `6` | `ADDR_ERR` | W1C | Address is outside the selected device's supported range |
| `31:7` | Reserved | — | Write zero, read zero |

Writing one to a W1C field clears that field.

An unsupported transaction combination is rejected, leaves `BUSY` low and
sets `STATUS.CFG_ERR`.

A prohibited write targeting NOR flash is rejected, leaves `BUSY` low and
sets `STATUS.WRITE_BLOCKED`.

The combined interrupt output asserts when:

```text
(DONE & CTRL.IE_DONE) |
((CFG_ERR | WRITE_BLOCKED | ADDR_ERR) & CTRL.IE_ERR)
```

This is the proposed initial status-bit definition for `GRPR-QSPI-015`.

## ADDR — 0x0C

| Bits | Field | Access | Description |
| --- | --- | --- | --- |
| `23:0` | `ADDR` | R/W | Three-byte external-memory address payload |
| `31:24` | Reserved | — | Write zero, read zero |

When `CMD.ADDR_EN = 1`, `ADDR[23:0]` is transmitted as three bytes, MSB
first.

The APS6404L uses 23-bit byte addressing, so its valid address range is
`0x000000–0x7FFFFF` and `ADDR[23]` must be zero.

Address validation for each target follows the supported capacity of that
device. An out-of-range address is rejected and sets `STATUS.ADDR_ERR`.

## DATA — 0x10

| Access | Behaviour |
| --- | --- |
| Write | Supplies one byte of transmit data in bits `7:0` |
| Read | Returns the most recently received byte in bits `7:0` |

Bits `31:8` are reserved and read as zero.

The initial manual-command interface supports one data byte per transaction.
FIFO and multi-byte transfer support are outside the initial proposal.


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

- `GRPR-QSPI-015` — the proposed status register definition is included above and remains subject to design review.
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
