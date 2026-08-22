---
name: pnr-run
description: Use when running or troubleshooting LibreLane synthesis or place-and-route for the GrouperSoC chip core, choosing a floorplan, or reading post-PnR timing (WNS) / Magic DRC / route DRC. Covers the working landscape 1650x1100 config, invocation, flow checkpoints, the delay-cell/fanout timing trap, and mid-flow timing gotchas. Triggers on "run P&R", "run librelane", "synth this", "check WNS", "DRC errors", "gf180mcu_fd_sc_mcu7t5v0", "floorplan".
---

# Running LibreLane (P&R) for GrouperSoC

Hardens `grouper_soc_chip_core` (picorv32 SoC + 4 SRAM macros) with LibreLane on GF180MCU,
foundry 5 V cells `gf180mcu_fd_sc_mcu7t5v0` at 3.3 V core, three signoff corners
(`nom_tt_025C_3v30`, `min_ff_n40C_3v60`, `max_ss_125C_3v00`).

Two ways to run it:

- **Locally**: `nix-shell` in the repo root gives a shell with the `leo/gf180mcu` LibreLane;
  OpenROAD compiles on first use. Full PnR is minutes, so local is fine for iteration.
- **On homelab-sge** (for long or parallel runs): submit via `hqsub` — see the **run-pnr**
  skill for the submit/poll wrapper and **sge-job** for the NFS sync + container paths.

The deep design-decision record lives in `librelane/classic/TRIAL_NOTES.md` — read it before
changing the floorplan, PDN, or cell knobs. This skill is the operational summary.

## The working config — landscape 1650x1100

The current best result (job 4340) is **`librelane/classic/config_1650x1100_keepdlyc_fanout32.yaml`**:
a landscape 1650×1100 die with the row of 4 SRAM macros at x0=22.4, y=200, orientation S.
It is the only floorplan variant that reaches **Magic DRC 0** (the portrait variants carry 2
die-edge Metal3 violations). Signoff on this config:

| | |
|---|---|
| die / core | 1650 × 1100 / 1,744,710 um² |
| route DRC | **0** |
| Magic DRC | **0** |
| setup | TNS 0, WNS **+12.077 ns** (nom_tt), +33.2 (min_ff) |
| hold | TNS 0, WNS **+0.289 ns** (min_ff) |
| power grid | 0 violations, worst IR drop 1.78 mV |
| antennas | 10 nets / 12 pins |
| utilisation | 0.690 |
| runtime | ~8 min on 8 CPUs |

> A portrait `config_1330x1370_keepdlyc_fanout32.yaml` exists with lower wirelength and
> better setup slack, but it has 2 die-edge Metal3 DRCs. Use the **landscape** config when
> the slot demands a landscape aspect or when Magic DRC 0 matters more than wirelength.

**Settled, don't re-litigate without a run:** the macro row stays at x0=22.4, y=200, orient
S. Centring it (job 4341) cost +5.6% wirelength and introduced 20 route DRCs; corner
placement strands macro edges. Growing the die *eastward* is free; growing any other edge is
not.

**The one remaining deferred error is LVS, and it is RTL not PD:** `io_ss` exposes 40 bidir
slots but only 16 are wired, so `bidir_in[16..39]` have no layout geometry and Netgen reports
them unmatched (≈179 errors). This makes the flow exit 2 even on a clean physical result. Fix
in RTL or waive via the commented `#Netgen.LVS: null` / `#Checker.LVS: null` hooks in the
config. It is not a PnR problem.

## Invocation

Run from the config's directory so `runs/<tag>/` lands under `librelane/classic/`:

```bash
cd librelane/classic
librelane config_1650x1100_keepdlyc_fanout32.yaml \
    --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --run-tag <tag> --overwrite
```

- `--to STEP_ID` stops the flow at a step. Useful checkpoints:
  `Yosys.Synthesis` (~15 s sanity check), `OpenROAD.GlobalRouting`
  (floorplan+PDN+placement+CTS+GRT, ~2–5 min), `OpenROAD.STAPostPNR` (signoff STA — the
  only fully trustworthy timing).
- `--only STEP_ID -i <stage>/state_out.json` reruns a single step seeded from a saved stage
  state (used for the timing extraction below).
- `-c KEY=VALUE` overrides a config key. **List-type keys take a bare value**, e.g.
  `-c 'STA_CORNERS=max_ss_125C_3v00'`, *not* JSON-array syntax `["..."]` — the parser doesn't
  decode nested brackets and silently wraps the literal string into a one-element list.

