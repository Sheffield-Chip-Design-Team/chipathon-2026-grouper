# Per-block area measurement

Synthesis-only LibreLane configs for the three serial peripherals that are not
yet instantiated in the SoC. They exist so the `ahb_stub_slave` placeholders in
[`periph_ss.sv`](../../hw/rtl/periph_ss.sv) can be sized against something real
instead of a guess.

These are **not** hardening configs — no floorplan, no PDN, no SDC of their own,
never taped out. Each one runs to `Yosys.Synthesis` and stops (~15 s).

```bash
make measure-ge                   # synthesize all three, then print one summary
make measure-ge GE_BLOCKS=qspi    # just one block
make report-ge                    # reprint the summary, no resynthesis
```

`measure-ge` runs every block's synthesis first and prints the summary once at
the end — a LibreLane run buries a few hundred lines of its own output between
blocks. Each summary is also kept at
`runs/RUN_<timestamp>/summary`, so successive measurements can be diffed against
each other. Per-block artifacts stay in `runs/ge_<block>/`, and `runs/` is
gitignored.

The multiplied column in the summary is the `TARGET_GE` to set in
[`periph_ss.sv`](../../hw/rtl/periph_ss.sv); the multipliers themselves live in
the `Makefile` as `GE_MULT_<block>`.

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

| Block | Measured | Multiplier | `TARGET_GE` | Rationale |
|---|---|---|---|---|
| SPI slave | 3,483.8 µm² = 317 GE | 2.0× | 635 | no error response, no IRQs, no FIFOs (so `GRPR-SPIS-012` is unmet) |
| SPI master | 14,402.7 µm² = 1,312 GE | 1.3× | 1,706 | one open marker; by far the most complete of the three |
| QSPI | 18,481.4 µm² = 1,684 GE | 2.0× | 3,368 | 5 open markers, plus the `GRPR-QSPI-021` init FSM does not exist at all |

**Read `reports/stat.rpt`, not `reports/post_dff.rpt`.** The latter is taken
before `abc`, so its combinational logic is still generic gates with no area —
it undercut `ahb_spi_m` by 40%. `report_ge.py` selects on content and prefers
`design__instance__area` from the step's `metrics.json` when only a pre-`abc`
stat exists; `--list` shows every report with a "fully mapped" column.

Only SPI master had a stated figure to check against — `GRPR-SPIM-015`,
1,500–2,000 GE, itself flagged "not yet confirmed by synthesis". 1,706 GE lands
inside it, so that requirement can now drop the caveat. SPI slave and QSPI are
both "TBD" in their specs, so these are the first real numbers for them and are
worth folding back into those documents.

Full working, including the GE derivation and the multiplier reasoning, is in
[`../classic/TRIAL_NOTES.md`](../classic/TRIAL_NOTES.md) § Session 4.

## Checking what the stubs actually came out at

`USE_SLANG: true` plus `--keep-hierarchy` keeps the three differently
parameterised stubs as three distinct `$paramod\ahb_stub_slave\…` modules in the
netlist, so a single classic-flow synthesis reports each one separately:

```bash
make report-stub-ge RUN_TAG=<tag>
```
