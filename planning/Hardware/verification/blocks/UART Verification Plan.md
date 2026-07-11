# UART Verification Plan

**Design doc:** [UART](../../design/blocks/UART.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (UART VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** Most-mature block. `hw/dv/ahb_uart/` (pyuvm test + sequences) and `hw/dv/uvc/uart/`, `hw/dv/uvc/ahb3lite/` (reusable UVCs) already exist. `hw/tb/uart_wtb.sv` is a standalone directed testbench.

---

## Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **UART VIP (active) ↔ UART (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**.

```
        ┌──────────────┐        ┌──────────────┐
        │  UART Agent  │◄──────►│              │
        │ (active VIP) │  DUT   │  ahb_uart    │
        └──────────────┘  pins  │  (+ uart     │
        ┌──────────────┐        │   core)      │
        │  AHB3Lite    │◄──────►│              │
        │  Agent       │  AHB   └──────────────┘
        │ (active VIP) │  bus
        └──────┬───────┘
               │
        ┌──────▼───────┐
        │  Scoreboard   │  (does not exist yet — see gap below)
        └───────────────┘
```

Both VIPs are **active** (the AHB agent drives CPU-side register transactions; the UART agent drives/monitors the serial pins), matching the Schematic Review's diagram exactly.

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| AHB3Lite Agent (driver/monitor/sequencer/item) | **Exists** — `hw/dv/uvc/ahb3lite/` | Reuse as-is. |
| UART Agent (driver/monitor/sequencer/item) | **Exists** — `hw/dv/uvc/uart/` | Reuse as-is; drives/monitors `uart_tx`/`uart_rx` at the serial-bit level. |
| UART env (wires agents together) | **Exists** — `hw/dv/ahb_uart/tbench/ahb_uart_env.py` | Note: this file currently imports from `hw.dv.ahb3.*`, a path that doesn't match the real `hw/dv/uvc/ahb3lite/` location — likely a stale import left over from a refactor; fix before adding new tests on top of it. |
| Scoreboard / reference model | **Missing** | No scoreboard exists anywhere in `hw/dv/` yet. For UART this needs to: (a) mirror the 4-register `CTRL`/`STATUS`/`TXDATA`/`RXDATA` map from AHB transactions, (b) independently model FIFO fill/empty/full state and baud timing from `CLK_DIV`, (c) compare bytes driven on `uart_rx` against bytes popped via `RXDATA` reads, and bytes pushed via `TXDATA` against bytes observed on `uart_tx`. |
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

## Suggested Tests

- **`UartSanityTest`** (exists — `hw/dv/ahb_uart/tests/uart_test.py`): basic AHB register sanity. Keep as the smoke test.
- **Baud-rate sweep**: parametrize `CLK_DIV` across corner + random values, verify measured bit period (`V-UART-STM-008`/`COV-003`).
- **TX/RX loopback**: tie `uart_tx` back to `uart_rx` externally in the testbench, send a random byte stream, verify round-trip integrity through the FIFOs.
- **Framing-error injection**: force a bad start/stop bit via the UART agent driver, verify `RX_FRAME_ERROR`/`RX_BREAK` (`V-UART-STM-006`/`CHK-007`).
- **FIFO boundary test**: fill/drain both FIFOs to exactly 4 entries, confirm full/empty flag edges (`V-UART-STM-009`/`CHK-010`).
- **Illegal-access test**: writes to `STATUS`/`RXDATA`, write-while-full, read-while-empty — confirm `HRESP` error and no corruption (`V-UART-STM-003/004/005`).
- **Break test**: assert `TX_BREAK` mid-byte and idle, confirm line behavior (`V-UART-STM-007`).
- **Randomized register/FIFO stress**: pyuvm sequence issuing random AHB register traffic interleaved with random serial traffic, scoreboard checking end-to-end.

## Open Items

- No scoreboard exists yet — this blocks every `CHK` item above from actually running; building it is the top DV priority for this block.
- `hw/dv/ahb_uart/tbench/ahb_uart_env.py` imports from a stale `hw.dv.ahb3` path — needs fixing to point at `hw/dv/uvc/ahb3lite/` before new tests are layered on top.
- No committed cocotb runner/Makefile for this flow (see the top-level `CLAUDE.md`) — needed before any of the above tests can actually be executed in CI or locally in a repeatable way.