> The repo `Makefile`'s `make librelane` targets point at `librelane/slots/slot_$(SLOT).yaml`
> and `librelane/config.yaml`, which **do not exist** — the real configs are under
> `librelane/classic/` and `librelane/chip/`. Invoke `librelane` against the real config path
> directly (as above) rather than trusting `make librelane` unfixed.

## Extracting real per-corner timing mid-flow

**Gotcha:** LibreLane's metrics dict is cumulative, so `timing__setup__ws__corner:*` keys in
a late stage's `state_out.json` are often **stale placement-based estimates carried forward**,
not fresh post-route numbers — `OpenROAD.GlobalRouting` writes routing metrics only, it does
not recompute setup/hold. This produced a misleading -62 ns/1500-violation reading early on
that was pure pre-route noise. Also, `STAMidPNR`'s human-readable `max.rpt`/`min.rpt` only
report **one** corner per invocation (usually `nom_tt`).

To get a trustworthy fresh per-corner report at any point, rerun `STAMidPNR` standalone,
seeded from a completed stage, restricted to one corner (~15 s):

```bash
librelane config_1650x1100_keepdlyc_fanout32.yaml \
    --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --only OpenROAD.STAMidPNR \
    -i runs/<tag>/37-openroad-globalrouting/state_out.json \
    -c 'STA_CORNERS=max_ss_125C_3v00' -c 'DEFAULT_CORNER=max_ss_125C_3v00' \
    --run-tag <tag>_worst_paths_ss --overwrite
```

Setup wants the slowest path → `max_ss_125C_3v00`; hold wants the fastest → `min_ff_n40C_3v60`
(`{rc}_{pvt}`: `min/nom/max` selects the RC/wire corner, `tt/ss/ff` selects the liberty/cell
corner). **The only fully trustworthy number is post-detailed-routing signoff STA
(`OpenROAD.STAPostPNR`)**, on extracted (not estimated) parasitics.

## The delay-cell / fanout timing trap (why this config exists)

The earlier setup failures were **not** floorplan or congestion — they were a fanout tree
built out of delay cells. `gf180mcu_fd_sc_mcu7t5v0` has twelve delay cells
(`dly{a,b,c,d}_{1,2,4}`); they are functionally buffers (Z=I), so the resizer picks them for
fanout/slew repair and `SYNTH_STRATEGY: "AREA 0"` rewards their small area. A `dlyd_1` used as
a buffer contributed **5.15 ns delay at fanout 11** vs 0.67 ns for a real `buf_4` on the same
load. The config addresses it with **two independent levers**, both needed:

1. **Keep `dlyc`, ban `dlya`/`dlyb`/`dlyd`.** `dlyc` does legitimate *hold* repair (delay per
   area is what it's for); the others were doing *drive-strength* repair, which a delay cell
   is the worst answer to. Don't ban all twelve — that forces hold repair onto long
   `clkbuf_1` chains (3.4× the cells) for no gain.
2. **`MAX_FANOUT_CONSTRAINT: 32`** (up from 16). `rst_n_sync` has 996 loads; at fanout 16 the
   repair tree was ~5 levels deep. 32 fixes the timing on its own but leaves `dlyd_1` armed —
   both levers together is best.

**Health checks to repeat on any new run:**

```bash
# dlyc count should track hold-cell count (~90), NOT run to the hundreds.
# If it does, fanout repair has migrated onto dlyc -> fall back to banning all 12.
grep -oE "gf180mcu_fd_sc_mcu7t5v0__dly[a-z]_[0-9]+" runs/<tag>/*detailedrouting/*.def | sort | uniq -c

# DRT convergence trend: a healthy run falls off a cliff; a plateau flattens at a small nonzero.
grep -hoE "Number of violations = [0-9]+" runs/<tag>/*detailedrouting/*.log
```

Runtime is a diagnostic: a healthy full flow is **8–9 min** (on 20 cores). **Over ~15 min
means something is broken, not busy** — read the DRT trend, not the wall clock.

## Two flags to leave OFF

`RUN_POST_GRT_DESIGN_REPAIR` and `RUN_POST_GRT_RESIZER_TIMING` are gated off in the Classic
flow by default. Enabling them for a full run to signoff on this design makes
`OpenROAD.DetailedRouting` hang (confirmed live TritonRoute grinding, 0-byte log, killed at
3 h) — the repair steps invalidate global-route guides broadly and leave DRT re-resolving far
more congestion. If you need the ~14 real setup endpoints they'd fix, run them in isolation
(`--to OpenROAD.ResizerTimingPostGRT`) to inspect, then re-route deliberately; don't leave
them on for signoff.

## Reading results

See the **pnr-results** skill for the exact WNS / DRC / LVS / area read commands against a
`librelane/classic/runs/<tag>/` directory.
