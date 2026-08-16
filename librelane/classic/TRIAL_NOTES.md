# picorv32_hello_top — LibreLane trial notes

Notes from an interactive PnR investigation on `picorv32_minimal`. Covers how
to run trials on the homelab-sge cluster, a PDN-bugfix regression check, a
clock frequency change, an important gotcha about stale timing metrics
mid-flow, and an in-progress area-reduction experiment.

## Running trials on homelab-sge

The repo lives on NFS at `/srv/eda/designs/timothyjabez/chipathon-2026-grouper`
(sync with `rsync -a --exclude='.git' --exclude='librelane/classic/runs' <local> <nfs>`
— **never use `--delete`**, it wipes NFS-only run artifacts that aren't
tracked in git). The `ip/gf180mcu_ocd_ip_sram` submodule must be initialized
locally first (`git submodule update --init --recursive`) before syncing,
since it's a real dependency (SRAM macro lib/lef/gds) not present until
checked out.

Jobs run via `hqsub` against `HLAB_SGE_URL=http://nas.home:4783`, using
whatever container image the scheduler is preconfigured with (no `--image`
flag on `hqsub` itself). A representative job script:

```bash
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
cd /foss/designs/chipathon-2026-grouper/librelane/classic
/foss/tools/bin/librelane config.yaml \
    --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --to OpenROAD.GlobalRouting \
    --run-tag <tag> --overwrite
```

`--to STEP_ID` stops the sequential flow at a given step. Useful checkpoints
for `Classic` flow: `Yosys.Synthesis` (fast sanity check, ~15s), 
`OpenROAD.GlobalRouting` (floorplan+PDN+placement+CTS+GRT, ~2-5 min),
`OpenROAD.ResizerTimingPostGRT` (post-route repair, if enabled — see below).

## Extracting real per-corner timing mid-flow

**Gotcha:** `OpenROAD.GlobalRouting`'s own docstring says routing gives "much
more accurate" RC estimates, but the step doesn't actually recompute setup/
hold metrics — it only writes routing metrics (wirelength, vias, antenna).
LibreLane's metrics dict is cumulative across steps, so
`timing__setup__ws__corner:...` keys visible in a later step's
`state_out.json` are often **stale, carried forward from an earlier
placement-based estimate**, not freshly computed post-route numbers. This
caused a very misleading reading early in this investigation (apparent
-62 ns WNS / 1500+ violations that turned out to be pre-route noise).

Similarly, `corner.tcl` (used by `OpenROAD.STAMidPNR`) only produces a full
human-readable path report for **one** corner per invocation (a `foreach
{corner_name corner_object} [lln::get_corner_dict] { ...; break }` early-exit
by design) — so `max.rpt`/`min.rpt` at any given `STAMidPNR` stage only shows
whichever corner happened to be first, usually `nom_tt`.

**Fix:** to get a trustworthy, fresh per-corner report at any point in the
flow, re-run `OpenROAD.STAMidPNR` standalone, seeded from a specific
completed stage's saved state, restricted to one corner:

```bash
librelane config.yaml --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --only OpenROAD.STAMidPNR \
    -i runs/<tag>/37-openroad-globalrouting/state_out.json \
    -c 'STA_CORNERS=max_ss_125C_3v00' \
    -c 'DEFAULT_CORNER=max_ss_125C_3v00' \
    --run-tag <tag>_worst_paths_ss --overwrite
```

(`-c KEY=VALUE` list-type overrides must be a bare value like
`max_ss_125C_3v00`, not JSON-array syntax `["max_ss_125C_3v00"]` — the
override parser doesn't JSON-decode nested brackets and will silently wrap
the literal bracketed string into a one-element list instead.)

This reruns cheaply (~15s) against the frozen ODB from whichever stage you
point `-i` at, and produces a real `report_checks`/`violator_list.rpt` for
just that corner.

## Post-GRT repair steps are disabled by default

