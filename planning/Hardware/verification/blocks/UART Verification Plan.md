# UART Verification Plan

**Design doc:** [UART](../../design/blocks/UART.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (UART VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** Most-mature block. `hw/dv/ahb_uart/` (pyuvm test + sequences) and `hw/dv/uvc/uart/`, `hw/dv/uvc/ahb3lite/` (reusable UVCs) already exist, but the pyuvm flow is blocked on a missing scoreboard. `hw/tb/uart/test_uart.py` is a standalone directed cocotb testbench that runs today (5 tests passing) — see [Directed Verification](#directed-verification).

---

## Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **UART VIP (active) ↔ UART (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**.

```
        ┌──────────────┐          ┌──────────────┐
        │UART RX Agent │◄────────►│ RX           │
        │ (active VIP) │          │              │
        └──────────────┘          │   AHB UART   │◄────────► IRQ interface.
                                  │              │
        ┌──────────────┐          │              │
        │UART TX Agent │◄────────►│ TX           │
        │(passive VIP) │          │              │ 
        └──────────────┘          │              │
        ┌──────────────┐          │              │
        │  AHB3Lite    │◄────────►│              │
        │  Agent       │ AHBlite  └──────────────┘
        │ (active VIP) │   bus
        └──────┬───────┘
               │
        ┌──────▼───────┐
        │  Scoreboard  │  (does not exist yet — see gap below)
        └──────────────┘
```

 The AHB agent Drives + Monitors CPU-side register transactions; the UART RX agent drives/monitors the RX serial pin wheras the TX agent just monitors the tx pin passively.

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| AHB3Lite Agent (driver/monitor/sequencer/item) | **Exists** — `hw/dv/uvc/ahb3lite/` | Reuse as-is. |
| UART Agent (driver/monitor/sequencer/item) | **Exists** — `hw/dv/uvc/uart/` | Reuse as-is; drives/monitors `uart_tx`/`uart_rx` at the serial-bit level. |
| UART env (wires agents together) | **Exists** — `hw/dv/ahb_uart/tbench/ahb_uart_env.py` | Note: this file currently imports from `hw.dv.ahb3.*`, a path that doesn't match the real `hw/dv/uvc/ahb3lite/` |
| Scoreboard / reference model | **TODO** | No scoreboard exists anywhere in `hw/dv/` yet. For UART this needs to: (a) mirror the 4-register `CTRL`/`STATUS`/`TXDATA`/`RXDATA` map from AHB transactions, (b) independently model FIFO fill/empty/full state and baud timing from `CLK_DIV`, (c) compare bytes driven on `uart_rx` against bytes popped via `RXDATA` reads, and bytes pushed via `TXDATA` against bytes observed on `uart_tx`. |
| Functional coverage collector | **Missing** | New — see `V-UART-COV-*` below. |

## Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-UART-STM-001` | Stimulus | Drive AHB writes/reads to all 4 registers at all valid `HSIZE` widths | `GRPR-UART-001` | New directed test, AHB3Lite agent |
| `V-UART-CHK-001` | Check | Register offsets/decode match 0x0/0x4/0x8/0xC exactly; no aliasing within the 4 KiB region | `GRPR-UART-001` | Scoreboard |
| `V-UART-STM-002` | Stimulus | Sweep every `CTRL` bit independently (enable, tx_en, rx_en, rx_resync_en, tx_break, flush_tx_fifo, flush_rx_fifo, clk_div) | `GRPR-UART-002` | New directed test |
| `V-UART-CHK-002` | Check | Readback of `CTRL` matches last write, except self-clearing flush bits which read back 0 the cycle after | `GRPR-UART-002` | Scoreboard |
| `V-UART-COV-001` | Coverage | Cross-coverage of all `CTRL` enable-bit combinations exercised | `GRPR-UART-002` | Coverage collector |
| `V-UART-CHK-003` | Check | `STATUS` bits reflect true FIFO/line state at all times (tx_empty/full, rx_empty/full, tx_active, frame_error, break) | `GRPR-UART-003` | Scoreboard (reference FIFO model) |
| `V-UART-COV-002` | Coverage | Each `STATUS` bit observed both asserted and deasserted at least once | `GRPR-UART-003` | Coverage collector |
| `V-UART-STM-003` | Stimulus | Fill TX FIFO to full, then attempt one more write | `GRPR-UART-004` | New directed test |
| `V-UART-CHK-004` | Check | Write to `TXDATA` while full is rejected with `HRESP` error and does not corrupt FIFO contents | `GRPR-UART-004` | Scoreboard |
| `V-UART-STM-004` | Stimulus | Drain RX FIFO to empty, then attempt one more read | `GRPR-UART-005` | New directed test |
| `V-UART-CHK-005` | Check | Read of `RXDATA` while empty is rejected with `HRESP` error | `GRPR-UART-005` | Scoreboard |
| `V-UART-STM-005` | Stimulus | Attempt writes to `STATUS` and `RXDATA` | `GRPR-UART-006` | New directed test |
| `V-UART-CHK-006` | Check | Both are rejected with `HRESP` error and have no side effects | `GRPR-UART-006` | Scoreboard |
| `V-UART-STM-006` | Stimulus | Inject a bad start bit and a bad stop bit on `uart_rx` via the UART agent | `GRPR-UART-007` | New directed test, UART agent |
| `V-UART-CHK-007` | Check | `RX_FRAME_ERROR` asserts on both; `RX_BREAK` asserts on sustained line-low past a stop bit; confirm the `RX_FRAME_ERROR`/`RX_BREAK` read-clear-on-STATUS-read behavior against the RTL inconsistency flagged in [UART § Open Items](../../design/blocks/UART.md#open-items) | `GRPR-UART-007` | Scoreboard |
| `V-UART-STM-007` | Stimulus | Assert `TX_BREAK` mid-transmission and while idle | `GRPR-UART-008` | New directed test |
| `V-UART-CHK-008` | Check | `uart_tx` held low continuously while `TX_BREAK=1`, overriding FIFO-driven transmission | `GRPR-UART-008` | UART agent monitor + scoreboard |
| `V-UART-CHK-009` | Check | Drive `uart_rx` asynchronously (unrelated clock/phase to `HCLK`) and confirm no metastability-class failures / correct 2-stage-synchronized capture | `GRPR-UART-009` | UART agent monitor, CDC-aware directed test |
| `V-UART-STM-008` | Stimulus | Sweep `CLK_DIV` across its full 10-bit range and measure resulting bit period on `uart_tx` | `GRPR-UART-010` | New directed test |
| `V-UART-COV-003` | Coverage | `CLK_DIV` corner values (0, mid, max) each exercised for both TX and RX | `GRPR-UART-010` | Coverage collector |
| `V-UART-STM-009` | Stimulus | Fill and drain both FIFOs across their full 4-entry depth, including simultaneous TX+RX traffic | `GRPR-UART-011` | New directed + randomized test |
| `V-UART-CHK-010` | Check | FIFO full/empty flags transition at exactly the 4th entry boundary in both directions | `GRPR-UART-011` | Scoreboard |

## Directed Verification

The matrix above describes the pyuvm flow, whose `CHK` items are all blocked on a scoreboard that does not exist yet. This section describes the **directed cocotb bench**, which runs today and needs no scoreboard — each test asserts directly.

```bash
source .env/bin/activate
fusesoc run --no-export sharc:comms_ip:ahb_uart_directed
```

- **Bench:** `hw/tb/uart/test_uart.py`
- **Core:** `hw/tb/uart/uart_cocotb.core` (`sharc:comms_ip:ahb_uart_directed`), toplevel `ahb_uart`
- **Bus helpers:** `hw/tb/tb_utils/ahb_utils.py` — `ahb_read`/`ahb_write` take a `size=` argument for byte/halfword accesses and are wait-state aware
- **Baud arithmetic:** `clk_div_for_baud` from `hw/dv/ahb_uart/uart_clk_math.py`, already imported by the bench

Items are numbered `V-UART-DIR-NNN`, a separate series from the `STM`/`CHK`/`COV` items above so directed coverage stays traceable on its own. **Status** is `exists` (written and passing) or `TODO`.

### `GRPR-UART-001` — register map

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-001` | `test_register_decode` | Read/write each of `CTRL`/`STATUS`/`TXDATA`/`RXDATA` at 0x0/0x4/0x8/0xC and confirm no offset aliases another within the 4 KiB window | TODO |
| `V-UART-DIR-002` | `test_access_widths` | Byte and halfword writes to `CTRL` touch only their lane; word write touches all | TODO |
| `V-UART-DIR-003` | `test_reserved_bits_read_zero` | Bits above each register's implemented width read 0 and ignore writes | TODO |

### `GRPR-UART-002` — CTRL fields

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-004` | `test_ctrl_reset_values` | Out of reset `RX_RESYNC_EN`=1, `CLK_DIV`=all-1s, every other field 0 | TODO |
| `V-UART-DIR-005` | `test_ctrl_bit_readback` | Each of `ENABLE`/`TX_EN`/`RX_EN`/`RX_RESYNC_EN`/`TX_BREAK`/`CLK_DIV` written and read back independently | TODO |
| `V-UART-DIR-006` | `test_ctrl_flush_self_clear` | `FLUSH_TX_FIFO`/`FLUSH_RX_FIFO` read back 0 on the cycle after the write | TODO |
| `V-UART-DIR-007` | `test_ctrl_flush_empties_fifo` | Part-fill each FIFO, flush it, confirm the empty flag returns and no stale byte reappears | TODO |

### `GRPR-UART-003` — STATUS fields

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-008` | `test_status_bits_toggle` | Every bit observed both asserted and deasserted | TODO |
| `V-UART-DIR-009` | `test_status_tx_active` | `TX_ACTIVE` high for the duration of a frame and low either side of it | TODO |
| `V-UART-DIR-010` | `test_status_sticky_read_clear` | `RX_FRAME_ERROR` and `RX_BREAK` are sticky, and **both** clear on a `STATUS` read — see the note below | TODO |

> `V-UART-DIR-010` settles a question the design doc raised as an open item. The RTL's read-clear block assigns both `status_rx_frame_error` and `status_rx_break`, so both clear. The duplicated-assignment bug the open item described is in the abandoned UART copy that became `hw/rtl/gpio/ahb_gpio_ctrl.sv`, not here. The test exists to keep it that way.

### `GRPR-UART-004` — TXDATA push, reject when full

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-011` | `test_uart_tx_byte` | Write a byte, capture the 8N1 frame on `uart_tx`, confirm `TX_EMPTY`/`TX_ACTIVE` afterwards | **exists** |
| `V-UART-DIR-012` | `test_tx_fifo_full_write_errors` | Fill to `TX_FULL`, confirm the next write raises an error response and does not corrupt the queued bytes | TODO |
| `V-UART-DIR-013` | `test_tx_byte_order` | A burst of distinct bytes leaves the FIFO in the order written | TODO |

### `GRPR-UART-005` — RXDATA pop, reject when empty

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-014` | `test_uart_rx_byte` | Bit-bang a byte onto `uart_rx`, read it back; reading the **last** byte must not error, and the read after it must | **exists** |
| `V-UART-DIR-015` | `test_read_empty_rxdata_errors` | Reading an empty FIFO raises the error response | **exists** |
| `V-UART-DIR-016` | `test_errored_read_does_not_pop` | An errored `RXDATA` read leaves the FIFO untouched | TODO |

> The last-byte case in `V-UART-DIR-014` is the regression guard for read-validity phasing. `rx_read` pops during the address phase, so `RX_EMPTY` may be high by the data phase; deciding the error there would reject a legitimate read.

### `GRPR-UART-006` — illegal writes

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-017` | `test_write_to_read_only_errors` | Writes to `STATUS` and `RXDATA` both raise the error response | **exists** |

### `GRPR-UART-007` — framing errors and break detection

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-018` | `test_rx_bad_start_bit` | A start bit that is not low at the mid-bit sample sets `RX_FRAME_ERROR` | TODO |
| `V-UART-DIR-019` | `test_rx_bad_stop_bit` | A stop bit that is not high sets `RX_FRAME_ERROR` | TODO |
| `V-UART-DIR-020` | `test_rx_break_detect` | Line held low past the stop bit sets `RX_BREAK` | TODO |
| `V-UART-DIR-021` | `test_rx_error_irq_pulses` | `rx_error_irq` pulses on a frame error; `rx_irq` pulses on each good byte | TODO |

Injection can reuse the UART agent in `hw/dv/uvc/uart/`, or extend the bench's own `drive_rx_byte` helper with a bad-bit argument — the latter keeps the directed bench free of pyuvm dependencies.

### `GRPR-UART-008` — TX_BREAK

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-022` | `test_tx_break_from_idle` | `uart_tx` held low continuously while `TX_BREAK`=1, and returns high when cleared | TODO |
| `V-UART-DIR-023` | `test_tx_break_overrides_fifo` | `TX_BREAK` asserted mid-frame overrides FIFO-driven transmission; normal transmission resumes after clearing | TODO |

### `GRPR-UART-010` — baud divider

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-024` | `test_baud_sweep_tx` | Sweep `CLK_DIV` corners (0, mid, max), measure the bit period on `uart_tx` and compare against `HCLK / (8 × (CLK_DIV+1))` | TODO |
| `V-UART-DIR-025` | `test_baud_sweep_rx` | Receive correctly at the same corners | TODO |

`test_uart_tx_byte` already exercises one rate (1.25 MBaud), so this extends rather than replaces it.

### `GRPR-UART-011` — FIFO depth

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-026` | `test_fifo_depth_boundaries` | `TX_FULL`/`RX_FULL` assert on exactly the 4th entry and deassert on the first pop, in both directions | TODO |
| `V-UART-DIR-027` | `test_full_duplex_traffic` | Simultaneous TX and RX traffic without either FIFO disturbing the other | TODO |

### AHB response behaviour

The spec states this under *Invalid Access Rules* rather than as a numbered requirement, but it needs its own tests: a **single-cycle** `HRESP` — what this block did until recently — passes every functional test above while violating AHB-Lite.

| Item | Test | What it does | Status |
|---|---|---|---|
| `V-UART-DIR-028` | `test_read_empty_rxdata_errors` | The response is cycle-accurate: `HREADYOUT`/`HRESP` = `(0,1)` then `(1,1)` | **exists** |
| `V-UART-DIR-029` | `test_access_after_error` | The transfer following an error is neither lost nor applied twice — the address-phase hold during the wait state. Checked on the wire, because `TX_EMPTY` tracks the FIFO and the transmitter pops it within a few cycles | **exists** |

### Requirements deliberately not in this section

Three requirements are structural properties that simulation can show a symptom of but cannot prove. Giving them directed rows would overstate coverage:

- `GRPR-UART-009` (`uart_rx` through a 2-stage synchroniser) — a directed test can show bytes still arrive when `uart_rx` transitions off the `HCLK` grid, but not that the synchroniser hardens against metastability. Needs CDC lint. Tracked by `V-UART-CHK-009` above.
- `GRPR-UART-012` (single clock domain) — a structural property of the netlist, established by inspection and CDC lint.
- `GRPR-UART-013` (async-assert, sync-deassert reset) — needs a reset-strategy review across the SoC, not a block test.

### What this bench does not attempt

No functional coverage collection, no constrained randomisation, no reference model. Those remain the pyuvm flow's job, and this section is a complement to it rather than a replacement — the directed tests pin down specific behaviours, and the UVM environment is what will give coverage closure once the scoreboard exists.

## Testscases

- **`UartSanityTest`** (exists — `hw/dv/ahb_uart/tests/uart_test.py`): basic configuration, receive data and then send data ( simple ASCII messages). (Not full duplex)'
- **`UartFullDuplexTest`** : basic configuration, receive data and then send data ( simple ASCII messages). (Not full duplex)'
- **`UartResetTest`** : advanced configuration, full-duplex data transmission, resets mid-transmission.
- **`UartErrorInjectTest`** : advanced configuration (different test cases), full duplex.'
        - **Baud-rate sweep**: parametrize `CLK_DIV` across corner + random values, verify measured bit period (`V-UART-STM-008`/`COV-003`).
        - **Framing-error injection**: force a bad start/stop bit via the UART agent driver, verify `RX_FRAME_ERROR`/`RX_BREAK` (`V-UART-STM-006`/`CHK-007`).
        - **Illegal-access**: writes to `STATUS`/`RXDATA`, write-while-full, read-while-empty — confirm `HRESP` error and no corruption (`V-UART-STM-003/004/005`).
- **`UartRandomTest`** : chaos.'

## Open Items
- UVM-style testcases just fail.
- The random sequences don't seem to really work that concurrently.
- Is the 'UVM' methodology creep too heavy? can I simplifiy the reg model + randomness etc
- The Monitor warns about bad start and stop bits - this should not be the case.
- Currently the checks are in the sequences (bad UVM separation of concerns)
- No scoreboard exists yet — this blocks every `CHK` item above from actually running; building it is the top DV priority for this block.
- `hw/dv/ahb_uart/tbench/ahb_uart_env.py` imports from a stale `hw.dv.ahb3` path — needs fixing to point at `hw/dv/uvc/ahb3lite/` before new tests are layered on top.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`) — needed before any of the above tests can actually be executed in CI or locally in a repeatable way.
- No coverage yet + No Scoreboard
