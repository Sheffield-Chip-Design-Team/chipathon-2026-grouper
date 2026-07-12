# QSPI Verification Plan

**Design doc:** [QSPI](../../Hardware/design/blocks/QSPI.md)
**Source:** [Schematic Review](../../Hardware/Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (QSPI VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** No RTL, no VIP, no tests exist yet, though per the Schematic Review §4 RTL design for this block is starting.

---

## Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **QSPI VIP (active) ↔ QSPI (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**. The QSPI VIP needs to model *two* target devices — an APS6404L-compatible PSRAM (read/write) and a Micron N25Q032A-compatible NOR flash (read-only) — since the DUT talks to both per [QSPI § Purpose](../../Hardware/design/blocks/QSPI.md#purpose).

```
        ┌──────────────┐        ┌──────────────┐
        │  QSPI Agent  │◄──────►│              │
        │ (active VIP, │  CE#/  │    QSPI      │
        │  models both │  SCK/  │              │
        │  PSRAM + NOR)│  SIO   │              │
        └──────────────┘ [3:0]  │              │
        ┌──────────────┐        │              │
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
| QSPI Agent (driver/monitor/sequencer/item), dual device role | **Missing — new** | Needs two independently-selectable target models: an APS6404L PSRAM model (read/write, single→quad mode transition) and an N25Q032A NOR flash model (read-only). Both share the physical `SIO[3:0]` bus, selected via `CE#` per device — mirrors the "three four-bit SIO buses onto one physical bus" open item in the design doc, which needs resolving before this agent's internal structure can be finalized. |
| Scoreboard / reference model | **Missing** | Tracks single/quad mode state, in-flight command/address/dummy-cycle phase, and per-device backing memory for read/write consistency. |
| Functional coverage collector | **Missing** | New — see `V-QSPI-COV-*` below. |

## Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-QSPI-STM-001` | Stimulus | Drive AHB register traffic across the full QSPI register set | `GRPR-QSPI-001` | New directed test |
| `V-QSPI-CHK-001` | Check | AHB-Lite subordinate protocol compliance | `GRPR-QSPI-001` | Scoreboard |
| `V-QSPI-STM-002` | Stimulus | Issue read commands to the modeled N25Q032A NOR flash device | `GRPR-QSPI-002` | New directed test, NOR flash device model |
| `V-QSPI-CHK-002` | Check | Read-only enforcement: any write attempt to the NOR flash target is rejected/ignored, never corrupts the model | `GRPR-QSPI-002` | Scoreboard |
| `V-QSPI-STM-003` | Stimulus | Drive the modeled APS6404L PSRAM through its SPI-mode boot sequence, then CPU-driven quad-mode reconfiguration | `GRPR-QSPI-003` | New directed test, PSRAM device model |
| `V-QSPI-CHK-003` | Check | PSRAM correctly transitions from SPI to quad mode following the documented sequence; read/write both work post-transition | `GRPR-QSPI-003` | Scoreboard |
| `V-QSPI-STM-004` | Stimulus | Drive both single-bit SPI and four-bit QPI transfers | `GRPR-QSPI-004` | New directed test |
| `V-QSPI-COV-001` | Coverage | Both single and quad mode exercised for both device targets | `GRPR-QSPI-004` | Coverage collector |
| `V-QSPI-STM-005` | Stimulus | Boot directly from the modeled NOR flash, bypassing UART | `GRPR-QSPI-005` | New directed test, top-level-adjacent (coordinate with [Grouper SoC Verification Plan](../Grouper%20SoC%20Verification%20Plan.md)) |
| `V-QSPI-CHK-004` | Check | CPU correctly fetches/executes from NOR-flash-backed address space with no UART boot-ROM involvement | `GRPR-QSPI-005` | Scoreboard |
| `V-QSPI-STM-006` | Stimulus | After a simulated UART boot-load, issue PSRAM read/write from firmware | `GRPR-QSPI-006` | New directed test |
| `V-QSPI-CHK-005` | Check | PSRAM read/write available and correct post-boot | `GRPR-QSPI-006` | Scoreboard |
| `V-QSPI-STM-007` | Stimulus | Exercise both single and quad SPI support paths independently | `GRPR-QSPI-007` | New directed test |
| `V-QSPI-COV-002` | Coverage | Single/quad mode crossed with both device targets | `GRPR-QSPI-007` | Coverage collector |
| `V-QSPI-STM-008` | Stimulus | Issue manual commands via the command/data/control register interface with read-back | `GRPR-QSPI-008` | New directed test |
| `V-QSPI-CHK-006` | Check | Read-back data matches what was written/read on the wire | `GRPR-QSPI-008` | Scoreboard |
| `V-QSPI-STM-009` | Stimulus | Sweep clock-divider and CPHA/CPOL configuration | `GRPR-QSPI-009` | New directed test |
| `V-QSPI-COV-003` | Coverage | Clock-divider corners × CPOL/CPHA combinations cross-covered | `GRPR-QSPI-009` | Coverage collector |
| `V-QSPI-STM-010` | Stimulus | Toggle the single/quad mode configuration bit | `GRPR-QSPI-010` | New directed test |
| `V-QSPI-STM-011` | Stimulus | Program distinct read-command and write-command opcode fields | `GRPR-QSPI-011` | New directed test |
| `V-QSPI-STM-012` | Stimulus | Toggle the AHB-write-to-flash enable bit | `GRPR-QSPI-012` | New directed test |
| `V-QSPI-CHK-007` | Check | AHB writes to the NOR flash target are only accepted when this bit is set; otherwise rejected/ignored regardless of `GRPR-QSPI-002`'s read-only enforcement (i.e. this is a distinct, more general gate — verify both interact correctly, not just individually) | `GRPR-QSPI-012` | Scoreboard |
| `V-QSPI-STM-013` | Stimulus | Sweep the fast-read dummy-cycle count configuration | `GRPR-QSPI-013` | New directed test |
| `V-QSPI-CHK-008` | Check | APS6404L interface parameters (23-bit addressing, 8 MB capacity boundary, QPI clock) match spec; out-of-range addresses handled defined-ly (wrap, error, or reject — confirm against whatever the RTL implements) | `GRPR-QSPI-014` | Scoreboard, address-boundary directed test |
| `V-QSPI-CHK-009` | Check | Status register bit definitions, once defined at the design level (see [QSPI § Open Items](../../Hardware/design/blocks/QSPI.md#open-items)) | `GRPR-QSPI-015` | **Blocked** — no bit definitions to test against yet |
| `V-QSPI-CHK-010` | Check | Clock frequency matches the resolved system clock plan | `GRPR-QSPI-016` | **Blocked** — depends on the unresolved clock-plan open item (shared with SPI Master) |
| `V-QSPI-STM-014` | Stimulus | Exercise startup at the reduced (~500 kHz) SCK rate with synchronisers enabled, then a rate increase with synchronisers disabled | `GRPR-QSPI-017` | New directed test |
| `V-QSPI-CHK-011` | Check | Reset is active-low async-assert/sync-deassert; startup sequence transitions cleanly from reduced-rate/synchronized to full-rate/unsynchronized operation | `GRPR-QSPI-017` | Scoreboard |
| `V-QSPI-CHK-012` | Check | Cross-domain control signals are correctly registered/handshaked, no metastability-class failures at the GPIO Mux boundary | `GRPR-QSPI-018` | Scoreboard, coordinate with [GPIO Mux Verification Plan](../../Hardware/verification/blocks/GPIO%20Mux%20Verification%20Plan.md) |
| `V-QSPI-CHK-013` | Check | QPI clock reaches the target rate once the clock plan is resolved | `GRPR-QSPI-019` | **Blocked** — same clock-plan dependency |
| `V-QSPI-CHK-014` | Check | Measured raw four-bit link bandwidth matches the 16 MB/s arithmetic target at the resolved clock rate | `GRPR-QSPI-020` | Scoreboard timing check |
| `V-QSPI-CHK-015` | Check | Device initialization completes within 1 ms of reset de-assertion | `GRPR-QSPI-021` | Scoreboard timing check |

## Suggested Tests

- **Register sanity**: AHB read/write walk of the full QSPI register set.
- **NOR-flash read-only test**: confirm reads work and writes are rejected/ignored (`V-QSPI-STM-002`/`CHK-002`), interacting correctly with the separate AHB-write-enable gate (`V-QSPI-STM-012`/`CHK-007`).
- **PSRAM mode-transition test**: SPI boot → CPU-driven quad reconfiguration → verified read/write in quad mode (`V-QSPI-STM-003`/`CHK-003`).
- **NOR-boot-bypass test**: boot directly from NOR flash with no UART involvement — coordinate with the top-level boot-sequence test in [Grouper SoC Verification Plan](../Grouper%20SoC%20Verification%20Plan.md) (`V-QSPI-STM-005`/`CHK-004`).
- **Post-UART-boot PSRAM extension test**: simulate the UART boot path completing, then exercise PSRAM as extended storage from firmware (`V-QSPI-STM-006`/`CHK-005`).
- **Dummy-cycle sweep**: confirm fast-read timing across the configurable dummy-cycle range (`V-QSPI-STM-013`).
- **Startup-rate test**: reduced-rate/synchronized startup transitioning to full-rate operation (`V-QSPI-STM-014`/`CHK-011`).
- **Address-boundary test**: reads/writes at and beyond the 8 MB PSRAM / N25Q032A capacity limits.

## Open Items

- `V-QSPI-CHK-009` blocked on the undefined status-register bit list (design-level open item).
- `V-QSPI-CHK-010`/`CHK-013` blocked on the unresolved system clock plan (shared with SPI Master and the top-level spec).
- The QSPI agent's internal structure (device-select / multiplexing of the "three four-bit SIO buses") depends on the same open item flagged in [QSPI § IOs and External Interfaces](../../Hardware/design/blocks/QSPI.md#ios-and-external-interfaces).
- No scoreboard, no QSPI VIP, no tests exist yet.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`).