`OpenROAD.RepairDesignPostGRT` and `OpenROAD.ResizerTimingPostGRT` are gated
off in LibreLane's Classic flow by default (`RUN_POST_GRT_DESIGN_REPAIR` /
`RUN_POST_GRT_RESIZER_TIMING`, both `default=False`) — LibreLane's own
docstring flags them "experimental and may result in hangs and/or extended
run times." Enable via `-c 'RUN_POST_GRT_DESIGN_REPAIR=true' -c
'RUN_POST_GRT_RESIZER_TIMING=true'`. Run in isolation (`--to
OpenROAD.ResizerTimingPostGRT`), they completed fine (~3 min, no hang) and
found only 14 real setup-violating endpoints (matching the "real" corner
check above, not the stale ~1500 figure), fixing them with a small buffer
swap. However, resizing/buffering invalidates existing global route guides
for many nets (`[WARNING EST-0026] Missing route to pin...`), so the metrics
written immediately after repair are themselves contaminated by now-invalid
routing until the design is actually re-routed. **The only fully trustworthy
number is post-detailed-routing, post-RCX (extracted, not estimated,
parasitics) signoff STA (`OpenROAD.STAPostPNR`).**

**First attempt, inconclusive:** a full-flow run with both repair steps
enabled (job `grouper-full-signoff`, tag `full_signoff_16m`) showed
`OpenROAD.DetailedRouting` sitting at a 0-byte log for 11.5+ hours right
after a `[GRT-0115] Global routing finished with congestion` warning, and was
force-cancelled (`hqdel --force`). At the time this looked like it confirmed
LibreLane's "may result in hangs" warning. However, the homelab-sge scheduler
was restarted during this window, which can orphan a running job's worker
process (silently killed, no further log output, `hqstat` still showing it
as RUNNING) — so that data point alone didn't reliably show the repair steps
cause a TritonRoute hang.

**Confirmed on a clean re-run:** re-submitted the identical job (`job 3450`,
`grouper-full-signoff-v2`) with no scheduler restart this time. Watched it
closely: CPU stayed pegged at 100% throughout (confirmed via `docker stats`/
`docker top` — the actual `openroad ... drt.tcl` process, not a zombie), and
memory grew slowly and steadily (1.6 GiB → 2.4 GiB over ~2.5 hours) — this is
*not* a dead/orphaned process, it is a live TritonRoute run that never
produces a single log line and never finishes. Force-cancelled at the 3-hour
mark (`hqdel --force 3450`) with the log still at 0 bytes. **This confirms
the design genuinely triggers LibreLane's documented "may result in hangs"
behavior for `RUN_POST_GRT_DESIGN_REPAIR`/`RUN_POST_GRT_RESIZER_TIMING` on
this DIE_AREA/density configuration** (1310×1150, 65% target density) —
likely because the repair/resize steps invalidate global-route guides
broadly (see `[EST-0026] Missing route to pin...` warnings after
`ResizerTimingPostGRT`), leaving TritonRoute to re-resolve a much larger
volume of congestion than a normal detailed-routing pass.

**Practical conclusion:** do not enable these two post-GRT repair flags for
a full run to signoff on this design at the current density/die-size. If
post-GRT repair is needed, either (a) run it in isolation to inspect/fix the
~14 real violating endpoints and then re-route by hand/with a longer budget
and active timeout, or (b) leave the flags off and rely on `OpenROAD.CTS`
and other pre-GRT-repair mechanisms, accepting the pre-repair setup
violations found by the standalone `STAMidPNR` check instead.

**Update: the hang is not about the repair flags at all.** Re-ran the full
flow again with `RUN_POST_GRT_DESIGN_REPAIR`/`RUN_POST_GRT_RESIZER_TIMING`
both *off* (job 3455, `full_signoff_16m_norepair`, 4 CPUs/8G RAM), still on
the 1310x1150/65%-density config, and `OpenROAD.DetailedRouting` stalled the
exact same way: 400% CPU (4 threads), memory climbing, log at 0 bytes for
the whole ~3h watch window, force-cancelled at the cutoff. **This proves the
DIE_AREA/density combination itself is what TritonRoute cannot resolve in
reasonable time — the post-GRT repair flags were a red herring.** See the
"Area reduction experiment" section below for the resolution (backed off to
a less aggressive shrink, which routed cleanly).

## Corner naming: what `min`/`nom`/`max` and `tt`/`ss`/`ff` mean

Corner names follow `{rc_corner}_{pvt_corner}`, two independent axes:

- `tt`/`ss`/`ff` (+ temp/voltage) selects the **liberty file** (cell delays):
  typical, slow-slow (worst-case cells), fast-fast (best-case cells).
- `min`/`nom`/`max` prefix selects the **RC extraction corner** (wire
  parasitics only) via `RCX_RULESETS`/`TECH_LEFS` glob patterns
  (`min_*`/`nom_*`/`max_*`) — independent of the liberty file chosen.

Signoff convention: **setup** wants the slowest possible path → slow cells +
slow wires → `max_ss`. **Hold** wants the fastest possible path → fast cells
+ fast wires → `min_ff`. (Caught and fixed a bug in the *adjacent*
`chipathon-2026-trouper` repo's `trouper_top.json`, which used `max_ff`
instead of `min_ff` for its hold corner — pairing fast cells with slow wires
doesn't represent the true fastest-path hold-stress scenario.)

## Findings so far, in order

1. **Trial synthesis** (`Yosys.Synthesis` only): clean, 10,736 std cells + 4
   SRAM macros, ~300k µm² synthesized area, no lint errors.
2. **Trial PnR through Global Routing**: confirms the `pdn-bugfix` merge
   fixed the prior `PDN-1017` failure (`Only one of -pad_offsets or
   -core_offsets can be specified`) — PDN generation, placement, CTS, and
   global routing all pass cleanly at `PDN_CORE_RING: false`.
3. **Clock frequency**: changed `CLOCK_PERIOD` from 50 ns (20 MHz) to
   62.5 ns (16 MHz) in both `config.yaml` and `src/rtl/picorv32_hello_top.sdc`
   (SDC reads `$::env(CLOCK_PERIOD)` directly, no other hardcoded references
   found anywhere in the repo).
4. **Real worst-case setup paths at `max_ss_125C_3v00`** (post-GRT, correctly
   computed, at 16 MHz): WNS -2.97 ns, TNS -33.7 ns, 33 violating paths — not
   the "-62 ns / 1500 paths" the stale in-flow metrics initially suggested.
   **30 of 33 violations trace back to a single structural bottleneck**: the
   `u_rst_sync/data_o` reset-synchronizer output, high-fanout into the
   register file (`cpuregs[...]`) through a `dlyb_1`/`buf_8` rebuffer chain.
   The other 3 are in the `pcpi_div` (divider) datapath. This is a targeted
   fix (reset fanout restructuring), not a broad timing failure.
5. **Post-GRT repair** (`RUN_POST_GRT_DESIGN_REPAIR`/`RUN_POST_GRT_RESIZER_TIMING`
   enabled): resizer found and attempted to fix all 14 setup-violating
   endpoints it could see with a small buffer swap; full confirmation needs
   a run to actual signoff STA (in progress — see below).
6. **Area reduction experiment** (in progress, config currently reflects this
   trial — see "Current config state" below):
   - Die: 1400×1400 → 4 SRAM macros (621,654 µm², fixed) + std cells
     (~462-466k µm² depending on run), std-cell utilization only 36.5%
     against a 45% density target — **because `FP_SIZING: absolute` means
     `PL_TARGET_DENSITY_PCT` alone does nothing to shrink the die**; it only
     guides placement inside the fixed box. Confirmed empirically: bumping
     45%→65% with `DIE_AREA` unchanged left utilization at 36.2%, unchanged.
   - Shrinking `DIE_AREA` to 1310×1150 (recentering the 4-macro row: new
     x-coords 22.4/343.7/665.0/986.3, keeping y=25) achieved the intended
     **23.1% area reduction** (1,960,000 → 1,506,500 µm²), std-cell
     utilization 36.5%→54.8%, legalized cleanly with zero PDN/routing
     violations.
   - But timing cost was larger than hoped: `nom_tt` setup stayed positive
     (+31.3 ns → +20.4 ns worst slack, still clean), **but `max_ss` setup
     WNS went from -2.97 ns to -20.2 ns (33→290 violating paths)** — driven
     by global route wirelength more than doubling (1.64M→3.57M) at the
     tighter density. This overshoots the "slightly negative" tolerance on
     `max_ss`. This density/die-size also turned out to be the config that
     hung in `OpenROAD.DetailedRouting` (see the "Post-GRT repair" section
     above) — never actually reached signoff STA at this cut.
   - **Backed off to a more conservative cut**: `DIE_AREA` 1310x1150 (65%
     density, 23.1% area reduction) → **1350x1250 (55% density, 13.9% area
     reduction)**, macros recentered (x = 42.4/363.7/685.0/1006.3, y=25
     unchanged). This routed cleanly end-to-end (job 3459, full signoff in
     ~23 min, no hang) and gave **real post-route, post-RCX signoff STA**:
     - `nom_tt_025C_3v30`: WNS/TNS = 0 / 0 (clean, worst slack +23.53 ns)
     - `min_ff_n40C_3v60`: WNS/TNS = 0 / 0 (clean, worst slack +40.45 ns)
     - `max_ss_125C_3v00`: **WNS -16.95 ns, TNS -2082.5 ns, 318 violating
       paths** — worse than the earlier *mid-flow estimate* for the more
       aggressive 23.1% cut (-20.2 ns/290 paths, itself only a GRT-based
       estimate, not real routed timing). Even a conservative 13.9% area
       reduction blows well past "slightly negative" once measured with real
       parasitics.
     - Die area achieved: 1,687,500 µm² (13.9% below the 1,960,000 µm²
       16MHz baseline). Everything else signed off clean: LVS pass, hold
       clean in all 3 corners, XOR clean. One real, separate, fixable issue:
       **16 Metal2 spacing DRC violations** (signal nets too close to
       VDD/VSS, `Checker.TrDRC`) caused the flow to hard-fail even though
       Magic DRC's 22 errors are tolerated (`ERROR_ON_MAGIC_DRC: False`) —
       `Checker.TrDRC` has no equivalent override in this config yet.
   - **Root cause of the max_ss violations, traced via `violator_list.rpt`**:
     318 violating paths collapse to only **8 unique startpoint registers**,
     three of which account for 85% of all violations:
     - `u_cpu.latched_store` → (through a 4-gate `aoi211/aoi211/oai211/aoi211`
       logic cone) → a downstream register: **159 paths (49%)**
     - `u_cpu.genblk2.pcpi_div.dividend[16]` → (through `aoi22`/`or4`) → a
       downstream register: **69 paths (21%)** — new at this density; wasn't
       a significant contributor in the original 1400x1400 baseline.
     - `u_rst_sync/data_o` (the reset-synchronizer output): **61 paths
       (19%)** — same structural bottleneck identified in the original
       16MHz baseline (finding #4 above), still present after the shrink.
     These auto-named nets look superficially like buffer *chains* because
     `SYNTH_AUTONAME` bakes each net's entire driver ancestry into its name,
     but the gates in the chain (`aoi211`, `oai211`, `aoi22`, `or4`) are real
     combinational logic, not inserted buffers — confirmed by locating the
     actual `dffq_1`/`dffrnq_1` cell instances in the post-route DEF and
     querying their `Q`-pin fanout directly via OpenROAD/ODB (jobs 3460/3461,
     `scripts/fanout_query.tcl`/`fanout_query2.tcl`). Immediate (1-hop)
     electrical fanout at each register's own `Q` pin:
     - `latched_store` startpoint reg: **direct fanout = 1** (drives a
       further buffer/logic tree; 26 sinks total once traced through pure
       buffer/delay-buffer cells)
     - `pcpi_div.dividend[16]` startpoint reg: **direct fanout = 2**
     - `u_rst_sync/data_o`: **direct fanout = 4** (556 sinks total once
       traced through pure buffer/delay-buffer cells — this one really is a
       wide clock/reset-style distribution tree)
     The 1-hop fanout is modest in all three cases — the 159/69/61 *violating
     path* counts come from the signal cascading through several further
     levels of real combinational logic (not simple buffers), each of which
     re-fans-out again, rather than from one single overloaded net. This
     means the fix is architectural (restructure/re-time the logic cone
     feeding off each of these registers, or duplicate the register to split
     the fanout earlier), not a matter of just upsizing one buffer.
   - **Practical implication**: this is not a diffuse "everything is a
     little slow" problem — three specific high-fanout registers are
     responsible for the overwhelming majority of the max_ss failures, and
     the reset-sync one is a repeat offender from the un-shrunk baseline.
     Targeted fixes (fanout restructuring / fanout-tree rebalancing on these
     three signals, or increasing their driving strength) would likely
     recover most of the max_ss budget without giving back the area
     reduction, rather than needing to shrink the die further.

## Session 2: the `dlyb` fanout-buffer bug, the Metal5 PDN restructure, and
## the search for a smaller viable die

Continuation of the area-reduction work above. Three major findings, in
order: (1) the `max_ss` violations at 1350x1250 were significantly worsened
by a resizer misconfiguration, not just real logic depth; (2) shrinking
further requires moving the PDN mesh off Metal3 onto Metal5, which is a
real ownership question, not just a routing knob; (3) that PDN move had a
real, non-obvious bug of its own, and even once fixed, the true routing
congestion at smaller die sizes is much worse than early (buggy)
measurements suggested.

### 1. `dlyb_*` cells were being used as generic fanout buffers

Traced the worst `max_ss` timing paths (finding #4 above) down to the
actual liberty timing data for the cells OpenROAD's resizer/design-repair
steps were inserting to fix `MAX_FANOUT_CONSTRAINT: 10` violations. They
were picking `gf180mcu_fd_sc_mcu7t5v0__dlyb_1/2/4` -- the library's
**delay buffer** cells, built to deliberately have high intrinsic delay
(~2.5-2.8 ns even at near-zero load, confirmed directly from the
`ss_125C_3v00` liberty file, vs a real `buf_1`) for hold-fixing use, not to
drive real loads. Nothing in `config.yaml`, `resolved.json`, or the PDK's
LibreLane overlay excluded them from the general buffer-insertion pool, so
the resizer was free to chain them together, burning several ns per stage
in the worst path.

**Fix:** exclude them via
`-c 'DONT_USE_CELLS=gf180mcu_fd_sc_mcu7t5v0__dlyb_1,gf180mcu_fd_sc_mcu7t5v0__dlyb_2,gf180mcu_fd_sc_mcu7t5v0__dlyb_4'`
(comma-separated bare list, no JSON brackets -- same CLI quirk as noted
above for single-value list overrides). This resolves internally to
`EXTRA_EXCLUDED_CELLS`, not a variable named `DONT_USE_CELLS` itself --
confirmed via `resolved.json`, and it is *not* a real LibreLane config key
(see the `PDN_M3_RUNG_PITCH` gotcha below for what happens if you try to
add an actually-unrecognized key to `config.yaml` instead of passing it via
`-c`).

At 1350x1250 (dlyb excluded, otherwise unchanged): `max_ss` WNS improved
from -16.95 ns / TNS -2082.5 / 318 paths to **-3.77 ns / TNS -123.8 / 108
paths**. `latched_store`'s contribution dropped from 159 violating paths to
~30; the next-largest offenders became `cpu_state[4]` (34 paths) and the
repeat-offender `u_rst_sync/data_o` (32 paths). Zero `dlyb_*` instances
confirmed in the resulting DEF. This is a permanent, low-risk win --
**should be kept regardless of what die size is ultimately chosen.**

### 2. Shrinking below 1350x1250 needs Metal5, which is a real question, not a free knob

Tried 1330x1200 (18.6% reduction) with the dlyb fix alone, still routing
signals/PDN only up to Metal4 (`RT_MAX_LAYER: Metal4`): congestion became
severe -- Metal3 99.5%, total usage 85.3%, overflow 37,627 (vs ~0 at
1350x1250). Letting *signal* routing opportunistically use Metal5
(`RT_MAX_LAYER: Metal5`, PDN untouched) cut overflow to 10,675 (72%
better) but Metal3 was still busy (77.9%) -- partial relief only, because
vias between non-adjacent layers still have to stack through every
intervening layer (Via1..Via4 are strictly adjacent-pair only: M1-M2,
M2-M3, M3-M4, M4-M5 -- there is no such thing as a direct M5-M3 via).

Real fix: move the **general PDN mesh's horizontal layer** off Metal3 onto
Metal5 (`PDN_HORIZONTAL_LAYER: Metal5`), freeing Metal3 from carrying a
full reserved corridor across the whole die. Direction-wise this is free --
the gf180mcuD tech LEF fixes each metal's preferred routing direction
(alternates every layer: M1 H, M2 V, M3 H, M4 V, M5 H), so Metal4
(vertical, unchanged) and Metal5 (horizontal) are already the natural
alternating pair.

**This is not just a routing knob.** `PDN_CORE_RING: false` /
`RT_MAX_LAYER: Metal4` had deliberately left Metal5 untouched because this
macro integrates hierarchically into a parent chip that owns Metal5 for
its own core ring. Filling Metal5 with our own dedicated, fixed-pitch power
mesh is a permanent geometric commitment the parent's integration would
need to be designed around -- **not yet cleared with whoever owns the
top-level integration.** Flagged in both `config.yaml` and `pdn_cfg.tcl`.

The SRAM macro's power pins are physically drawn on Metal3 in its own LEF
(fixed, cannot move) -- `pdn_cfg.tcl`'s `sram_grid` connect is hardcoded to
`Metal3` regardless of `PDN_HORIZONTAL_LAYER` now, decoupling the SRAM tap
from whatever layer the general mesh uses.

At 1330x1200 with the Metal5 PDN move: overflow dropped to 386 (from
37,627 Metal4-only / 10,675 Metal5-signals-only), usage 46.4% -- healthy,
and confirmed via `check_power_grid -net VDD`/`-net VSS`
(`PSM-0040 All shapes ... are connected`).

### 3. The Metal5 PDN move had a real connectivity bug, caught only by re-measuring at a different die size

Swept die sizes at the new Metal5-PDN config, following the same
proportional-shrink pattern as the original attempt:
- **1310x1150** (23.1% reduction, the exact size that hung TritonRoute in
  the original pre-fix investigation): legalized cleanly, **but
  `Checker.PowerGridViolations` reported 1524 real connectivity violations**
  (`PSM-0069 Check connectivity failed on VDD/VSS`). Root cause: the PDN
  script's Metal2-Metal4 "direct connect" was the *only* rail-to-grid
  bridge once the general Metal3 mesh was removed. Metal2 and Metal4 are
  both vertical-preferred (parallel, not crossing), so pdngen has no
  well-defined intersection to drop a real via at -- it produced degenerate
  0.01um-wide unconnected Metal3 slivers instead of real vias
  (`VDD/VSS-grid-errors.rpt` from `OpenROAD.GeneratePDN`). This was masked
  at 1330x1200 only because that die height happened to avoid the bug, not
  because the underlying connect was sound -- the original script had this
  same direct-connect line, but it was redundant with a full Metal3 mesh
  back then, so its unreliability never mattered.
- **1300x1130** and **1295x1115**: hit `DPL-0011`/`DPL-0010`/`DPL-0033` --
  standard cells illegally placed inside the SRAM macros' padding/blocked-
  layer zones, naming all 4 macro instances explicitly. Root cause: the
  4-macro row has a fixed footprint (1265.2um = 4x301.3 + 3x20 gaps) plus a
  mandatory 10um halo per side (`FP_MACRO_HORIZONTAL_HALO`/
  `FP_MACRO_VERTICAL_HALO`) -- at these widths the margin beyond that halo
  shrinks to ~17.4um / ~4.9um, too tight to legally seat a std-cell row
  segment. (Initially suspected this halo was purely a row-cutting
  convenience and could be shrunk to buy more margin -- turns out the
  linked bug, OpenROAD#8868, is actually about spurious DRC-violating vias
  from near-miss PDN/rail overlaps near macro boundaries, so shrinking the
  halo is a real DRC risk, not a free lever. Never tested reducing it.)

**Fix for the connectivity bug:** reintroduced a *sparse* Metal3 "rung"
stripe in `pdn_cfg.tcl` -- real perpendicular crossings with the Metal2/
Metal4 vertical stripes (which pdngen handles reliably, unlike the parallel
same-direction direct connect), at a much coarser pitch (300um, hardcoded)
than the original full-density mesh (130um). Replaced the fragile
`Metal2-Metal4` connect with `Metal2-Metal3(rung)` + `Metal3(rung)-Metal4`.

**Gotcha:** first attempt added this as a new `config.yaml` variable
(`PDN_M3_RUNG_PITCH`). LibreLane validates `config.yaml` keys against a
fixed schema and hard-rejects unrecognized ones *before running anything*
-- silently killed all 4 sweep jobs with `Unknown key 'PDN_M3_RUNG_PITCH'
provided`. Fix: hardcode the pitch as a local Tcl variable inside
`pdn_cfg.tcl` instead (`set pdn_rung_pitch 300`) -- it's an internal
implementation detail, not something a run needs to tune from
`config.yaml`, so it doesn't need to be a real config variable at all.

Re-verified with `check_power_grid` after the fix: **all four die sizes
(1330x1200, 1310x1150, 1300x1130, 1295x1115) now report fully connected
VDD/VSS**, including 1310x1150 (previously 1524 violations). The
legalization failures at 1300x1130/1295x1115 are unaffected by this fix --
confirmed as a separate, still-open problem (real geometric floor from the
fixed macro row, not a PDN issue).

### 4. Height sweep at fixed width 1310 -- confirms 1310x1150 is a real floor on both axes, not an arbitrary stopping point

Width is the tight constraint (tied to the fixed macro row + halo); height
is comparatively slack, since the macros only occupy the bottom ~551um of
whatever height is chosen. Tested holding width at 1310 (the widest size
confirmed to legalize cleanly) and shrinking height below the known-good
1150:
- **1310x1100** (71% density): legalizes, but congestion goes
  catastrophic -- **112.4% total usage (demand exceeds resource), 145,774
  overflow, Metal3 at 160.3%.** Worse than anything else tested. Wirelength
  nearly tripled vs 1330x1200 (5.99M vs 2.96M um).
- **1310x1050** (78%) and **1310x1000** (86%): both hit `DPL-0036`
  (detailed placement failed outright) -- density too aggressive to
  legalize at all.

**Conclusion: 1310x1150 is the practical floor on both width and height** --
a sharp cliff immediately past it in either dimension, not an intermediate
stepping stone to something smaller. Coincidentally the exact size that
hung in the original pre-fix investigation, but confirmed here to be a
*different* root cause this time (see next section).

### 5. The "17,963 overflow" figure for 1310x1150 was measured on the broken mesh -- the honest number is much worse, and needed its own fix

Before running detailed routing, re-measured 1310x1150's `GlobalRouting`
congestion for the first time with the *fixed* (fully-connected) PDN mesh
-- all earlier checks at this size had only verified connectivity via
`GeneratePDN`-only runs, never re-run the full congestion report post-fix.
Result: **98.4% total usage, 79,819 overflow, Metal3 at 123.9% (over
capacity)** -- dramatically worse than the original 17,963-overflow figure
measured on the *broken* mesh. Explanation: the earlier number was
artificially optimistic because many of the mesh's intended via
connections were simply missing (degenerate unconnected slivers, section 3
above) -- dead copper doesn't consume real routing resource. An honestly
wired-up design needs meaningfully more.

Submitted a real `OpenROAD.DetailedRouting` run at this (uncorrected-for-
congestion) config anyway, to see what would happen. After 45+ minutes
with the DRT log still at 0 bytes, checked the container directly
(`docker stats`): **CPU 322%, 2.45GiB memory and climbing** -- a live,
actively-computing TritonRoute process, not a stalled/orphaned one. This
is the exact signature documented in the original hang investigation
(section "Post-GRT repair steps" above) that took 3+ hours to conclusively
confirm as a hang. Given the now-known 98.4%/over-capacity congestion at
this exact config, cancelled it (`hqdel 3533`) rather than wait out a
likely repeat, in favor of fixing the congestion first.

### 6. Congestion-mitigation sweep at 1310x1150 (dlyb + Metal5-PDN fixes, corrected-mesh baseline: 79,819 overflow / 98.4% usage)

Five levers tested in parallel, each as a `-c` override on top of
`config_sweep_1310x1150.yaml`:

| Test | Change | Overflow | Usage | Reduction |
|---|---|---|---|---|
| A | `GRT_ADJUSTMENT` 0.3->0.2 | -- | -- | failed at `DPL-0036` legalization (likely unrelated edge case -- this variable only affects routing, not placement; could not isolate its solo congestion effect) |
| B | `MAX_FANOUT_CONSTRAINT` 10->16 | 41,729 | 76.1% | ~48% |
| C | PDN mesh pitch 130->180um (`PDN_VPITCH`/`PDN_HPITCH`, spacing recomputed to 85) | 58,433 | 91.9% | ~27% (weakest individual lever) |
| D | A + B + C combined | **3,495** | **49.5%** | **~96%** |
| E | Narrower Metal3 rung width, 5um->2um (`pdn_cfg_narrowrung.tcl` variant) | 35,122 | 74.5% | ~56% |
| F | A + B combined, no C | 15,385 | 73.7% | ~81% |

Strong synergy, not additive: no individual lever gets close to D's result
alone, and D clearly beats F -- **C (the PDN pitch change) is pulling real
weight in the combination**, despite being the weakest lever on its own.

**Open question: C has a real IR-drop cost that has not been checked.**
Widening the PDN strap pitch generically increases IR drop (less
redundant current-carrying metal, longer resistive paths from cells to the
nearest strap) -- unlike A/B/E, which are purely netlist/routing
bookkeeping with no electrical tradeoff. `OpenROAD.IRDropReport` is enabled
in the Classic flow (not skipped) but runs late, after detailed routing --
none of the congestion-only `--to GlobalRouting` runs above have reached
it. **Before accepting D as final, need an actual IR drop check** (or
accept F's smaller-but-still-large 81% reduction and skip the PDN pitch
change entirely, avoiding the question).

### 7. Confirmed: `OpenROAD.DetailedRouting` actually succeeds on config D at 1310x1150

Ran D (dlyb fix + Metal5 PDN mesh/sparse rungs + `GRT_ADJUSTMENT=0.2` +
`MAX_FANOUT_CONSTRAINT=16` + PDN pitch 180) all the way through
`OpenROAD.IRDropReport` (job `irdrop_check_d`, `--to OpenROAD.IRDropReport`).
**TritonRoute fully completed** -- wrote the routed DEF/netlist/layout,
0 antenna violations, and the flow continued through RCX and post-route STA
without incident. This is the first config since the original pre-fix
1400x1400 baseline to actually finish detailed routing rather than hang or
get force-cancelled.

**IR drop check resolves the open question from section 6:** the PDN pitch
loosening (130um -> 180um) has a negligible electrical cost --
worst-case IR drop 3.45e-4 V (0.01%) on VDD, 7.17e-4 V (0.02%) on VSS,
against a 3.3V supply. Nowhere near a real concern (typical budgets are
5-10%). **The PDN pitch change in D is cleared -- no need to fall back to
F to avoid it.**

**Gotcha along the way, worth remembering:** `hqsub`'s default `--cpus 4`
badly throttles `OpenROAD.DetailedRouting` -- TritonRoute always spawns 24
threads regardless of allocation (`Running TritonRoute with 24 threads` in
its log), so a 4-core job runs at a 24:4 thread-to-core ratio. Confirmed
directly via the container's cgroup (`cpu.stat`: `nr_throttled` at ~27% of
periods). **Do not try to fix this by live-updating a running container's
`--cpus`/`cpuset-cpus`** (`docker update`) -- tried it once on a stuck run
and it visibly destabilized the already-running thread pool (CPU dropped
from an oscillating 200-400% to a dead-flat single-core 100% with memory
totally frozen across multiple checks, consistent with a TBB-style pool's
internal state getting confused by a live affinity change after startup).
Cancel and resubmit with the correct `--cpus` from the start instead --
the successful run here used `--cpus 22` set at submission time, pinned to
`--node proxmox-agent` specifically to leave `gaming-pc` (this repo's
usual scheduling target, also the user's own machine) free for other
work.

**Live CPU observation (2026-07-23):** the congested 1310x1100 detailed-
routing trial (job 3547, container `hlab-sge-job-3547`) was checked directly
on `proxmox-agent`, rather than inferred from its silent NFS log. Its
`openroad ... drt.tcl` process had sustained **1070--1114% CPU** after more
than two hours in detailed routing -- approximately **11 CPU cores** of real
compute. Thus a long, log-silent TritonRoute phase can still consume a
significant share of the CPU capacity assigned to it; use live process or
container CPU measurements before classifying it as stuck. This is not,
however, evidence that it consumes *all* assigned cores continuously.

**One small, real, localized defect found: a Metal2 short.** `Checker.TrDRC`
reported "4 Routing DRC errors" (`Checker.TrDRC` step), but the 4 entries
collapse to 2 distinct violation sites, both the same short between one
specific auto-named net (`u_cpu.alu_out_q[0]...`) and `VDD` on Metal2, at
~(385, 754) -- a single localized routing defect, not a systemic
congestion/PDN problem.

### 8. Short investigation: root cause found, attempted fix hit an unrelated tool bug, left as a known open item

Traced the exact geometry by grepping the routed DEF directly (more
reliable than guessing at OpenROAD/ODB Tcl query syntax blind, with no way
to iterate quickly against a real interactive session). Found the VDD
Metal2 intermediate PDN stripe centered at x=384.28um in that column, and
the offending net's routing:
```
NEW Metal2 ( 770000 1508080 ) ( 774480 * )   -- DBU, 2000/um
```
i.e. a horizontal Metal2 jog from x=385.0um to x=387.24um at y=754.04um --
landing almost exactly inside the VDD stripe's own column. **A single
net's ripup-reroute left one bad jog behind, not a systemic PDN-clearance
problem** -- confirmed further by the fact that `PDN_VSPACING` was already
widened to 85um (from 60) as part of the D recipe's pitch change, so the
stripe already has generous clearance; DRC minimum spacing on Metal2 is
only 0.28um, far smaller than what's available here. This really is just
one net that didn't converge cleanly.

**Attempted fix: `-c 'DRT_OPT_ITERS=128'`** (up from the default 64),
re-run from the saved `GlobalRouting` state to skip redoing placement/CTS
(`-i runs/irdrop_check_d/37-openroad-globalrouting/state_out.json`, job
`fix_short_d`). **This crashed, not because more iterations are wrong, but
because of an unrelated bug in LibreLane's `drt.tcl` wrapper**: passing
`-droute_end_iter 128` to `detailed_route` triggers a broken warning-message
call somewhere past that threshold --
```
+ detailed_route -droute_end_iter 128 -or_seed 42 ...
Error: drt.tcl, 92 Wrong number of arguments :utl::warn tool id msg  argument 2
```
-- a hard crash (`utl::warn` called with the wrong arg count) rather than a
DRC-related failure. **Do not set `DRT_OPT_ITERS` above the default (64)
without first confirming what threshold triggers this** -- untested
whether e.g. 80 or 96 avoids it; 128 does not.

**Decision: left as a known open item rather than chasing it further.**
The design otherwise routes cleanly with negligible IR drop (section 7) --
one localized short on one net is the kind of residual defect normally
closed out with a manual/targeted reroute (an ECO) in a real signoff flow,
not something to keep burning speculative full-detailed-routing job cycles
on. **Next attempt, if resumed:** either retry the identical original
recipe unmodified (accept whatever a second independent TritonRoute run
converges to, given some run-to-run nondeterminism from thread scheduling)
or investigate a real Tcl-based ECO to reroute just that one net's bad
segment, rather than another blind global config-variable adjustment.

### Current state (uncommitted, mid-experiment) as of this note

- `librelane/classic/config.yaml`: **baseline is now the proven 1310x1150
  recipe**: `CLOCK_PERIOD: 62.5` (16 MHz), 68% target density,
  `MAX_FANOUT_CONSTRAINT: 16`, `GRT_ADJUSTMENT: 0.2`, dlyb_1/2/4 excluded,
  180um PDN pitch with 85um spacing, `RT_MAX_LAYER: Metal5`, and
  `PDN_HORIZONTAL_LAYER: Metal5` with sparse Metal3 rungs. This is the
  exact configuration exercised by `irdrop_check_d`: detailed routing,
  RCX, post-route STA, and IR-drop analysis completed.
- `librelane/classic/config_sweep_{1310x1150,1300x1130,1295x1115,
  1310x1100,1310x1050,1310x1000}.yaml`: untracked sweep variants used to
  find the die-size floor. They remain as historical experiment inputs;
  `config.yaml` is the reproducible baseline.
- `librelane/classic/pdn_cfg.tcl`: the sparse-Metal3-rung version is the
  accepted fix (resolves the real connectivity bug). `pdn_cfg_narrowrung.tcl`
  is an experimental variant (test E), not part of the baseline.
- Baseline evidence: global-routing utilization was 31.55% with zero
  overflow; worst IR drop was 0.01% on VDD and 0.02% on VSS. Post-route
  `max_ss` setup timing remains the principal open issue (WNS -37.30ns,
  TNS -7764.08ns); hold is clean in all corners.
- Still open: Metal5 ownership must be coordinated with the parent
  integration, and the four residual detailed-routing DRC errors need a
  targeted fix.

`src/rtl/picorv32_hello_top.sdc` clock-period comment updated to match
(16 MHz / 62.5 ns) -- from the original session, still valid.
