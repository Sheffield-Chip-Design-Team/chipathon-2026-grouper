# SPI Slave Verification Plan

**Design doc:** [SPI Slave](../../design/blocks/SPI%20Slave.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (SPI VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** No RTL, no VIP, no tests exist yet, though per the Schematic Review §4 RTL design for this block is starting.

---

## Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **SPI VIP (passive) ↔ SPI S (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**.

```
        ┌──────────────┐        ┌──────────────┐
        │  SPI Agent   │◄──────►│              │
        │ (passive VIP)│  SS/   │   SPI S      │
        │              │  SCK/  │              │
        └──────────────┘  MOSI/ │              │
        ┌──────────────┐  MISO  │              │
        │  AHB3Lite    │◄──────►│              │
        │  Agent       │  AHB   └──────────────┘
        │ (active VIP) │  bus
        └──────┬───────┘
               │
        ┌──────▼───────┐
        │  Scoreboard   │  (does not exist yet)
        └───────────────┘
```

**Open question — "passive" SPI VIP.** The source labels the SPI-side VIP for this block **passive**, unlike SPI Master's (active). A pure passive VIP only monitors; it cannot generate the SPI transactions needed to stimulate a slave DUT, since something has to act as the external master driving `SCK`/`MOSI`/`CS`. Either (a) "passive" here specifically means "no register-level sequencer, but the driver still toggles pins directly from a directed testbench sequence" (a narrower meaning than the AHB3Lite UVC's `is_active` convention already established in `hw/dv/uvc/ahb3lite/ahb3lite_agent.py`), or (b) the deck intends an active driver here too and "passive" is a labeling slip. **Needs clarification from whoever owns this block's testbench before it's built** — this plan assumes interpretation (a) and calls the component a "SPI host-role driver" below to avoid conflating it with the passive/active convention used elsewhere.

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| AHB3Lite Agent | **Exists** — `hw/dv/uvc/ahb3lite/` | Reuse as-is; monitors the RAM-side view of firmware-load writes and normal register access. |
| SPI host-role driver/monitor | **Missing — new** | Drives `SCK`/`MOSI`/`CS` as the external master (see open question above), monitors `MISO`. Needs to speak the APS6404L-compatible command set from the *master* side (mirror image of the SPI Master VIP's device-role responder). |
| Scoreboard / reference model | **Missing** | Needs two checking paths: (1) normal register access — SPI-driven reads/writes visible correctly on the AHB side, and (2) the firmware-load path — bytes shifted in via `SS`/SPI produce the correct `fw_ld_addr`/`fw_ld_wdata`/`fw_ld_we` sequence into RAM. |
| Functional coverage collector | **Missing** | New — see `V-SPIS-COV-*` below. |

## Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-SPIS-STM-001` | Stimulus | Drive AHB-side register access while a SPI transaction is in flight and while idle | `GRPR-SPIS-001` | New directed test |
| `V-SPIS-CHK-001` | Check | AHB-Lite subordinate protocol compliance | `GRPR-SPIS-001` | Scoreboard, AHB agent protocol checks |
| `V-SPIS-STM-002` | Stimulus | Drive SPI transactions in both mode 0 and mode 3 | `GRPR-SPIS-002` | SPI host-role driver |
| `V-SPIS-COV-001` | Coverage | Both modes exercised, MSB-first bit order confirmed | `GRPR-SPIS-002` | Coverage collector |
| `V-SPIS-STM-003` | Stimulus | Issue each APS6404L-compatible command from the external-master side | `GRPR-SPIS-003` | New directed test |
| `V-SPIS-CHK-002` | Check | DUT correctly parses/responds to each command per the APS6404L encoding | `GRPR-SPIS-003` | Scoreboard |
| `V-SPIS-STM-004` | Stimulus | Drive a mixed sequence of reads and writes over SPI | `GRPR-SPIS-004` | New directed test |
| `V-SPIS-CHK-003` | Check | Data received over SPI is visible correctly via the AHB-Lite bus, and vice versa | `GRPR-SPIS-004` | Scoreboard |
| `V-SPIS-STM-005` | Stimulus | Exercise `SPI_READ`, `FAST_READ`, `SPI_WRITE`, `FAST_WRITE` individually and mixed | `GRPR-SPIS-005` | New directed + randomized test |
| `V-SPIS-COV-002` | Coverage | All 4 commands exercised in isolation and back-to-back | `GRPR-SPIS-005` | Coverage collector |
| `V-SPIS-CHK-004` | Check | Register/memory region addressable via this block matches the intended 4 kB allocation | `GRPR-SPIS-006` | Scoreboard, address-sweep test |
| `V-SPIS-STM-006` | Stimulus | Drive byte-granular SPI transfers (not full-word bursts) | `GRPR-SPIS-007` | New directed test |
| `V-SPIS-STM-007` | Stimulus | Drive register reads/writes exclusively through register accesses (no side-channel paths) | `GRPR-SPIS-008` | New directed test |
| `V-SPIS-CHK-005` | Check | All hardware behavior changes are observable purely through documented registers | `GRPR-SPIS-008` | Scoreboard |
| `V-SPIS-CHK-006` | Check | Resolve and verify the open clock-domain question (§ SPI Slave design doc): is `SCK` phase-locked to `HCLK`, or does the FSM run in the `SCK` domain with a handshake? Confirm no metastability-class failures under the actual implementation | `GRPR-SPIS-009` | **Blocked** — needs the design-level clocking question resolved first; write this check to match whichever answer the RTL implements |
| `V-SPIS-STM-008` | Stimulus | Assert reset mid-transfer, at multiple points within a transaction | `GRPR-SPIS-010` | New directed test |
| `V-SPIS-CHK-007` | Check | Reset cleanly aborts any in-progress SPI transfer with no corrupted register/RAM state, and the design restarts cleanly | `GRPR-SPIS-010` | Scoreboard |
| `V-SPIS-CHK-008` | Check | SPI clock sweep up to 10 MHz with no transaction corruption | `GRPR-SPIS-011` | SPI host-role driver, scoreboard |
| `V-SPIS-CHK-009` | Check | Firmware-load throughput reaches 1.25 MB/s under back-to-back burst writes | `GRPR-SPIS-012` | Scoreboard timing check |
| `V-SPIS-CHK-010` | Check | One payload byte received every 0.8 µs at maximum SPI clock, sustained over a representative burst | `GRPR-SPIS-013` | Scoreboard timing check |

## Suggested Tests

- **Register sanity**: AHB read/write walk of this block's register region.
- **Command-opcode directed tests**: one per APS6404L-compatible command, driven from the external-master side.
- **Firmware-load path test**: drive a burst SPI write sequence and confirm `fw_ld_addr`/`fw_ld_wdata`/`fw_ld_we` produce the correct RAM contents — this is the test that should also resolve the open "relationship to UART boot path" question in the design doc, by exercising the path end-to-end and documenting what it actually does.
- **Reset-mid-transfer test**: assert reset at several points within a transaction, confirm clean abort and recovery.
- **Throughput test**: sustained burst-write test measuring achieved MB/s against the 1.25 MB/s target.
- **Clock-domain stress test** *(blocked)*: once the `SCK`/`HCLk` relationship is resolved at the design level, a test that specifically stresses that boundary (e.g. free-running asynchronous `SCK` if that's what's implemented).

## Open Items

- The "passive" SPI VIP labeling needs clarification before the testbench architecture above can be finalized as written — see the open question in Testbench Architecture.
- `V-SPIS-CHK-006` is blocked on the same open clocking question flagged in [SPI Slave § Clocking Strategy](../../design/blocks/SPI%20Slave.md#clocking-strategy).
- No scoreboard, no SPI VIP, no tests exist yet.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`).
