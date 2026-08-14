---
name: pnr-results
description: Dig timing (WNS/TNS per corner), route DRC, Magic DRC, LVS status, and cell/area stats out of a completed (or in-progress) GrouperSoC LibreLane run under librelane/classic/runs/. Use after a run-pnr job finishes, or when the user asks "what's the WNS", "did DRC pass", "how much area", or points at a specific run tag.
---

# pnr-results

LibreLane run directories (`librelane/classic/runs/<tag>/`) are numbered stage
subdirectories. Find the run, then pull only what's needed — these directories are large,
don't `cat` whole reports blindly. On homelab-sge these live on NFS at
`/srv/eda/designs/timothyjabez/chipathon-2026-grouper/librelane/classic/runs/<tag>/`.

## Locate the run

```bash
cd librelane/classic
RUN=$(ls -td runs/*/ | head -1)   # most recent, or use the --run-tag you passed
echo "$RUN"
```

Stage numbers shift depending on which steps the config gates on/off — if a numbered stage
name below doesn't exist, `ls "$RUN"` and match by suffix (`*yosys-synthesis`,
`*openroad-stapostpnr`, `*detailedrouting`, `*checker-magicdrc`).

## Synth-only run (stops at Yosys.Synthesis)

```bash
cat "$RUN"/*yosys-synthesis/reports/chk.rpt     # "Found and reported N problems" — want 0
cat "$RUN"/*yosys-synthesis/reports/stat.rpt    # cell count + area (µm²) in the header block
grep -c "^Latch inferred" "$RUN"/*yosys-synthesis/reports/latch.rpt   # want 0
```

Read `stat.rpt`, never `post_dff.rpt`, for real cell/area numbers.

## Full P&R run

```bash
# Signoff WNS per corner (post-detailed-route, extracted parasitics — the trustworthy number)
cat "$RUN"/*openroad-stapostpnr/max_ss_125C_3v00/wns.max.rpt    # setup, worst corner
cat "$RUN"/*openroad-stapostpnr/min_ff_n40C_3v60/wns.min.rpt    # hold, worst corner
cat "$RUN"/*openroad-stapostpnr/nom_tt_025C_3v30/wns.max.rpt
# TNS is in the sibling tns.*.rpt in the same dir

# Route DRC (TritonRoute) — convergence trend even if the run is still going
grep -hoE "Number of violations = [0-9]+" "$RUN"/*detailedrouting/*.log | tail -5

# Magic DRC error count
python3 -c "
import json, glob
f = sorted(glob.glob('$RUN/*checker-magicdrc/state_out.json'))
print(json.load(open(f[-1])).get('metrics',{}).get('magic__drc_error__count','not found') if f else 'no DRC stage')
"

# LVS
python3 -c "
import json, glob
f = sorted(glob.glob('$RUN/*lvs*/state_out.json'))
print(json.load(open(f[-1])).get('metrics',{}) if f else 'no LVS stage')
"

# Cell/area summary + power grid
cat "$RUN"/*openroad-stapostpnr/reports/*.rpt 2>/dev/null | grep -iE "area|instance" | head
```

## Interpreting the numbers

- **Setup lives at `max_ss_125C_3v00`, hold at `min_ff_n40C_3v60`.** `gf180mcu_fd_sc_mcu7t5v0`
  is 5 V-characterized cells run at 3.3 V core, so SS timing is chronically tight across
  GF180 designs — but on the working landscape config the SoC actually closes with healthy
  margin (setup WNS ≈ **+12 ns** nom_tt, hold WNS ≈ **+0.29 ns** min_ff). A *negative* setup
  WNS is a real regression here, not corner noise; compare against the last good run's number
  before concluding.
- **Route DRC 0 and Magic DRC 0** are the target on the landscape 1650×1100 config
  (portrait variants carry 2 die-edge Metal3 DRCs — expected, not a regression). A route-DRC
  count that *doesn't move* across a stubborn-tiles iteration is a converged fixed point, not
  slow progress — there's nothing to wait for.
- **LVS is expected to report ~179 errors / ~171 unmatched pins**, and the flow **exits 2**
  because of it. This is the unwired `io_ss` bidir slots (`bidir_in[16..39]` have no layout
  geometry) — **RTL, not PD.** Don't chase it as a physical failure; it's fixed in RTL or
  waived via the config's commented `#Netgen.LVS: null` / `#Checker.LVS: null` hooks.
- **Max slew / max cap warnings at nom_tt** (thousands) are almost certainly the library's own
  `default_max_transition` being tighter than the SDC's 3 ns — warnings, not deferred errors,
  unconfirmed but long-standing. Don't treat them as new unless they moved on a change you made.
- If `RUN_MAGIC_DRC`/`RUN_LVS` are disabled in an exploratory config, those checker stages
  won't exist — expected, not a failure to chase.

## Health checks worth repeating

```bash
# Delay-cell abuse guard: dlyc_1 should track the hold-cell count (~90), not run to hundreds.
grep -oE "gf180mcu_fd_sc_mcu7t5v0__dly[a-z]_[0-9]+" "$RUN"/*detailedrouting/*.def | sort | uniq -c
```

Runtime itself is a diagnostic: a healthy full flow is 8–9 min on 20 cores; >15 min means
broken, not busy.

## Reporting back to the user

State: (1) did the flow reach signoff / exit code (noting the deferred LVS if that's the only
reason it's 2), (2) setup + hold WNS per corner if full P&R, (3) route DRC + Magic DRC counts,
(4) cell count / area / utilisation, (5) anything in warnings that isn't already-known noise
(new lint on files just changed vs. long-standing warnings on untouched files).
