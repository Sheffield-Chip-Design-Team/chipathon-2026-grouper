# `results/sdc_falsepath_fix_01_09_26/` — job 5357

Flat-file dump of SGE job 5357 (`grouper-pnr-sdc_falsepath_fix`, run tag
`sdc_falsepath_fix`, 2026-09-01, exit 0). Full narrative and signoff table:
`final/RUN_INFO.md` (this run is now the repo's `final/`).

## What changed since the last documented run (`silver_01_09_26_first_pass`, job 5311)

- `STA_CORNERS` now runs all **three** corners — `max_ss_125C_3v00` was added (job 5342), and
  this is the first documented run to carry its lib/sdf views.
- A `set_false_path` fix for the async `dbg_own` debug-ownership net and the GPIO synchroniser
  bypass (`gpio_1_bidir_in`/`gpio_15_bidir_in`) was added to `grouper_chip_core.sdc` and, after
  a broken first attempt (job 5347, wrong `get_nets` pattern), verified and applied correctly
  in this run.
- Antenna repair margin, `ROUTING_OBSTRUCTIONS` (PDN-stripe short fix), and `DRT_OPT_ITERS`
  were retuned in `config.yaml` per jobs 5335–5337; `RUN_HEURISTIC_DIODE_INSERTION` was tried
  and backed out (jobs 5317/5318/5320 — it flooded the design with 25k–45k diodes).

## Result

- LVS clean, Magic DRC clean, route DRC clean, power grid clean.
- **`max_ss_125C_3v00` setup: 244 violations, worst -20.10 ns, TNS -2327.87 ns.** The
  false-path fix cut this from 409 (job 5347's broken attempt) / 394 (job 5342 baseline), but
  did not close it — this is **not** a clean signoff.
- Antenna improved to 7 net / 7 pin violations (was 13/13 in job 5311).

## Next

All 244 remaining `max_ss` violations fan out from one `cpu_ss` register
(`u_cpu_ss._1236_/Q`) into FIFO/data-register `D` pins across `spi_m`, `spi_s`, `uart_rx`, and
`dbg_ctrl`. Needs tracing back to its RTL name and a real determination of whether it's
async/qualified-late (another false-path/multicycle candidate) or a genuine same-cycle path
needing pipelining. See `final/RUN_INFO.md` for the full reasoning and the ranked next-steps
list.
