# UART Verification Plan

**Design doc:** [UART](../../design/blocks/UART.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (UART VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** Most-mature block. `hw/dv/ahb_uart/` (pyuvm test + sequences) and `hw/dv/uvc/uart/`, `hw/dv/uvc/ahb3lite/` (reusable UVCs) already exist, but the pyuvm flow is blocked on a missing scoreboard. `hw/tb/uart/test_uart.py` is a standalone directed cocotb testbench that runs today — **29 tests, 29 passing** — see [Directed Verification](#directed-verification).

---

## Directed Verification

The matrix above describes the pyuvm flow, whose `CHK` items are all blocked on a scoreboard that does not exist yet. This section describes the **directed cocotb bench**, which runs today and needs no scoreboard — each test asserts directly.

```bash
source .env/bin/activate
fusesoc run ahb_uart_directed
```

- **Bench:** `hw/tb/uart/test_uart.py`
- **Core:** `hw/tb/uart/uart_cocotb.core` (`sharc:comms_ip:ahb_uart_directed`), toplevel `ahb_uart`
- **Bus helpers:** `hw/tb/tb_utils/ahb_utils.py` — `ahb_read`/`ahb_write` take a `size=` argument for byte/halfword accesses and are wait-state aware
- **Baud arithmetic:** `clk_div_for_baud` from `hw/dv/ahb_uart/uart_clk_math.py`, already imported by the bench

Items are numbered `V-UART-DIR-NNN`, a separate series from the `STM`/`CHK`/`COV` items above so directed coverage stays traceable on its own. Items whose **Test** column names a function in `hw/tb/uart/test_uart.py` are implemented; the rest are named for the test that should exist.

### `GRPR-UART-001` / `-025` / `-026` / `-027` — register map and decode

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-001` | `test_register_decode` | Read/write each of `CTRL`/`STATUS`/`TXDATA`/`RXDATA` at 0x0/0x4/0x8/0xC and confirm each is a distinct register. Also pins the 16-byte aliasing (`0x10` reads back as `CTRL`) and that a read of write-only `TXDATA` returns 0 rather than erroring | `-001`, `-025`, `-026` |
| `V-UART-DIR-002` | `test_access_widths` | Byte/halfword/word reads of `CTRL` all return the whole register — the block does not lane-narrow read data. A byte write to `TXDATA` transmits | `-001`, `-027` |
| `V-UART-DIR-002a` | `test_ctrl_byte_write_lane_isolation` | **`expect_fail`.** A byte write to `CTRL` byte 0 should leave `CLK_DIV` alone; it does not. Executable documentation of limitation `L1` — flips to an unexpected pass the day the RTL grows per-lane masking | `L1` |
| `V-UART-DIR-003` | `test_reserved_bits_read_zero` | Bits above each register's implemented width read 0 and ignore writes; the write-one-shot flush bits read 0 | `-001`, `-026` |

> `V-UART-DIR-001` deliberately asserts the aliasing rather than the absence of it, and `GRPR-UART-025` makes that normative: the decode is `HADDR[3:2]` only, so the map repeats every 16 bytes. `V-UART-CHK-001` below used to ask for "no aliasing within the 4 KiB region", which the RTL has never done.

### `GRPR-UART-002` — CTRL fields

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-004` | `test_ctrl_reset_values` | Out of reset `RX_RESYNC_EN`=1, `CLK_DIV`=all-1s, every other field 0 | `-002` |
| `V-UART-DIR-005` | `test_ctrl_bit_readback` | Each of `ENABLE`/`TX_EN`/`RX_EN`/`RX_RESYNC_EN`/`TX_BREAK`/`CLK_DIV` written and read back independently | `-002` |
| `V-UART-DIR-006` | `test_ctrl_flush_self_clear` | `FLUSH_TX_FIFO`/`FLUSH_RX_FIFO` read back 0 on the cycle after the write, and the rest of that write lands normally | `-002`, `-019` |
| `V-UART-DIR-007` | `test_ctrl_flush_empties_fifo` | Part-fill each FIFO, flush it, confirm the empty flag returns and no stale byte reappears | `-002`, `-019` |

### `GRPR-UART-003` — STATUS fields

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-008` | `test_status_bits_toggle` | Every bit observed both asserted and deasserted | `-003` |
| `V-UART-DIR-009` | `test_status_tx_active` | `TX_ACTIVE` high for the duration of a frame and low either side of it | `-003` |
| `V-UART-DIR-010` | `test_status_sticky_read_clear` | `RX_FRAME_ERROR` and `RX_BREAK` are sticky, and **both** clear on a `STATUS` read — see the note below | `-003`, `-021` |

> `V-UART-DIR-010` settles a question the design doc raised as an open item. The RTL's read-clear block assigns both `status_rx_frame_error` and `status_rx_break`, so both clear. The duplicated-assignment bug the open item described is in the abandoned UART copy that became `hw/rtl/gpio/ahb_gpio_ctrl.sv`, not here. The test exists to keep it that way.

### `GRPR-UART-004` — TXDATA push, reject when full

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-011` | `test_uart_tx_byte` | Write a byte, capture the 8N1 frame on `uart_tx`, confirm `TX_EMPTY`/`TX_ACTIVE` afterwards | `-004` |
| `V-UART-DIR-012` | `test_tx_fifo_full_write_errors` | Fill to `TX_FULL`, confirm the next write raises an error response and does not corrupt the queued bytes | `-004` |
| `V-UART-DIR-013` | `test_tx_byte_order` | A burst of distinct bytes leaves the FIFO in the order written | `-004` |

### `GRPR-UART-005` / `-029` — RXDATA pop, reject when empty

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-014` | `test_uart_rx_byte` | Bit-bang a byte onto `uart_rx`, read it back; reading the **last** byte must not error, and the read after it must | `-005`, `-029` |
| `V-UART-DIR-015` | `test_read_empty_rxdata_errors` | Reading an empty FIFO raises the error response | `-005` |
| `V-UART-DIR-016` | `test_errored_read_does_not_pop` | An errored `RXDATA` read leaves the FIFO untouched | `-005` |

> The last-byte case in `V-UART-DIR-014` is the regression guard for the read-validity phasing that `GRPR-UART-029` makes normative. `rx_read` pops during the address phase, so `RX_EMPTY` may be high by the data phase; deciding the error there would reject a legitimate read.

### `GRPR-UART-006` — illegal writes

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-017` | `test_write_to_read_only_errors` | Writes to `STATUS` and `RXDATA` both raise the error response | `-006` |

### `GRPR-UART-007` / `-020` / `-022` / `-023` — framing errors, break detection, interrupts

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-018` | `test_rx_bad_start_bit` | A start bit that is not low at the mid-bit sample sets `RX_FRAME_ERROR`, and no byte is queued. Also pins the mid-bit sample point: a low pulse shorter than half a bit reads as a false start | `-007`, `-022`, `-024` |
| `V-UART-DIR-019` | `test_rx_bad_stop_bit` | A stop bit that is not high sets `RX_FRAME_ERROR`, does **not** set `RX_BREAK` when the data bits were high, and queues nothing | `-007`, `-022` |
| `V-UART-DIR-020` | `test_rx_break_detect` | The line held low through start + 8 data + stop sets `RX_BREAK`, and no byte is queued | `-007`, `-020` |
| `V-UART-DIR-021` | `test_rx_error_irq_pulses` | `rx_error_irq` pulses on a frame error and not on a good byte; `rx_irq` pulses on each good byte | `-023` |
| `V-UART-DIR-038` | `test_break_exit_requires_line_high` | The receiver stays in its break state until `uart_rx` returns high, and the first frame after the line recovers is received cleanly | `-020` |
| `V-UART-DIR-039` | `test_sticky_set_wins_over_read_clear` | A framing error landing in the same cycle as the clearing `STATUS` read leaves the sticky bit set | `-021` |

Injection can reuse the UART agent in `hw/dv/uvc/uart/`, or the bench's own `drive_rx_frame(start_bit=, stop_bit=)` helper — the latter keeps the directed bench free of pyuvm dependencies.

### `GRPR-UART-008` / `-018` — TX_BREAK

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-022` | `test_tx_break_from_idle` | `uart_tx` held low continuously while `TX_BREAK`=1, and returns high when cleared | `-008` |
| `V-UART-DIR-023` | `test_tx_break_overrides_fifo` | A byte queued while `TX_BREAK`=1 is not transmitted, stays in the FIFO, and goes out once the break clears | `-008`, `-018` |
| `V-UART-DIR-036` | `test_tx_break_mid_frame_completes_character` | `TX_BREAK` asserted mid-character lets that character finish intact on the wire before the line goes to break — `GRPR-UART-018`, not a mid-character abort. Also checks the ≥1 bit period of mark between break release and the next start bit | `-018` |

### `GRPR-UART-010` / `-024` — baud divider and sample points

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-024` | `test_baud_sweep_tx` | Sweep `CLK_DIV` corners (0, 9, 63, max), measure the start-bit width on `uart_tx` and compare against `HCLK / (8 × (CLK_DIV+1))` | `-010`, `-024` |
| `V-UART-DIR-025` | `test_baud_sweep_rx` | Receive correctly at the same corners | `-010` |
| `V-UART-DIR-040` | `test_rx_samples_at_bit_centre` | Drive a frame whose data bits are corrupted only in their outer quarters; it must still be received correctly, proving the sample lands at tick 4 of 8 | `-024` |

`test_uart_tx_byte` already exercises one rate (1.25 MBaud), so the sweep extends rather than replaces it.

### `GRPR-UART-011` — FIFO depth

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-026` | `test_fifo_depth_boundaries` | `TX_FULL`/`RX_FULL` assert on exactly the 4th entry and deassert on the first pop, in both directions | `-011` |
| `V-UART-DIR-027` | `test_full_duplex_traffic` | Simultaneous TX and RX traffic without either FIFO disturbing the other | `-011` |

### `GRPR-UART-014` / `-015` / `-016` — enables and gating

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-030` | `test_disable_freezes_block` | With `ENABLE=0` no frame is transmitted or received, and the FIFOs, `CTRL` and the sticky flags all survive. Do **not** assert that `uart_tx` returns to mark — per `L6` it holds its last level | `-014` |
| `V-UART-DIR-031` | `test_tx_fifo_full_write_errors`, `test_tx_byte_order` | Both queue bytes with `TX_EN=0` and drain them after setting `TX_EN`, which is the `GRPR-UART-015` TX case: the enable gates the transmitter, not the FIFO | `-015` |
| `V-UART-DIR-032` | `test_rx_fifo_survives_rx_en_clear` | Receive bytes, clear `RX_EN`, confirm the RX FIFO still reads back its contents in order and that no new frames are captured while it is clear. Also that clearing `TX_EN` parks `uart_tx` at mark within one baud tick | `-015` |
| `V-UART-DIR-033` | `test_tx_rx_en_restart_from_idle` | With `ENABLE` held set, clear and re-assert `RX_EN` part-way through an incoming character: the receiver must pick up on the *next* start bit rather than latch a partial frame. Same for `TX_EN` with a byte already queued | `-016` |
| `V-UART-DIR-043` | `test_disable_midframe_freezes_line` | Clear `ENABLE` mid-character and confirm the documented `L6` behaviour: `uart_tx` frozen at its last level, and re-enabling resumes the same character rather than restarting. The regression target if `L6` is ever fixed | `L6` |

### `GRPR-UART-017` — RX resynchronisation

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-034` | `test_rx_resync_tolerates_baud_error` | Drive frames at a bit period a few percent off the configured rate, in both directions, with `RX_RESYNC_EN=1`; all bytes received correctly | `-017` |
| `V-UART-DIR-035` | `test_rx_no_resync_narrower_margin` | The same skew with `RX_RESYNC_EN=0` misses at a skew the resynchronised receiver tolerates, showing the bit actually does something | `-017` |

> `V-UART-DIR-035` has to be written against measured margins, not a guessed number: with 8× oversampling the static margin before resync is roughly ±½ sample per bit accumulated over 10 bits. Find the failing skew empirically, then assert either side of it.

### `GRPR-UART-019` — FIFO flush

Covered by `V-UART-DIR-006`/`-007` above, plus:

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-037` | `test_flush_does_not_abort_active_frame` | A `FLUSH_TX_FIFO` issued mid-character lets that character complete on the wire and only suppresses the frames behind it | `-019` |

### `GRPR-UART-028` — AHB response behaviour

A **single-cycle** `HRESP` — what this block did until recently — passes every functional test above while violating AHB-Lite, so the response shape needs checking on the wire.

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-UART-DIR-028` | `test_read_empty_rxdata_errors` | The response is cycle-accurate: `HREADYOUT`/`HRESP` = `(0,1)` then `(1,1)` | `-028` |
| `V-UART-DIR-029` | `test_access_after_error` | The transfer following an error is neither lost nor applied twice — the address-phase hold during the wait state. Checked on the wire, because `TX_EMPTY` tracks the FIFO and the transmitter pops it within a few cycles | `-028` |

### Known limitations

Rows for the `L*` entries in [UART § Known Limitations](../../design/blocks/UART.md#known-limitations). These pin down what the RTL *does*, so a fix shows up as a test change rather than a silent behaviour change.

| Item | Test | What it does | Limitation |
|---|---|---|---|
| `V-UART-DIR-002a` | `test_ctrl_byte_write_lane_isolation` | See the register-map section above — `expect_fail` guard on the `CTRL` byte-write clobbering `CLK_DIV` | `L1` |
| `V-UART-DIR-041` | `test_txdata_write_wrong_lane` | A byte write to `TXDATA+1..3` is answered OKAY and pushes nothing. Documents the silent drop; becomes an error-response check if `L2` is fixed | `L2` |
| `V-UART-DIR-042` | `test_rx_overrun_overwrites_oldest` | Receive a 5th byte while `RX_FULL`: `rx_irq` still pulses, no status bit records the overrun, and the oldest unread entry has been replaced. Documents `L3` and is the regression target for an `RX_OVERRUN` bit if one is added | `L3` |
| `V-UART-DIR-043` | `test_disable_midframe_freezes_line` | See the enables section above — `ENABLE` cleared mid-character freezes `uart_tx` at its last level instead of parking it at mark | `L6` |

### Requirements deliberately not in this section

Three requirements are structural properties that simulation can show a symptom of but cannot prove. Giving them directed rows would overstate coverage:

- `GRPR-UART-009` (`uart_rx` through a 2-stage synchroniser) — a directed test can show bytes still arrive when `uart_rx` transitions off the `HCLK` grid, but not that the synchroniser hardens against metastability. Needs CDC lint. Tracked by `V-UART-CHK-009` above.
- `GRPR-UART-012` (single clock domain) — a structural property of the netlist, established by inspection and CDC lint.
- `GRPR-UART-013` (async-assert, sync-deassert reset) — needs a reset-strategy review across the SoC, not a block test.

### What this bench does not attempt

No functional coverage collection, no constrained randomisation, no reference model. Those remain the pyuvm flow's job, and this section is a complement to it rather than a replacement — the directed tests pin down specific behaviours, and the UVM environment is what will give coverage closure once the scoreboard exists.

## Metric-Driven Testing


### MDV Testbench Architecture

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
| `V-UART-CHK-001` | Check | Register offsets/decode match 0x0/0x4/0x8/0xC exactly, and the map aliases every 16 bytes as `GRPR-UART-025` specifies (`HADDR[3:2]` decode). Reads of write-only `TXDATA` and of unimplemented bits return 0 without an error response | `GRPR-UART-001`, `-025`, `-026` | Scoreboard |
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
| `V-UART-CHK-007` | Check | `RX_FRAME_ERROR` asserts on both; `RX_BREAK` asserts only when the line is low continuously from the start edge through the stop-bit sample, and the receiver holds its break state until the line returns high | `GRPR-UART-007`, `-020` | Scoreboard |
| `V-UART-STM-007` | Stimulus | Assert `TX_BREAK` mid-transmission, while idle, and with bytes queued | `GRPR-UART-008`, `-018` | New directed test |
| `V-UART-CHK-008` | Check | `uart_tx` held low continuously while `TX_BREAK=1`; a character already in flight completes first; queued bytes survive the break and go out afterwards, with ≥1 bit period of mark in between | `GRPR-UART-008`, `-018` | UART agent monitor + scoreboard |
| `V-UART-CHK-009` | Check | Drive `uart_rx` asynchronously (unrelated clock/phase to `HCLK`) and confirm no metastability-class failures / correct 2-stage-synchronized capture | `GRPR-UART-009` | UART agent monitor, CDC-aware directed test |
| `V-UART-STM-008` | Stimulus | Sweep `CLK_DIV` across its full 10-bit range and measure resulting bit period on `uart_tx` | `GRPR-UART-010`, `-024` | New directed test |
| `V-UART-COV-003` | Coverage | `CLK_DIV` corner values (0, mid, max) each exercised for both TX and RX | `GRPR-UART-010` | Coverage collector |
| `V-UART-STM-009` | Stimulus | Fill and drain both FIFOs across their full 4-entry depth, including simultaneous TX+RX traffic | `GRPR-UART-011` | New directed + randomized test |
| `V-UART-CHK-010` | Check | FIFO full/empty flags transition at exactly the 4th entry boundary in both directions | `GRPR-UART-011` | Scoreboard |
| `V-UART-STM-010` | Stimulus | Toggle `ENABLE`/`TX_EN`/`RX_EN` around live traffic: mid-frame, with FIFOs part-filled, and while re-enabling into an active line | `GRPR-UART-014`, `-015`, `-016` | New directed test |
| `V-UART-CHK-011` | Check | `ENABLE=0` freezes both FSMs without disturbing FIFOs, `CTRL` or the sticky flags (a freeze, not a park — model `L6`); `TX_EN`/`RX_EN` gate only their own direction and never the FIFOs, and a direction re-enabled under a held `ENABLE` resumes from idle, never mid-character | `GRPR-UART-014`, `-015`, `-016`, `L6` | Scoreboard (reference FIFO model) |
| `V-UART-STM-011` | Stimulus | Drive `uart_rx` at bit periods skewed a few percent either side of the configured rate, with `RX_RESYNC_EN` both set and clear | `GRPR-UART-017` | UART agent (needs a per-bit period override) |
| `V-UART-CHK-012` | Check | With `RX_RESYNC_EN=1` the skewed frames are received correctly and at most one resync happens per bit; with it clear the same skew degrades as predicted by the 8× static margin | `GRPR-UART-017` | Scoreboard |
| `V-UART-CHK-013` | Check | `RX_FRAME_ERROR` and `RX_BREAK` are sticky, clear together on a lane-0 `STATUS` read, and a set coincident with that read wins | `GRPR-UART-021` | Scoreboard |
| `V-UART-CHK-014` | Check | No byte reaches the RX FIFO for any frame failing the start- or stop-bit check | `GRPR-UART-022` | Scoreboard (reference FIFO model) |
| `V-UART-CHK-015` | Check | `rx_irq` pulses exactly once per good byte and `rx_error_irq` exactly once per framing error (breaks included); neither is ever level-held | `GRPR-UART-023` | Scoreboard + IRQ monitor |
| `V-UART-CHK-016` | Check | Every errored access is a two-cycle AHB-Lite ERROR — `(HREADYOUT, HRESP)` = `(0,1)` then `(1,1)` — and the transfer behind it is applied exactly once | `GRPR-UART-028` | AHB3Lite monitor + scoreboard |
| `V-UART-COV-004` | Coverage | `RX_RESYNC_EN` × skew direction (early/late/none) crossed with `CLK_DIV` corners | `GRPR-UART-017` | Coverage collector |
| `V-UART-COV-005` | Coverage | RX FIFO observed receiving a byte while `RX_FULL` (the overrun case, limitation `L3`) | `L3` | Coverage collector |

## Testscases

- **`UartSanityTest`** (exists — `hw/dv/ahb_uart/tests/uart_test.py`): basic configuration, receive random data and send random data with regular configuration ( simple ASCII messages). (Not full duplex)'

- **`UartFullDuplexTest`** : full-duples data transmission'

- **`UartResetTest`** : advanced configuration, full-duplex data transmission, resets mid-transmission.

- **`UartErrorInjectTest`** : advanced configuration (different test cases), full duplex.'
        - **Baud-rate sweep**: parametrize `CLK_DIV` across corner + random values, verify measured bit period (`V-UART-STM-008`/`COV-003`).
        - **Framing-error injection**: force a bad start/stop bit via the UART agent driver, verify `RX_FRAME_ERROR`/`RX_BREAK` (`V-UART-STM-006`/`CHK-007`).
        - **Illegal-access**: writes to `STATUS`/`RXDATA`, write-while-full, read-while-empty — confirm `HRESP` error and no corruption (`V-UART-STM-003/004/005`).
        - **Baud skew**: drive `uart_rx` off-rate with `RX_RESYNC_EN` set and clear (`V-UART-STM-011`/`CHK-012`/`COV-004`).
        - **RX overrun**: keep receiving past `RX_FULL` and record what the block does — limitation `L3`, `V-UART-COV-005`.

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
- **Directed gaps, in rough priority order.** The requirements added from the RTL sweep are unevenly covered:
  - `GRPR-UART-014`/`-016` and limitation `L6` (disable behaviour, clean restart after enabling) have no test at all — `V-UART-DIR-030`, `033`, `043`. `L6` — clearing `ENABLE` mid-character freezes `uart_tx` low, which the far end reads as a break — is the most likely of the limitations to bite real firmware, so this is the gap to close first.
  - `GRPR-UART-017` (`RX_RESYNC_EN`) is completely unverified — every existing test runs with it set and at an exact baud match, so the bit could be tied off and nothing would notice. `V-UART-DIR-034`/`035` need the bench's `drive_rx_frame` to take a per-bit period.
  - Limitation `L3` (RX overrun overwrites the oldest FIFO entry, silently) has no test and no status bit. `V-UART-DIR-042` documents it; deciding whether to add an `RX_OVERRUN` bit is a design open item.
  - `GRPR-UART-018` mid-character break, `GRPR-UART-019` flush-during-frame, `GRPR-UART-024` sample-point proof, and `L2` (`TXDATA` wrong-lane write silently dropped) are each a single small test — `V-UART-DIR-036`, `037`, `040`, `041`.
