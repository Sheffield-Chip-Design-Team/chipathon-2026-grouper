# SPI Master Verification Plan

**Design doc:** [SPI Master](../../design/blocks/SPI%20Master%20Specification.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (SPI VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** *(header below is stale — see "Current cocotb coverage" immediately after)*
~~No RTL, no VIP, no tests exist yet~~. `hw/rtl/spi_m/ahb_spi_m.sv` is implemented
and instantiated live in `hw/rtl/periph_ss.sv` (`u_spi_m`; the neighbouring
`ahb_stub_slave` is the SPI **Slave** slot, not this block). A directed cocotb
testbench exists at `hw/tb/spi_m/` and passes 25/25.

> **Note on this document.** The traceability matrix below describes a planned
> pyuvm flow (SPI device-role UVC + scoreboard) that was never built. The
> verification that actually exists is directed cocotb. The `V-SPIM-*` rows are
> retained as the intended randomized-closure plan; the table under "Current
> cocotb coverage" is what is real today. These two views need reconciling —
> tracked in Open Items.

## Current cocotb coverage

**Testbench:** `hw/tb/spi_m/test_spi_m.py` (DUT `ahb_spi_m`, AHB driven by
`hw/tb/tb_utils/ahb_utils.py`, wire checked by `SpiMonitor`).

**Run:**

```bash
fusesoc run --no-export sharc:comms_ip:ahb_spi_m_directed
```

**SoC-level**, against the APS6404L model in `hw/tb/models/aps6404l.py`:

```bash
FW_TEST=spi_m fusesoc run --no-export sharc:soc_ip:grouper_soc_directed
```

| # | Test | Requirement | Pass criterion | Status |
|---|---|---|---|---|
| 1 | `test_word_push_wait_states` | `GRPR-SPIM-024` | A 32-bit `DATA` store takes exactly 3 wait states, puts all four bytes on MOSI in low-lane-first order, and sets no `OVERFLOW` | ✅ done |
| 2 | `test_byte_push_is_zero_wait` | `GRPR-SPIM-024` | Byte-sized `DATA` stores take 0 wait states — the driver's byte loop is not slowed by the stall | ✅ done |

Both rows were added with the stall itself and were mutation-checked: forcing
`push_stall = 1'b0` in `ahb_spi_m.sv` makes row 1 fail with "0 wait states,
expected 3" while row 2 still passes, so row 1 detects the stall's absence
rather than passing vacuously.

Not yet covered for `GRPR-SPIM-024`:

| Gap | Why it matters | Status |
|---|---|---|
| Half-word (`HSIZE_HALF`) store → 1 wait state | The 2-lane case is the untested midpoint of the lane/wait-state table; only 1-lane and 4-lane are checked | ⬜ new |
| Unaligned / non-zero-base byte lanes (e.g. `HSIZE_BYTE` at offset 3) | `byte_select` is generated from `HSIZE` **and** `HADDR[1:0]`; only lane 0 is exercised today | ⬜ new |
| Store to a **full** TX FIFO under stall | Asserts the "never device-paced" half of the requirement: the store must retire with no wait states and set `OVERFLOW`. Currently inferred from the `!tx_full` term in RTL, not tested | ⬜ new |
| Stall interaction with the two-cycle ERROR response | `HREADYOUT` combines both; the priority is argued in RTL comments but unproven by test | ⬜ new |

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
| `V-SPIM-CHK-003` | Check | Transaction timing stays within RP2040/Pico SPI peripheral compatible bounds | `GRPR-SPIM-004` | **Blocked** — no concrete compatibility criteria defined yet (see [SPI Master § Open Items](../../design/blocks/SPI%20Master%20Specification.md#open-items)); this item needs a concrete spec before a test can be written |
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
| `V-SPIM-STM-010` | Stimulus | Drive `DATA` stores at every `HSIZE` (byte/half/word) and every legal `HADDR[1:0]` offset, so all byte-lane patterns are generated | `GRPR-SPIM-024` | `test_word_push_wait_states`, `test_byte_push_is_zero_wait` (1-lane and 4-lane only — half-word and offset lanes ⬜ new) |
| `V-SPIM-CHK-010` | Check | Wait states equal (asserted lanes − 1): 0 for a byte store, 1 for a half, 3 for a word | `GRPR-SPIM-024` | `test_word_push_wait_states`, `test_byte_push_is_zero_wait` |
| `V-SPIM-CHK-011` | Check | Queued bytes reach the wire low-lane-first and none are dropped or duplicated by the stall | `GRPR-SPIM-024` | `test_word_push_wait_states` (MOSI stream check) |
| `V-SPIM-CHK-012` | Check | The stall is never device-paced: a `DATA` store to a full TX FIFO retires with no wait states, drops the surplus lanes and sets `IRQ_STATUS.OVERFLOW` | `GRPR-SPIM-024` | ⬜ new — currently argued from the `!tx_full` term in RTL, not tested |
| `V-SPIM-CHK-013` | Check | The push stall and the two-cycle AHB ERROR response compose correctly; the ERROR's second cycle always presents `HREADYOUT` high | `GRPR-SPIM-024`, `GRPR-SPIM-016` | ⬜ new |
| `V-SPIM-COV-005` | Coverage | Cross `HSIZE` × `HADDR[1:0]` × TX-FIFO occupancy (empty / partial / full) on `DATA` writes | `GRPR-SPIM-024` | Coverage collector (⬜ new) |

`GRPR-SPIM-015` (gate estimate) is a synthesis metric, not covered by functional verification.

## Suggested Tests

- **Register sanity**: AHB read/write walk of all SPI Master registers, modeled on `UartSanityTest`.
- **Command-opcode directed tests**: one test per APS6404L command (`SPI_READ`/`FAST_READ`/`SPI_WRITE`/`FAST_WRITE`), checking wire-level framing against the datasheet.
- **Mode sweep**: CPOL/CPHA = {0,1}×{0,1}, confirm mode 0/3 work and mode 1/2 are rejected or behave as spec'd (spec currently only commits to mode 0/3 — confirm the other two are out of scope, not silently accepted).
- **Busy-flag polling test**: start a transaction, poll `busy` every cycle, confirm no false-idle window.
- **Clock-divider sweep**: measure SCK period across the divider's range once the clock-plan open item is resolved.
- **Randomized read/write stress**: random address/data/command sequences against the modeled target device, scoreboard-checked end to end.
- **Pico-compatibility check** *(blocked)*: once `GRPR-SPIM-004` has concrete criteria, a directed timing-margin test against those criteria.

## Suggested Tests (`GRPR-SPIM-024`)

- **Half-word push**: `HSIZE_HALF` store to `DATA`, assert exactly 1 wait state and 2 bytes on the wire — the untested midpoint of the lane/wait-state table.
- **Offset lane push**: `HSIZE_BYTE` at `HADDR[1:0]` = 1, 2, 3, confirming the byte taken is the addressed lane and the stall is still 0. `byte_select` depends on `HADDR[1:0]` as well as `HSIZE`, and only offset 0 is exercised today.
- **Full-FIFO push**: fill the TX FIFO, then issue a word store. Assert it retires with **no** wait states and sets `OVERFLOW` — this is the property that keeps the block from deadlocking the single-master SoC, and it is the one half of the requirement with no test behind it.
- **Stall vs ERROR**: issue an illegal `CTRL` write (`GRPR-SPIM-016`) while a multi-lane push is draining, confirming the ERROR's second cycle still presents `HREADYOUT` high on schedule.

## Open Items

- `V-SPIM-CHK-003` (Pico/RP2040 compatibility) and `V-SPIM-CHK-007` (SCK frequency) are both blocked on open design-level questions — see the design doc's own Open Items.
- ~~No scoreboard, no SPI device-role VIP, no tests exist yet.~~ **Stale.** Directed cocotb tests exist (`hw/tb/spi_m/`, 25/25 passing) and an APS6404L device model exists at `hw/tb/models/aps6404l.py`, used at SoC level. What is still missing is the *pyuvm* scoreboard/UVC and the functional-coverage collector this plan's `V-SPIM-*` matrix assumes.
- **This plan needs reconciling with reality.** Its matrix was written before the RTL existed and describes a pyuvm flow that was never built; the `V-SPIM-*` rows are largely unmapped to the cocotb tests that now cover the same behaviour. Only `GRPR-SPIM-024` has been mapped both ways so far. Reconciling the rest is a separate task from this change.
- `V-SPIM-CHK-012` is the highest-value open row for `GRPR-SPIM-024`: it is the property that prevents a bus deadlock, and it is currently held only by an RTL term and a code comment.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`).
