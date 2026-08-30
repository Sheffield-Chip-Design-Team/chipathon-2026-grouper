# AHB GPIO Multiplexer

**Owner:** James
**Status:** Specified, RTL in progress. This document is the design contract — it was written before the RTL and `hw/rtl/gpio/ahb_gpio_ctrl.sv` is built to it, rather than being reverse-engineered from finished RTL. The block currently instantiated in the `GPIO CTRL` slot is `ahb_stub_slave`, which errors on every access.
**Source:** [Schematic Review](../../Schematic%20Review.md) §"Block-Level Design Checklists → 2. AHB GPIO Multiplexer". The source checklist for this block is a single bullet; the pin-sharing scheme, register map and error behaviour below were decided during design and are now firm, superseding the "not yet documented" state of the earlier revision of this file.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — memory map, pin-sharing context | [GPIO Mux Verification Plan](../../verification/blocks/GPIO%20Mux%20Verification%20Plan.md) | [SPI Slave](SPI%20Slave%20Specification.md), [SPI Master](SPI%20Master%20Specification.md), [QSPI](QSPI%20Specification.md) — the peripherals whose pins this block owns

---

## Purpose

Two roles:

1. A general-purpose, firmware-controlled AHB-Lite GPIO peripheral (`GPIO CTRL` in the memory map) driving 16 pads.
2. A physical-pin router that decides, per pad, whether that pad belongs to the GPIO peripheral or to the one serial function hardwired to it.

The block also owns the pad-electrical controls (input enable, pull-up/down, input type, slew rate) and the per-pad synchroniser bypass, so all pad configuration has a single owner.


## Protocols / Standards Conformity

