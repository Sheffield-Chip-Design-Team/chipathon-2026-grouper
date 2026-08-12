# Per-block area measurement

Synthesis-only LibreLane configs for the three serial peripherals that are not
yet instantiated in the SoC. They exist so the `ahb_stub_slave` placeholders in
[`periph_ss.sv`](../../hw/rtl/periph_ss.sv) can be sized against something real
instead of a guess.

These are **not** hardening configs — no floorplan, no PDN, no SDC of their own,
never taped out. Each one runs to `Yosys.Synthesis` and stops (~15 s).

```bash
make measure-ge                   # all three blocks, prints a GE table each
make measure-ge GE_BLOCKS=qspi    # just one
```

## Gate equivalents

One GE is the area of one `gf180mcu_fd_sc_mcu7t5v0__nand2_1`:

> **1 GE = 10.976 µm²**

Derived from the cell table in
[`../classic/build.log`](../classic/build.log) — 1215 `nand2_1` instances
totalling 1.33e4 µm², which snaps to 5 sites on the 0.56 × 3.92 µm site grid.
For reference from the same log: `dffq_1` = 5.80 GE, `dffrnq_1` = 6.80 GE,
`mux2_2` = 3.00 GE, and the SoC as a whole is 38.01% sequential area.

[`../../scripts/report_ge.py`](../../scripts/report_ge.py) does the division and
prints the table; it reads the Yosys log out of a run directory.

## Sizing the stubs from these numbers

`ahb_stub_slave` takes a `TARGET_GE` parameter. The intended recipe is

> `TARGET_GE` = (measured area of today's RTL) × (multiplier for the features
> still to be built)

with the multipliers justified from each block's outstanding `TODO`/`FIXME`
markers and its spec under `planning/Hardware/design/blocks/`. As instantiated
in `periph_ss.sv` today:

| Block | Multiplier | Rationale |
|---|---|---|
| SPI slave | 2.0× | no error response, no IRQs, no FIFOs (so `GRPR-SPIS-012` is unmet) |
| SPI master | 1.3× | one open marker; by far the most complete of the three |
| QSPI | 2.0× | 5 open markers, plus the `GRPR-QSPI-021` init FSM does not exist at all |

`TARGET_GE` is a request, not a guarantee: the stub increments its ballast
register 32 bits at a time so its carry chain cannot become the SoC's critical
path, and the width rounds up to whole 32-bit lanes. Achieved area therefore
quantises in steps of roughly 416 GE — well inside the accuracy of the estimates
feeding the targets, but it means a 1,450 GE request lands nearer 1,700.

Only SPI master has a stated figure to check against — `GRPR-SPIM-015`,
1,500–2,000 GE, itself flagged "not yet confirmed by synthesis". SPI slave and
QSPI are both "TBD" in their specs, so these runs are the first real numbers
for them and are worth folding back into those documents.

## Checking what the stubs actually came out at

`USE_SLANG: true` plus `--keep-hierarchy` keeps the three differently
parameterised stubs as three distinct `$paramod\ahb_stub_slave\…` modules in the
netlist, so a single classic-flow synthesis reports each one separately:

```bash
make report-stub-ge RUN_TAG=<tag>
```
