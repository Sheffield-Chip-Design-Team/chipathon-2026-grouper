---
name: block-regression
description: Use when running the regression suite for a specific GrouperSoC peripheral block (UART, GPIO, QSPI, SPI Slave, SPI Master) via FuseSoC — its lint plus every cocotb/pyuvm suite that exercises it — not a single one-off test. Triggers on "run regression for <block>", "regress uart", "regress gpio", "regress qspi", "regress spi slave", "regress spi master", "smoke test <block>", "run the full test suite for this block".
---

# Per-block regression

Runs the full set of FuseSoC targets relevant to one peripheral block — lint + directed
cocotb (+ pyuvm where it exists) — and reports pass/fail per target. This is the operational
counterpart to the block's verification plan under
`docs/hardware/verification/blocks/` — that doc says *what* to run and *why*; this skill runs
it.

**`.github/sim-ci-targets.yaml` is the authoritative matrix** of every core/target CI runs
and which legs are `fail_ok: true`. Cross-check against it; add a new block's legs there.

## Block → target mapping

Each peripheral has an RTL core (lint target) and, where a TB exists, a directed cocotb core
(`default` target). UART additionally has a pyuvm core. Run locally with
`fusesoc run --no-export` (these are seconds-to-minutes on Verilator/Icarus; no scheduler
needed). For a big sweep or a shared box, they can also go through homelab-sge — see the
run-on-SGE note at the end.

| Block | Lint core (`--target=lint`) | Directed cocotb (`default`) | pyuvm (`default`) | Verification plan | Known-failing in CI |
|---|---|---|---|---|---|
| UART | `sharc:comms_ip:ahb_uart` | `sharc:comms_ip:ahb_uart_directed` | `sharc:comms_ip:ahb_uart_pyuvm` | `docs/hardware/verification/blocks/UART Verification Plan.md` | `ahb_uart_mdv` (pyuvm) `fail_ok` — 3 AHB-readback failures |
| GPIO Mux | `sharc:comms_ip:ahb_gpio_ctrl` | `sharc:comms_ip:ahb_gpio_ctrl_directed` | — | `docs/hardware/verification/blocks/GPIO Mux Verification Plan.md` | — |
| QSPI | `sharc:comms_ip:ahb_qspi` | `sharc:comms_ip:ahb_qspi_directed` | — | `docs/hardware/verification/blocks/QSPI Verification Plan.md` | `ahb_qspi_directed` `fail_ok` |
| SPI Slave | `sharc:comms_ip:ahb_spi_s` | `sharc:comms_ip:ahb_spi_s_directed` | — | `docs/hardware/verification/blocks/SPI Slave Verification Plan.md` | `ahb_spi_s_directed` `fail_ok` |
| SPI Master | `sharc:comms_ip:ahb_spi_m` | `sharc:comms_ip:ahb_spi_m_directed` | — | `docs/hardware/verification/blocks/SPI Master Verification Plan.md` | not in CI matrix (block is unwired in `periph_ss`) |

Notes:

- **SPI Master's directed core exists (`ahb_spi_m_directed`, `default` target) but is not in
  the CI matrix**, and the block itself is still stubbed out in `periph_ss` (its fabric slot
  holds `ahb_stub_slave`). Run it explicitly if asked, but a green result there does not mean
  it's integrated.
- The `fail_ok: true` legs have **pre-existing, tracked failures** (not CI-setup problems).
  Treat a failure there as "still the known issue" unless the block's plan or a code change
  says otherwise — verify against the plan before calling it a *new* regression.
- Block-level lint targets need no toolchain. The directed suites need cocotb + Icarus; the
  full-SoC firmware tests (not part of a *block* regression) additionally need the RISC-V
  toolchain — those are covered by the top-level cores, not here.

## Procedure

### 1. Run the block's targets

Confirm the environment is set up (`source .env/bin/activate`; `fusesoc library add
grouper_soc .` once). Then loop over the block's row. Prefer `--no-export` so paths in errors
point at the real files:

```bash
BLOCK_LINT=sharc:comms_ip:ahb_uart          # from the table
DIRECTED=sharc:comms_ip:ahb_uart_directed
PYUVM=sharc:comms_ip:ahb_uart_pyuvm          # omit if the block has none

FAILED=""
run() { echo "=== $* ==="; if "$@"; then echo "*** PASS ***"; else echo "*** FAIL ($?) ***"; FAILED="$FAILED [$2]"; fi; }

run fusesoc run --no-export --target=lint "$BLOCK_LINT"
run fusesoc run --no-export "$DIRECTED"
[ -n "$PYUVM" ] && run fusesoc run --no-export "$PYUVM"

echo "===== SUMMARY ====="; [ -z "$FAILED" ] && echo "ALL PASSED" || echo "FAILED:$FAILED"
```

(The short core names from CLAUDE.md — `fusesoc run ahb_uart_directed` — also resolve; the
full VLNVs above are unambiguous.)

### 2. Report

Summarize as a table: target → PASS/FAIL/error, one row per target in the block's row. Before
calling any failure a regression, rule out the boring causes first — stale FuseSoC cache
(`--no-export` and a clean work root), a `fail_ok` leg that was already red, or an
environment/toolchain gap — then cross-check the block's
`docs/hardware/verification/blocks/*.md` for whether the behavior is even claimed done. The
docs are planning material and several specify behavior the RTL stubs/doesn't implement, so
verify against `hw/rtl/` and the plan, not the doc's intent alone.

## Adding a new block

1. Find its RTL core (`hw/rtl/<block>/` → a `.core` with a `lint` target) and any TB core
   under `hw/tb/<block>/` or `hw/dv/`.
2. Add a row to the mapping table (lint core, directed core + target, pyuvm if any, plan doc).
3. Add its legs to `.github/sim-ci-targets.yaml` with the right `group`, `kind`, and
   `fail_ok`, and link/create the verification plan under
   `docs/hardware/verification/blocks/`.

## Running on homelab-sge (optional)

These sims are quick and normally run locally. If you do want them on the scheduler (batch
sweep, shared box), wrap the loop above in a job script, sync the repo to NFS, and `hqsub` it
— see the **sge-job** and **hlab-sge** skills for the sync + submit mechanics. Nothing
block-level touches the PDK, so the container image doesn't matter for these.