| ID | Requirement |
|---|---|
| `GRPR-GPIO-002` | The block shall expose AHB-Lite subordinate control/status registers at the `GPIO CTRL` region of the memory map (`0x0000_4000`, 4 KiB — see [Grouper SoC Specification § Memory Map](../Grouper%20SoC%20Specification.md#memory-map)). |
| `GRPR-GPIO-010` | The block shall signal invalid accesses with the AMBA 3 AHB-Lite **two-cycle ERROR response**: `HRESP` asserted for two cycles with `HREADYOUT` low on the first and high on the second. |

`GRPR-GPIO-010` is the first two-cycle error response in the SoC. Every other slave (`ahb_uart`, `ahb_spi_s`, `ahb_stub_slave`, and the decoder in `ahb_interconnect_ss`) currently asserts a single-cycle `HRESP`, which is not spec-compliant; each carries a FIXME. Bringing those into line is deliberately **out of scope** here.

## Key Functionality

| ID | Requirement |
|---|---|
| `GRPR-GPIO-001` | Each pad input shall pass through a 2-stage synchroniser, bypassable per pad under register control (`GPIO_SYNC_EN_N`). |
| `GRPR-GPIO-003` | The block shall route each of the 16 pads to either the GPIO peripheral or to that pad's single hardwired alternate function, selected per pad by `GPIO_ALTSEL`. |
| `GRPR-GPIO-004` | Every pad shall be readable through `GPIO_IN` at all times, irrespective of `GPIO_ALTSEL` and `GPIO_OE`. Reads shall never raise an error response. |
| `GRPR-GPIO-005` | The block shall provide per-pad output data and output enable (`GPIO_OUT`, `GPIO_OE`) for pads in GPIO mode. |
| `GRPR-GPIO-006` | The block shall provide per-pad electrical controls: input enable, pull-up, pull-down, input type and slew rate. |
| `GRPR-GPIO-007` | `GPIO_RO_MASK` shall mark pads read-only. A write to `GPIO_OUT` that will never change the value of a RO masked pin. The rest of the unmasked bits may change. |
| `GRPR-GPIO-008` | A write to `GPIO_IN`, or to any reserved offset in the register block, shall raise an error response per `GRPR-GPIO-010`. |
| `GRPR-GPIO-009` | The block shall support byte, halfword and word writes, decoded with `generate_byte_select_32`. |


### Note on `GRPR-GPIO-001`
The synchroniser flops themselves are instantiated externally to the peripheral.

### Note on `GRPR-GPIO-007`
The rule tests whether a write would *change* a locked pad, not whether it *addresses* one. A "any locked bit addressed" rule would make `GPIO_OUT` permanently unwritable as soon as a single pad is locked, because a 32-bit store necessarily addresses all 16. Rejecting the whole write rather than the offending bits means firmware never has to reason about a partially-applied store.


## Block Diagram

```
                      AHB-Lite (0x0000_4000)
                              │
                    ┌─────────▼──────────┐
                    │   ahb_gpio_ctrl    │   CSRs + 2-cycle error response
                    └─────────┬──────────┘
     gpio_out_val, gpio_oe_val│ alt_sel, ie/pu/pd/cs/sl, sync_en_n
                    ┌─────────▼──────────┐
  spi_s ──┐         │                    │
  spi_m ──┼─mux_n_o─►       io_ss        ├──► gpio_out / gpio_oe  ──► pads
  qspi  ──┘         │   (pad mux, pin    │──► gpio_ie/pu/pd/cs/sl ──► pads
          ◄─mux_n_i─┤    assignment)     │──► gpio_sync_en_n      ──► top
                    └─────────▲──────────┘
                              │ gpio_in (already synchronised)
                    ┌─────────┴──────────┐
                    │ grouper_soc_top    │  16 × sync.sv, per-pad bypass
                    └────────────────────┘
```

`ahb_gpio_ctrl` is deliberately generic — it names no peripheral. The pin assignment lives entirely in `io_ss`, and the mux is written against generic `mux_n_o` / `mux_n_oe` / `mux_n_i` buses.

Mux behaviour per pad *n*:

| `ALTSEL[n]` | Pad output | Pad output enable | Value seen by the alternate function |
|---|---|---|---|
| 0 | `GPIO_OUT[n]` | `GPIO_OE[n]` | forced to the function's idle level |
| 1 | `mux_n_o[n]` | `mux_n_oe[n]` | `gpio_in[n]` |

Forcing the function's input to idle when its pad is in GPIO mode is required, not cosmetic: without it, toggling a GPIO would clock the SPI slave. For the active-low `spi_s_ss` the idle level is 1; every other muxed input idles at 0.

## Parameters and Configurations

| Parameter | Default | Notes |
|---|---|---|
| `ADDR_WIDTH` | 32 | AHB address width |
| `DATA_WIDTH` | 32 | AHB data width |
| `NUM_GPIO` | 16 | Number of pads |

`NUM_GPIO` is exposed up through `periph_ss` and `digital_ss`, but the pin assignment table is fixed for 16 pads. `io_ss` shall carry an elaboration-time check that fails loudly if `NUM_GPIO != 16`.

## IOs and External Interfaces

AHB-Lite subordinate, plus the pad interface already declared on `io_ss`: `gpio_in`, `gpio_out`, `gpio_oe`, `gpio_ie`, `gpio_pu`, `gpio_pd`, `gpio_cs`, `gpio_sl`, `gpio_sync_en_n`, each `[NUM_GPIO-1:0]`. On the peripheral side, the SPI Slave, SPI Master and QSPI signals already declared on `io_ss`.

## Register Map

Base `0x0000_4000`, decoded from `HADDR[5:2]` — 16 word slots. Each register is 32 bits with the low 16 used.

| Offset | Name | Access | Reset | Purpose |
|---|---|---|---|---|
| 0x00 | `GPIO_OUT` | R/W | 0x0000_0000 | Output data; writes gated by `GPIO_RO_MASK` |
| 0x04 | `GPIO_IN` | RO | — | Live pad value |
| 0x08 | `GPIO_OE` | R/W | 0x0000_0000 | Output enable |
| 0x0C | `GPIO_ALTSEL` | R/W | 0x0000_0000 | Alternate function select |
| 0x10 | `GPIO_RO_MASK` | R/W | 0x0000_0000 | Read-only pad mask |
| 0x14 | `GPIO_SYNC_EN_N` | R/W | 0x0000_0000 | Input synchroniser bypass |
| 0x18 | `GPIO_IE` | R/W | 0x0000_0000 | Pad input enable |
| 0x1C | `GPIO_PU` | R/W | 0x0000_0000 | Pull-up enable |
| 0x20 | `GPIO_PD` | R/W | 0x0000_0000 | Pull-down enable |
| 0x24 | `GPIO_CS` | R/W | 0x0000_0000 | Input type |
| 0x28 | `GPIO_SL` | R/W | 0x0000_0000 | Slew rate |
| 0x2C–0x3C | Reserved | — | — | Read 0; **write raises ERROR** |

Unlisted bits are reserved: read 0, write ignored.

Every register has the same shape — bit *n* controls pad *n*:

| Bits | Field | Access | Description |
|---|---|---|---|
| 15:0 | per-pad value | see table | Bit *n* applies to pad *n* |
| 31:16 | Reserved | — | Read 0, write ignored |

Field meanings, all active high: `GPIO_OE` 1 = drive the pad. `GPIO_ALTSEL` 1 = the alternate function owns the pad. `GPIO_RO_MASK` 1 = pad is read-only. `GPIO_SYNC_EN_N` 1 = **bypass** the synchroniser (0 = synchronised). `GPIO_IE` 1 = input buffer enabled. `GPIO_CS` 0 = CMOS, 1 = Schmitt. `GPIO_SL` 0 = fast, 1 = slow.

### Reset state and a bring-up warning

Reset leaves every pad an un-driven, un-pulled, synchronised input with the **input buffer disabled**, and every pad assigned to GPIO rather than its alternate function. Nothing is driven and no serial peripheral is connected to a pin until firmware says so.

> **Firmware must set `GPIO_IE` before `GPIO_IN` reads anything.** With the reset value of 0, `GPIO_IN` reads 0 no matter what is on the pad. This applies to the serial peripherals too: the SPI slave cannot receive until `GPIO_IE` is set for pads 0–2 and `GPIO_ALTSEL` for pads 0–3.

## Invalid Access Rules

Errors are reported per `GRPR-GPIO-010` (two-cycle response). An errored write updates no state.

| Access | Condition | Response |
|---|---|---|
| Write `GPIO_IN` | always | ERROR |
| Write reserved offset | always | ERROR |
| Any read | — | never errors (`GRPR-GPIO-004`) |

## Clocking Strategy

`GRPR-GPIO-011`: single clock domain, `HCLK`. The block contains no other clock.

## Reset Strategy

`GRPR-GPIO-012`: asynchronous assertion, synchronous release, active-low `HRESETn`, matching every other AHB peripheral in the SoC. All registers take the reset values in the register map.

## CDC Strategy

`GRPR-GPIO-001` covers it: pad inputs are asynchronous board-level signals and are synchronised by 2-stage synchronisers at `grouper_soc_top` before reaching this block or any serial peripheral. Bypassing the synchroniser via `GPIO_SYNC_EN_N` is a deliberate CDC violation, provided for latency-sensitive or externally-synchronous signals; the spec makes no metastability guarantee for a bypassed pad.

Everything downstream of the synchronisers, including the whole mux, is single-domain and needs no further CDC.

## Performance Targets

| ID | Requirement |
|---|---|
| `GRPR-GPIO-013` | Register reads and valid writes complete with zero wait states (`HREADYOUT = 1`). |
| `GRPR-GPIO-014` | Errored writes cost exactly one wait state, per the two-cycle response. |
| `GRPR-GPIO-015` | The mux is purely combinational: a pad in alternate-function mode adds no cycles between the peripheral and the pad. |

## Size Estimate

TBD. Dominated by 11 × 16 = 176 register flops plus 16 2:1 output muxes; the pad-electrical registers are the bulk and are static after boot.

## Open Items

- `GPIO_SYNC_EN_N` cannot be verified at SoC level until [hw/tb/top/grouper_soc_hello_tb.sv](../../../../hw/tb/top/grouper_soc_hello_tb.sv) instantiates `grouper_soc_top` instead of `digital_ss` — the synchronisers sit above the current DUT boundary. The testbench already carries a FIXME for this.
- `GPIO_RO_MASK` gates `GPIO_OUT` only. Extending it to `GPIO_OE` and `GPIO_ALTSEL` — which also change who drives a pad — and making `GPIO_RO_MASK` self-locking so a locked configuration cannot be undone, are both deliberate non-goals of this revision.
- Pad 15 has no alternate function. If a fifth serial signal is ever needed, it is the free one.
- The [GPIO Mux Verification Plan](../../verification/blocks/GPIO%20Mux%20Verification%20Plan.md) lists the GPIO agent as missing; `hw/dv/uvc/gpio/` now exists. That plan also lists `V-GPIO-STM-003`/`V-GPIO-COV-001` as blocked on the pin-sharing scheme, which this document now defines — both are unblocked and the plan needs updating.

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-GPIO-001` | `V-GPIO-CHK-001`, `V-GPIO-STM-001` (SoC level blocked — see Open Items) |
| `GRPR-GPIO-002` | `V-GPIO-STM-002`, `V-GPIO-CHK-002` |
| `GRPR-GPIO-003` | `V-GPIO-STM-003`, `V-GPIO-COV-001` (now unblocked by the Pin Assignment table) |
| `GRPR-GPIO-004` | `V-GPIO-CHK-003` — read `GPIO_IN` with `ALTSEL` set and with `OE` clear |
| `GRPR-GPIO-005` | `V-GPIO-CHK-004` |
| `GRPR-GPIO-006` | `V-GPIO-CHK-005` |
| `GRPR-GPIO-007` | `V-GPIO-CHK-006` — both the changing (ERROR) and non-changing (OK) write to a locked pad |
| `GRPR-GPIO-008` | `V-GPIO-CHK-007` |
| `GRPR-GPIO-009` | `V-GPIO-STM-004` — byte and halfword writes touch only their lanes |
| `GRPR-GPIO-010` | `V-GPIO-CHK-008` — cycle-accurate `HREADYOUT`/`HRESP`, plus a normal access immediately after an errored one |
| `GRPR-GPIO-011` | `V-GPIO-CHK-009` |
| `GRPR-GPIO-012` | `V-GPIO-CHK-010` — reset values match the register map |
| `GRPR-GPIO-013` | `V-GPIO-CHK-011` |
| `GRPR-GPIO-014` | `V-GPIO-CHK-008` (same waveform check) |
| `GRPR-GPIO-015` | `V-GPIO-CHK-012` |

See [GPIO Mux Verification Plan](../../verification/blocks/GPIO%20Mux%20Verification%20Plan.md) for the full item definitions and test list.
