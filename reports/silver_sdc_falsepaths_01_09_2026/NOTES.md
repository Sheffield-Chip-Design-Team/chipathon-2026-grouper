# `reports/sdc_falsepath_fix_01_09_2026/` — job 5357

Log/metric dump of SGE job 5357 (`grouper-pnr-sdc_falsepath_fix`, 2026-09-01, exit 0). Full
narrative and signoff table: `final/RUN_INFO.md` (this run is now the repo's `final/`); a
fuller raw-output dump (including all three GDS variants) is in
`librelane/classic/results/sdc_falsepath_fix_01_09_26/`.

## Short version

This run turns on the `max_ss_125C_3v00` slow corner for the first time (previously
commented out of `STA_CORNERS`) and carries a `set_false_path` fix for two async control
signals (`dbg_own`, the GPIO synchroniser-bypass ports) that a first attempt (job 5347) got
wrong. The fix is verified working, and cut slow-corner setup violations from 409 → **244**,
but LVS/DRC-clean is not the same as timing-clean here: **244 setup violations remain at
`max_ss`, worst slack -20.10 ns**. Do not treat this run as tapeout-ready.

## Next

Every remaining violation traces to one high-fanout `cpu_ss` register broadcasting into
peripheral data registers (`spi_m`, `spi_s`, `uart_rx`, `dbg_ctrl`). Needs its RTL identity
confirmed and a real call on false-path vs. genuine timing-closure work before the next run.
Details and the ranked plan are in `final/RUN_INFO.md`.
