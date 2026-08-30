# SPI Slave Verification Plan

**Design doc:** [SPI Slave Specification](../../design/blocks/SPI%20Slave%20Specification.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (SPI VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** RTL exists (`hw/rtl/spi_s/ahb_spi_s.sv`) and a directed cocotb suite exists (`hw/tb/spi_s/test_spi_s.py`, 9 tests, registered as `ahb_spi_s_directed` with `fail_ok: true`). No VIP or scoreboard yet, and the command FSM is not covered by any test. The debug port is specification only.

---

## Directed Verification

The matrix below describes the pyuvm/MDV flow, whose `CHK` items depend on a
scoreboard that does not exist yet. This section describes the **directed
cocotb bench**, which runs today and needs no scoreboard — each test asserts
directly.

```bash
source .env/bin/activate
fusesoc run ahb_spi_s_directed
```

- **Bench:** `hw/tb/spi_s/test_spi_s.py`
- **Core:** `hw/tb/spi_s/spi_s_directed.core` (`sharc:comms_ip:ahb_spi_s_directed`), toplevel `ahb_spi_s`
- **Bus helpers:** `hw/tb/tb_utils/ahb_utils.py` — `ahb_read`/`ahb_write` take a `size=` argument and are wait-state aware
- **SPI helpers:** `spi_send_byte` in the bench drives `SS`/`SCK`/`MOSI` as the external host

Items are numbered `V-SPIS-DIR-NNN`, a separate series from the `STM`/`CHK`/`COV`
items so directed coverage stays traceable on its own. Items whose **Test**
column names a function in `hw/tb/spi_s/test_spi_s.py` are implemented; the
rest are named for the test that should exist.

**Registered in CI as `ahb_spi_s_directed` with `fail_ok: true`** — failures are
recorded but do not block. That should be tightened to `fail_ok: false` once
the command-FSM gaps below are closed, otherwise a regression in this block
goes unnoticed.

### `GRPR-SPIS-001` / `-006` / `-008` — register map and decode

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-SPIS-DIR-001` | `test_ctrl_rw` | `CTRL` at 0x00 reads back what was written, bit by bit | `-001`, `-008` |
| `V-SPIS-DIR-002` | `test_status_ro` | `STATUS` at 0x04 is read-only; a write is rejected and does not change it | `-001` |
| `V-SPIS-DIR-003` | `test_txdata_wo` | `TXDATA` at 0x08 accepts writes; a read returns 0 rather than erroring | `-001` |
| `V-SPIS-DIR-004` | `test_rxdata_ro` | `RXDATA` at 0x0C is read-only | `-001` |
| `V-SPIS-DIR-005` | *(missing)* `test_register_aliasing` | The decode is `HADDR[3:2]` only, so the map repeats every 16 bytes across the 4 KiB window. Assert the aliasing rather than its absence — see the note below | `-006`, `SPIS-SPEC-011` |
| `V-SPIS-DIR-006` | *(missing)* `test_reset_values` | Every register reads its specified reset value out of reset, including `STATUS` = 0x04 | `-001` |
| `V-SPIS-DIR-007` | *(missing)* `test_access_widths` | Byte/halfword/word reads of `CTRL` all return the whole register; a byte write to `TXDATA` transmits | `-007` |

> `V-SPIS-DIR-005` mirrors the UART's `V-UART-DIR-001`: the block decodes only
> the low address bits, so its register map repeats within its 4 KiB region.
> That is worth pinning as behaviour rather than leaving as an accident, and it
> is the same decision `GRPR-UART-025` records for the UART.

### `GRPR-SPIS-002` / `-021` — SPI modes and sampling

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-SPIS-DIR-008` | *(missing)* `test_spi_mode_0` | A byte received with CPOL=0/CPHA=0, sampled on the rising edge | `-002` |
| `V-SPIS-DIR-009` | *(missing)* `test_spi_mode_3` | The same byte with CPOL=1/CPHA=1 | `-002` |
| `V-SPIS-DIR-009a` | *(missing)* `test_cpol_cpha_unimplemented` | **`expect_fail`.** `CTRL.CPHA`/`CPOL` are specified but not implemented in RTL; this documents `SPIS-SPEC-005` and flips to an unexpected pass when they land | `SPIS-SPEC-005` |
| `V-SPIS-DIR-010` | *(missing)* `test_sck_rate_limit` | Bytes are received correctly at SCK up to `HCLK`/4, and corrupt above it. The limit is a property of the oversampling design, so demonstrating the boundary is the point | `-011` |

### `GRPR-SPIS-004` / `-005` — data path and the command FSM

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-SPIS-DIR-011` | `test_spi_receive_byte` | A byte shifted in on `MOSI` appears in `RXDATA` with `RX_VALID` set | `-004` |
| `V-SPIS-DIR-012` | `test_spi_transmit_byte` | A byte written to `TXDATA` is shifted out on `MISO`, MSB first | `-004` |
| `V-SPIS-DIR-013` | `test_rx_valid_clears_after_read` | `RX_VALID` clears when `RXDATA` is read | `-004` |
| `V-SPIS-DIR-014` | `test_txdata_multiple_writes` | Repeated `TXDATA` writes each land | `-004` |
| `V-SPIS-DIR-015` | *(missing)* `test_command_opcodes` | Each of `SPI_READ`/`FAST_READ`/`SPI_WRITE`/`FAST_WRITE` drives the FSM through COMMAND into the right following state; an unknown opcode returns to IDLE | `-005` |
| `V-SPIS-DIR-016` | *(missing)* `test_address_phase` | The 24-bit address phase captures the right value, MSB first | `-005` |
| `V-SPIS-DIR-016a` | *(missing)* `test_legacy_address_unused` | **`expect_fail`.** The captured 24-bit address is read by nothing, so a legacy read does not address anything. Documents `SPIS-SPEC-010` | `SPIS-SPEC-010` |
| `V-SPIS-DIR-017` | *(missing)* `test_fast_read_dummy` | `FAST_READ` inserts its wait cycles before data. Currently treated identically to `SPI_READ`, so this starts as an `expect_fail` | `-005` |

> **The command FSM is the largest gap in this bench.** Not one of the eight
> existing tests drives an opcode, so `FSM_COMMAND`, `FSM_ADDRESS` and both
> data states are entirely unexercised — the tests cover only the register
> interface and the raw byte shift path. `V-SPIS-DIR-015` through `-017` are
> the highest-value additions here.

### `GRPR-SPIS-010` — reset behaviour

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-SPIS-DIR-018` | *(missing)* `test_reset_mid_transfer` | Reset asserted at several points within a transfer aborts it cleanly, with no stale byte and no corrupted register state | `-010` |
| `V-SPIS-DIR-019` | *(missing)* `test_soft_reset` | `CTRL.SOFT_RESET` returns the FSM to IDLE | `-010` |
| `V-SPIS-DIR-019a` | *(missing)* `test_soft_reset_self_clears` | **`expect_fail`.** The bit is specified to self-clear and does not. Documents `SPIS-SPEC-006` | `SPIS-SPEC-006` |
| `V-SPIS-DIR-020` | *(missing)* `test_ss_deassert_returns_to_idle` | Raising `SS` at any point returns the decoder to IDLE — the resynchronisation guarantee a host relies on | `-022` |

### `GRPR-SPIS-014` … `-019`, `-022` — debug port

These need `DEBUG_PORT_EN` built and a stub responder on `dbg_*`; none can be
written until the debug port RTL exists.

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-SPIS-DIR-021` | *(missing)* `test_debug_port_absent` | With the parameter unset, no debug port exists and the register map matches a pre-feature build exactly | `-014`, `-020` |
| `V-SPIS-DIR-022` | *(missing)* `test_debug_opcode_forwarding` | Each debug opcode produces exactly one correctly formed request on `dbg_*`, with the right command, address and data | `-015` |
| `V-SPIS-DIR-023` | *(missing)* `test_debug_gate` | With `CTRL.DEBUG_PORT_EN` clear, debug opcodes are ignored and the port is not disturbed | `-016` |
| `V-SPIS-DIR-024` | *(missing)* `test_debug_single_outstanding` | At most one request outstanding; read response bytes stall until the response arrives | `-017` |
| `V-SPIS-DIR-025` | *(missing)* `test_debug_abort_on_ss` | `SS` raised mid-command aborts it without leaving the port mid-handshake, and does not release a lock | `-018` |
| `V-SPIS-DIR-026` | *(missing)* `test_debug_resync_and_unlock` | Abort at every phase boundary, then release the lock on a fresh transaction — **with no AHB access available**, which is the real-world case since the CPU is halted | `-022` |
| `V-SPIS-DIR-027` | *(missing)* `test_reserved_opcode_refused` | Opcode `0x56` and other unassigned encodings are refused cleanly rather than aliasing another command | `-015` |
| `V-SPIS-DIR-028` | *(missing)* `test_soft_reset_aborts_debug_request` | `CTRL.SOFT_RESET` aborts an outstanding debug request without altering Debug Unit state | `-019` |

### Known limitations

Rows for the open items in
[SPI Slave § Open Items](../../design/blocks/SPI%20Slave%20Specification.md#open-items).
These pin down what the RTL *does*, so a fix shows up as a test change rather
than a silent behaviour change.

| Item | Test | What it does | Item |
|---|---|---|---|
| `V-SPIS-DIR-009a` | `test_cpol_cpha_unimplemented` | CPHA/CPOL specified, not implemented | `SPIS-SPEC-005` |
| `V-SPIS-DIR-016a` | `test_legacy_address_unused` | Captured address feeds nothing | `SPIS-SPEC-010` |
| `V-SPIS-DIR-019a` | `test_soft_reset_self_clears` | `SOFT_RESET` does not self-clear | `SPIS-SPEC-006` |
| `V-SPIS-DIR-029` | *(missing)* `test_status_busy_hardwired` | **`expect_fail`.** `STATUS.BUSY` is hardwired to 0 and never reports a transaction in progress | `SPIS-SPEC-004` |
| `V-SPIS-DIR-030` | *(missing)* `test_error_response_two_cycles` | **`expect_fail`.** The AHB error response is one cycle, an AHB-Lite protocol violation | `SPIS-SPEC-009` |

### Requirements deliberately not in this section

Structural properties a directed test can show a symptom of but cannot prove:

- `GRPR-SPIS-009` (single clock domain) — a property of the netlist, established
  by inspection and CDC lint.
- `GRPR-SPIS-021` (external inputs synchronised) — a directed test can show
  bytes still arrive when `SCK` transitions off the `HCLK` grid, but not that
  the synchronisers harden against metastability. Needs CDC lint. `V-SPIS-DIR-010`
  covers the rate limit that *is* observable.
- `GRPR-SPIS-003` (APS6404L compatibility) — conformance to an external
  datasheet is a review activity; the directed rows above check the individual
  opcodes the block implements.

### What this bench does not attempt

No functional coverage collection, no constrained randomisation, no reference
model. Those remain the MDV flow's job below, and this section complements it
rather than replacing it.

## MDV Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **SPI VIP (passive) ↔ SPI S (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**.

```
        ┌──────────────┐        ┌──────────────┐
        │  SPI Agent   │◄──────►│              │
        │ (active VIP) │  SS/   │   SPI S      │
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
| Scoreboard / reference model | **Missing** | Needs two checking paths: (1) normal register access — SPI-driven reads/writes visible correctly on the AHB side, and (2) the debug port — a decoded debug opcode produces exactly one correctly formed request on `dbg_*`. **There is no separate firmware-load datapath in this block**; earlier drafts of this plan referred to `fw_ld_addr`/`fw_ld_wdata`/`fw_ld_we` signals that do not exist. Firmware loading happens through the [Debug Unit](../../design/blocks/Debug%20Unit.md), and is verified there. |
| Debug-port monitor | **Missing — new** | Checks the request/response handshake on `dbg_*` and that one opcode yields one request. A stub responder is enough; the Debug Unit's own plan covers what happens downstream. |
| Functional coverage collector | **Missing** | New — see `V-SPIS-COV-*` below. |

## MDV Traceability Matrix

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
| `V-SPIS-CHK-006` | Check | `SCK` is oversampled in the `HCLK` domain (the design question is now answered — see § CDC Strategy); confirm no metastability-class failures with the top-level synchronisers enabled, and that the datapath is fully synchronous to `HCLK` | `GRPR-SPIS-009`, `GRPR-SPIS-021` | Directed test — no longer blocked |
| `V-SPIS-STM-008` | Stimulus | Assert reset mid-transfer, at multiple points within a transaction | `GRPR-SPIS-010` | New directed test |
| `V-SPIS-CHK-007` | Check | Reset cleanly aborts any in-progress SPI transfer with no corrupted register/RAM state, and the design restarts cleanly | `GRPR-SPIS-010` | Scoreboard |
| `V-SPIS-CHK-008` | Check | SPI clock sweep up to 4 MHz with no transaction corruption, and confirmation that corruption *does* appear above roughly `HCLK`/4 — the limit is a property of the oversampling design, so the boundary is worth demonstrating | `GRPR-SPIS-011` | SPI host-role driver, scoreboard |
| `V-SPIS-CHK-009` | Check | Throughput reaches 0.5 MB/s under back-to-back burst writes | `GRPR-SPIS-012` | Scoreboard timing check |
| `V-SPIS-CHK-010` | Check | One payload byte received every 2 µs at maximum SPI clock, sustained over a representative burst | `GRPR-SPIS-013` | Scoreboard timing check |
| `V-SPIS-STM-009` | Stimulus | Build with `DEBUG_PORT_EN` set and unset; drive debug opcodes in both | `GRPR-SPIS-014` | New directed test |
| `V-SPIS-CHK-011` | Check | With the parameter unset, no debug port exists and the register map and behaviour are identical to a pre-feature build | `GRPR-SPIS-014` | Elaboration + scoreboard |
| `V-SPIS-STM-010` | Stimulus | Drive each debug opcode of § Debug Command Encoding, with its full address and data phases | `GRPR-SPIS-015` | New directed test |
| `V-SPIS-COV-003` | Coverage | Every debug opcode exercised; every legacy opcode still exercised alongside | `GRPR-SPIS-015` | Coverage collector |
| `V-SPIS-STM-011` | Stimulus | Drive debug opcodes with `CTRL.DEBUG_PORT_EN` clear | `GRPR-SPIS-016` | New directed test |
| `V-SPIS-CHK-012` | Check | They are ignored and the debug port is not disturbed | `GRPR-SPIS-016` | Debug-port monitor |
| `V-SPIS-CHK-013` | Check | At most one debug request outstanding; read response bytes stall until the response arrives | `GRPR-SPIS-017` | Debug-port monitor |
| `V-SPIS-STM-012` | Stimulus | Deassert `SS` part-way through each phase of each debug opcode | `GRPR-SPIS-018` | New directed test |
| `V-SPIS-CHK-014` | Check | The command aborts cleanly with the debug port left idle, not mid-handshake | `GRPR-SPIS-018` | Debug-port monitor, assertion |
| `V-SPIS-CHK-015` | Check | `CTRL.SOFT_RESET` resets the command FSM and aborts an outstanding debug request | `GRPR-SPIS-019` | Scoreboard |
| `V-SPIS-CHK-016` | Check | `DEBUG_PORT_EN` = 0 elaborates with no debug logic present | `GRPR-SPIS-020` | Elaboration check |
| `V-SPIS-STM-013` | Stimulus | Abort a debug command at every phase boundary by raising `SS`, then immediately issue `BUS_UNLOCK` on a fresh transaction — with the CPU halted throughout, so no AHB access is available | `GRPR-SPIS-022` | New directed test |
| `V-SPIS-CHK-017` | Check | The decoder returns to idle on every such abort and the following `BUS_UNLOCK` is decoded correctly, proving a host can always resynchronise and release a lock over SPI alone | `GRPR-SPIS-022` | Scoreboard, debug-port monitor |

## Suggested Tests

- **Register sanity**: AHB read/write walk of this block's register region.
- **Command-opcode directed tests**: one per APS6404L-compatible command, driven from the external-master side.
- **Firmware-load path test**: drive a burst SPI write sequence and confirm `fw_ld_addr`/`fw_ld_wdata`/`fw_ld_we` produce the correct RAM contents — this is the test that should also resolve the open "relationship to UART boot path" question in the design doc, by exercising the path end-to-end and documenting what it actually does.
- **Reset-mid-transfer test**: assert reset at several points within a transaction, confirm clean abort and recovery.
- **Throughput test**: sustained burst-write test measuring achieved MB/s against the 1.25 MB/s target.
- **Clock-domain stress test** *(blocked)*: once the `SCK`/`HCLk` relationship is resolved at the design level, a test that specifically stresses that boundary (e.g. free-running asynchronous `SCK` if that's what's implemented).

## Open Items

- The "passive" SPI VIP labeling needs clarification before the testbench architecture above can be finalized as written — see the open question in Testbench Architecture.
- `V-SPIS-CHK-006` is blocked on the same open clocking question flagged in [SPI Slave § Clocking Strategy](../../design/blocks/SPI%20Slave%20Specification.md#clocking-strategy).
- No scoreboard, no SPI VIP, no tests exist yet.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`).
