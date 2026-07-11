# SPI Master Verification Plan

**Design doc:** [SPI Master](../../design/blocks/SPI%20Master.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (SPI VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** No RTL, no VIP, no tests exist yet, though per the Schematic Review §4 RTL design for this block is starting.

---

## Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **SPI VIP (active) ↔ SPI M (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**. Both VIPs are active: the AHB agent drives CPU-side register transactions, and the SPI agent plays the role of the *external target device* (an APS6404L-compatible part) — i.e. it must respond to `SPI_READ`/`FAST_READ`/`SPI_WRITE`/`FAST_WRITE` commands the DUT issues, not just monitor.

```
        ┌──────────────┐        ┌──────────────┐
        │  SPI Agent   │◄──────►│              │
        │ (active VIP, │  MOSI/ │   SPI M      │
        │  device role)│  MISO/ │              │
        └──────────────┘  SCK/  │              │
        ┌──────────────┐  CS    │              │
        │  AHB3Lite    │◄──────►│              │
        │  Agent       │  AHB   └──────────────┘
        │ (active VIP) │  bus
        └──────┬───────┘
               │
        ┌──────▼───────┐
        │  Scoreboard   │  (does not exist yet)
        └───────────────┘
```

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| AHB3Lite Agent | **Exists** — `hw/dv/uvc/ahb3lite/` | Reuse as-is. |
| SPI Agent (driver/monitor/sequencer/item), device role | **Missing — new** | Build following the `hw/dv/uvc/uart/` pattern. Must model an APS6404L-compatible target: respond to `SPI_READ`/`FAST_READ`/`SPI_WRITE`/`FAST_WRITE` opcodes, both SPI mode 0 and mode 3, with a backing memory array for read/write consistency checking. |
| Scoreboard / reference model | **Missing** | Compares CPU-issued AHB commands against the resulting SPI transactions (opcode, address, data, CPOL/CPHA framing) and against the modeled target device's read/write state. |
| Functional coverage collector | **Missing** | New — see `V-SPIM-COV-*` below. |

## Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-SPIM-STM-001` | Stimulus | Drive AHB register traffic to all SPI Master registers (`SR_TARGET`/`SR_ADDR`/`SR_DATA`/`SR_CTRL` or final names once resolved) | `GRPR-SPIM-001` | New directed test |
| `V-SPIM-CHK-001` | Check | AHB-Lite subordinate protocol compliance (wait states, `HRESP`, decode) | `GRPR-SPIM-001` | Scoreboard, AHB agent protocol checks |
| `V-SPIM-STM-002` | Stimulus | Exercise both SPI mode 0 and mode 3 transactions | `GRPR-SPIM-002` | New directed test |
| `V-SPIM-COV-001` | Coverage | Both modes exercised, MSB-first bit order confirmed on the wire | `GRPR-SPIM-002` | SPI agent monitor + coverage collector |
| `V-SPIM-STM-003` | Stimulus | Issue each APS6404L command opcode from firmware/AHB side | `GRPR-SPIM-003` | New directed test |
| `V-SPIM-CHK-002` | Check | Wire-level opcode/address/data framing matches the APS6404L datasheet encoding for each command | `GRPR-SPIM-003` | Scoreboard, SPI agent (device-role) decode |
| `V-SPIM-CHK-003` | Check | Transaction timing stays within RP2040/Pico SPI peripheral compatible bounds | `GRPR-SPIM-004` | **Blocked** — no concrete compatibility criteria defined yet (see [SPI Master § Open Items](../../design/blocks/SPI%20Master.md#open-items)); this item needs a concrete spec before a test can be written |
| `V-SPIM-STM-004` | Stimulus | Issue back-to-back read and write commands from the AHB side | `GRPR-SPIM-005` | New directed test |
| `V-SPIM-CHK-004` | Check | Each AHB command results in the correct corresponding SPI transaction, no drops/reorders | `GRPR-SPIM-005` | Scoreboard |
| `V-SPIM-STM-005` | Stimulus | Exercise `SPI_READ`, `FAST_READ`, `SPI_WRITE`, `FAST_WRITE` individually and in mixed sequences | `GRPR-SPIM-006` | New directed + randomized test |
| `V-SPIM-COV-002` | Coverage | All 4 commands exercised, including back-to-back same-command and alternating-command sequences | `GRPR-SPIM-006` | Coverage collector |
| `V-SPIM-STM-006` | Stimulus | Drive the modeled target device to accept/complete both read and write transactions | `GRPR-SPIM-007` | SPI agent (device role) |
| `V-SPIM-CHK-005` | Check | Data written is correctly read back through the modeled device's backing memory | `GRPR-SPIM-007` | Scoreboard |
| `V-SPIM-CHK-006` | Check | `busy` flag asserts for the full duration of a transaction and deasserts exactly on completion; polling `busy` during an in-flight transaction never gives a false-idle reading | `GRPR-SPIM-008` | Scoreboard, AHB agent polling sequence |
| `V-SPIM-STM-007` | Stimulus | Sweep all 4 CPOL/CPHA combinations, keep 2 (mode 0, mode 3) as legal per spec | `GRPR-SPIM-009` | New directed test |
| `V-SPIM-COV-003` | Coverage | Mode 0 and mode 3 each exercised for both read and write | `GRPR-SPIM-009` | Coverage collector |
| `V-SPIM-CHK-007` | Check | SCK frequency matches the configured clock-divider ratio | `GRPR-SPIM-010` | **Blocked** — depends on the unresolved system clock plan (see [Grouper SoC Specification § Clocking / Reset Architecture](../../design/Grouper%20SoC%20Specification.md#clocking--reset-architecture)) |
| `V-SPIM-STM-008` | Stimulus | Configure shift-register width across its supported range | `GRPR-SPIM-011` | New directed test |
| `V-SPIM-STM-009` | Stimulus | Sweep clock-divider ratio, CPOL, CPHA registers independently | `GRPR-SPIM-012` | New directed test |
| `V-SPIM-COV-004` | Coverage | All three configuration axes (divider, CPOL, CPHA) cross-covered | `GRPR-SPIM-012` | Coverage collector |
| `V-SPIM-CHK-008` | Check | Default SCK measured at 4 MHz from reset-default register values; max supported rate reaches 10 MHz without transaction corruption | `GRPR-SPIM-013` | Scoreboard, SPI agent monitor |
| `V-SPIM-CHK-009` | Check | A 16-bit transaction completes within the expected cycle count at 4 MHz | `GRPR-SPIM-014` | Scoreboard timing check |

`GRPR-SPIM-015` (gate estimate) is a synthesis metric, not covered by functional verification.

## Suggested Tests

- **Register sanity**: AHB read/write walk of all SPI Master registers, modeled on `UartSanityTest`.
- **Command-opcode directed tests**: one test per APS6404L command (`SPI_READ`/`FAST_READ`/`SPI_WRITE`/`FAST_WRITE`), checking wire-level framing against the datasheet.
- **Mode sweep**: CPOL/CPHA = {0,1}×{0,1}, confirm mode 0/3 work and mode 1/2 are rejected or behave as spec'd (spec currently only commits to mode 0/3 — confirm the other two are out of scope, not silently accepted).
- **Busy-flag polling test**: start a transaction, poll `busy` every cycle, confirm no false-idle window.
- **Clock-divider sweep**: measure SCK period across the divider's range once the clock-plan open item is resolved.
- **Randomized read/write stress**: random address/data/command sequences against the modeled target device, scoreboard-checked end to end.
- **Pico-compatibility check** *(blocked)*: once `GRPR-SPIM-004` has concrete criteria, a directed timing-margin test against those criteria.

## Open Items

- `V-SPIM-CHK-003` (Pico/RP2040 compatibility) and `V-SPIM-CHK-007` (SCK frequency) are both blocked on open design-level questions — see the design doc's own Open Items.
- No scoreboard, no SPI device-role VIP, no tests exist yet.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`).
