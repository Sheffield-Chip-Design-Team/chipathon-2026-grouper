# GPIO Mux Verification Plan

**Design doc:** [GPIO Mux](../../design/blocks/GPIO%20Mux.md)
**Source:** [Schematic Review](../../Schematic%20Review.md) §5 "Verification Summary" — block-level testbench architecture (GPIO VIP ↔ DUT ↔ AHB VIP ↔ Scoreboard).
**DV status:** No RTL, no VIP, no tests exist yet — this block is pre-RTL per the Schematic Review's own TODO list (see [GPIO Mux § Status](../../design/blocks/GPIO%20Mux.md)).

---

## Testbench Architecture

Per the Schematic Review's block-level testbench diagram: **GPIO VIP (active) ↔ GPIO CTRL (DUT) ↔ AHB VIP (active)**, feeding a **Scoreboard**.

```
        ┌──────────────┐        ┌──────────────┐
        │  GPIO Agent  │◄──────►│              │
        │ (active VIP) │  DUT   │  GPIO CTRL   │
        └──────────────┘  pins  │  + IO MUX    │
        ┌──────────────┐        │              │
        │  AHB3Lite    │◄──────►│              │
        │  Agent       │  AHB   └──────────────┘
        │ (active VIP) │  bus
        └──────┬───────┘
               │
        ┌──────▼───────┐
        │  Scoreboard   │  (does not exist yet — see gap below)
        └───────────────┘
```

Note this block has two distinct DUT roles per [GPIO Mux § Purpose](../../design/blocks/GPIO%20Mux.md#purpose): a firmware-facing GPIO register block, and a physical pin router shared with SPI Master/Slave/QSPI/UART. The testbench above covers the GPIO-register role directly; the pin-routing role can only be verified once the pin-sharing scheme (currently an open item) is defined — see below.

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| AHB3Lite Agent | **Exists** — `hw/dv/uvc/ahb3lite/` | Reuse as-is. |
| GPIO Agent (driver/monitor/sequencer/item) | **Missing — new** | Build following the pattern established in `hw/dv/uvc/uart/` (agent + driver + monitor + sequencer + item). Needs to drive/monitor GPIO pin state and, once defined, the shared-pin mux control. |
| Scoreboard / reference model | **Missing** | Needs to model 2-stage synchroniser latency on every input and, once the pin-sharing scheme exists, correct mux routing per peripheral ownership. |
| Functional coverage collector | **Missing** | New — see `V-GPIO-COV-*` below. |

## Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-GPIO-STM-001` | Stimulus | Drive each GPIO input pin with async transitions relative to `HCLK` | `GRPR-GPIO-001` | New GPIO agent driver |
| `V-GPIO-CHK-001` | Check | Each input passes through exactly 2 synchronizing flops before being visible to internal logic; measure observed latency matches `DEPTH=2` | `GRPR-GPIO-001` | Scoreboard, cross-check against `hw/rtl/common/sync.sv` behavior (same component UART's RX path already relies on) |
| `V-GPIO-STM-002` | Stimulus | Drive AHB register read/write traffic to the `GPIO CTRL` region | `GRPR-GPIO-002` | New directed test, AHB3Lite agent |
| `V-GPIO-CHK-002` | Check | Register decode matches the `GPIO CTRL` memory-map region exactly (see [Grouper SoC Specification § Memory Map](../../design/Grouper%20SoC%20Specification.md#memory-map)) | `GRPR-GPIO-002` | Scoreboard |
| `V-GPIO-STM-003` | Stimulus | Exercise mux routing across all peripherals sharing physical pins (SPI M/S, QSPI, UART) | `GRPR-GPIO-003` | **Blocked** — cannot be written concretely until the pin-sharing scheme in [GPIO Mux § Open Items](../../design/blocks/GPIO%20Mux.md#open-items) is defined |
| `V-GPIO-COV-001` | Coverage | Every peripheral-to-pin routing combination exercised at least once | `GRPR-GPIO-003` | **Blocked** — same dependency as `V-GPIO-STM-003` |

## Suggested Tests

- **Synchroniser latency test**: drive a GPIO input with a transition on a random phase relative to `HCLK`, confirm 2-cycle latency to internal visibility, no glitches propagate (`V-GPIO-STM-001`/`CHK-001`).
- **GPIO register sanity**: basic AHB read/write walk of the `GPIO CTRL` register region, modeled on `UartSanityTest`'s structure (`V-GPIO-STM-002`/`CHK-002`).
- **Pin-mux routing test** *(blocked)*: once the routing scheme is defined, a directed test per peripheral confirming its pins are correctly routed to/from the physical pads and not visible to any other peripheral.
- **Mux contention test** *(blocked)*: if any pins can be simultaneously requested by two peripherals, confirm the arbitration/ownership rule (once defined) is enforced and no pad drive contention occurs.

## Open Items

- This entire block is pre-RTL; the traceability matrix above has two items (`V-GPIO-STM-003`, `V-GPIO-COV-001`) that cannot be made concrete until [GPIO Mux § Open Items](../../design/blocks/GPIO%20Mux.md#open-items) (the pin-sharing scheme) is resolved at the design level. Verification planning for the pin-routing role should be revisited once that design work lands.
- No scoreboard, no GPIO VIP, no tests exist yet for any part of this block.
