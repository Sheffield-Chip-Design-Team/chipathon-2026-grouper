# ahb_gpio_ctrl directed testbench

Directed cocotb tests for the GPIO mux control register block, written against
[GPIO Mux.md](../../../planning/Hardware/design/blocks/GPIO%20Mux.md) before
the RTL existed. Each test names the `GRPR-GPIO-*` requirement it covers.

## Running

```bash
source .env/bin/activate
fusesoc library add grouper_soc .          # once, if not already registered
fusesoc run --no-export sharc:comms_ip:ahb_gpio_ctrl_directed
```

Lint the block on its own:

```bash
fusesoc run --no-export --target=lint sharc:comms_ip:ahb_gpio_ctrl
```

## DUT port contract

The testbench drives these names, so the RTL has to match them. The full
declaration is in the docstring at the top of `test_gpio.py`.

| Port | Dir | Width | Notes |
|---|---|---|---|
| `HCLK`, `HRESETn` | in | 1 | |
| `HADDR`, `HBURST`, `HMASTLOCK`, `HPROT`, `HSIZE`, `HTRANS`, `HWDATA`, `HWRITE` | in | | AHB-Lite address/write phase |
| `HRDATA`, `HREADYOUT`, `HRESP` | out | | |
| `HREADYIN`, `HSEL` | in | 1 | |
| `gpio_in` | in | `NUM_GPIO` | Pad value, already synchronised at `grouper_soc_top` |
| `gpio_out_val` | out | `NUM_GPIO` | `GPIO_OUT` — `io_ss` muxes this against the alternate function |
| `gpio_oe_val` | out | `NUM_GPIO` | `GPIO_OE` — likewise |
| `gpio_alt_sel` | out | `NUM_GPIO` | `GPIO_ALTSEL` — selects the mux in `io_ss` |
| `gpio_sync_en_n` | out | `NUM_GPIO` | Passes through `io_ss` to the top-level synchronisers |
| `gpio_ie`, `gpio_pu`, `gpio_pd`, `gpio_cs`, `gpio_sl` | out | `NUM_GPIO` | Pass straight through `io_ss` to the pads |

`GPIO_RO_MASK` has no port — it only feeds the internal write check, and the
tests reach it through readback.

## Two things the RTL has to get right

**`GPIO_IN` is not masked by `GPIO_IE`.** The input enable disables the pad's
input buffer out in the pad ring, so `gpio_in` already reads 0 for a disabled
pad by the time it reaches this block. Masking again here would be redundant
and would make the block untestable standalone. `test_gpio_in_ignores_ie`
pins this down.

**The address-phase capture must be held while `HREADYOUT` is low.** This is
the first slave in the SoC to insert a wait state; `ahb_uart`, `ahb_spi_s` and
`ahb_stub_slave` all advance their pipeline registers on every clock, which is
only correct at zero wait states. Copying that pattern here means the transfer
after an errored write is swallowed or applied twice —
`test_access_after_error` and `drive_error_write()` (which holds the address
phase, as a real master must) are what catch it.

## What this testbench does not cover

The pad mux itself lives in `hw/rtl/io_ss.sv`, not in this block, so the
routing requirement `GRPR-GPIO-003` is only checked here to the extent that
`gpio_alt_sel` reflects the register. Actual pin routing, and the
`GPIO_SYNC_EN_N` bypass at `grouper_soc_top`, are covered by the SoC-level
test in `sw/tests/test_gpio.c`.
