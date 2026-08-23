---
name: run-pnr
description: Submit a LibreLane synthesis or full P&R run for the GrouperSoC chip core to the homelab-sge scheduler, poll it to completion, and summarize the outcome. Use when the user asks to "run synth", "run P&R", "do PnR", "check timing on my RTL changes", or similar for grouper_soc_chip_core.
---

# run-pnr

Runs LibreLane (synth-only or full flow) on homelab-sge for `grouper_soc_chip_core`, then
polls to completion and summarizes. This ties three skills together:

- **pnr-run** — the LibreLane invocation, the working landscape 1650×1100 config, and the PD
  knobs/gotchas.
- **sge-job** — NFS sync, container paths, the read-only `/foss/designs` constraint, PDK
  selection. **Follow it for the job-script skeleton** rather than re-deriving one here.
- **pnr-results** — reading WNS / DRC / LVS / area out of the finished run.

Ask the user (via `AskUserQuestion` if ambiguous) which they want:

- **Synth-only** (`--to Yosys.Synthesis`) — ~25 s, checks elaboration / latches / cell count,
  no timing/DRC/LVS signal.
- **Global-route checkpoint** (`--to OpenROAD.GlobalRouting`) — ~2–5 min, floorplan + PDN +
  placement + CTS + GRT and a global-route wirelength, but timing is estimated (see the
  mid-flow gotcha in pnr-run).
- **Full P&R to signoff** — placement, CTS, route, `OpenROAD.STAPostPNR`, Magic DRC, LVS.
  ~7–9 min on 20 cores for a healthy run.

**There is one config: `librelane/classic/config.yaml`.** The floorplan lives inside it
(`DIE_AREA: [0.0, 0.0, 1650, 1100]`, the landscape 1650×1100), not in a separate file per
shape. Older notes name `config_1650x1100_keepdlyc_fanout32.yaml` and
`config_1330x1370_keepdlyc_fanout32.yaml` — **neither exists**; the portrait floorplan is
history recorded in that file's comments and in `TRIAL_NOTES.md`. `dry_run_config.yaml` is a
separate PnR-only variant (see CLAUDE.md) and is not what a normal run uses.

## Steps

1. **Sync the repo to NFS** (see sge-job — that skill owns these paths). Initialize
   `ip/gf180mcu_ocd_ip_sram` first, never `--delete`:

   ```bash
   export HLAB_SGE_URL=http://nas.home:4783
   LOCAL=/home/james/projects/grouper
   NFS=/srv/eda/designs/james/grouper-sim/grouper
   rsync -a --exclude='.git/' --exclude='librelane/classic/runs/' --exclude='.env/' \
         "$LOCAL/" "$NFS/"
   ```

   Then `diff` whatever you just changed against the NFS copy before submitting — `hqsub`
   snapshots at submit time, so a missed sync silently runs the old tree.

2. **Write the job script to NFS** (`hqsub` needs it at a daemon-readable path). Two things
   are non-negotiable and both come from sge-job:

   - **`/foss/designs` is read-only.** Copy the staged tree into `/foss/runs/...` and run
     from there, or LibreLane dies with `OSError: [Errno 30] Read-only file system`.
   - **The ROM image must be built inside the job.** `config.yaml` sets `ROM_INIT_CONST`, so
     `rom_ss.sv` includes `sw/boot/code.vmem`, which is gitignored and absent from a fresh
     tree. Synthesis fails on the missing include.

   ```bash
   cat > "$NFS/librelane/classic/pnr_<tag>.sh" << 'EOF'
   #!/bin/bash
   set -uo pipefail
   export PDK_ROOT=/foss/pdks PDK=gf180mcuD STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

   SRC=/foss/designs/grouper-sim/grouper
   REPO=/foss/runs/pnr-${JOB_ID:-manual}/grouper
   TAG=<tag>

   rm -rf "$(dirname "$REPO")"; mkdir -p "$REPO" || exit 1
   cp -a "$SRC/." "$REPO/" || exit 1
   cd "$REPO" || exit 1

   ./sw/scripts/build_bootloader.sh --no-disasm
   [ -s sw/boot/code.vmem ] || { echo "FATAL: ROM image build failed"; exit 1; }

   cd "$REPO/librelane/classic" || exit 1
   librelane config.yaml \
       --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
       [--to Yosys.Synthesis] \
       --run-tag "$TAG" --overwrite
   rc=$?
   echo "===== librelane exit code: $rc ====="
   exit $rc
   EOF
   ```

   Do **not** `set -e` the whole script: you want the flow's exit code and the post-run
   summary, not an abort on the first non-zero step.

   Add a **guard that asserts the fix under test is actually in the copied tree** and exits
   non-zero if not. A stale snapshot otherwise reads as "the fix didn't work."

   There is **no `--image` flag** on `hqsub` — the scheduler picks the container image.

3. **Submit:**

   ```bash
   hqsub --name grouper-pnr-<tag> \
       --cpus <2 synth-only | 20 full P&R> --mem <4G synth-only | 12G full P&R> \
       "$NFS/librelane/classic/pnr_<tag>.sh"
   ```

   `--cpus 20` prints `Warning: --cpus 20.0 exceeds schedulable CPUs 6.0`. **That warning is
   about the master node only** — the job still schedules onto the 22-core `proxmox` node.
   Check `hqhost` before assuming it is unschedulable; don't resubmit smaller on the warning
   alone.

4. **Poll to a terminal state without spamming updates.** Use the Monitor tool or a
   background `Bash` poll loop with an interval matched to expected duration (30 s synth-only,
   **180 s+** for full P&R). Terminal states: `DONE` / `FAILED` / `CANCELLED`.

   ```bash
   export HLAB_SGE_URL=http://nas.home:4783
   while true; do
     state=$(hqstat --json | python3 -c "
   import json,sys
   for j in json.load(sys.stdin):
       if j.get('id')==<JOB_ID>: print(j.get('state')); break
   ")
     case "$state" in DONE|FAILED|CANCELLED) echo "terminal: $state"; break;; esac
     sleep 180
   done
   ```

   **Runtime is a diagnostic.** A healthy full flow is 7–9 min. Over ~15 min means broken,
   not busy — check the DRT trend (`grep -hoE "Number of violations = [0-9]+"
   runs/<tag>/*detailedrouting/*.log`) rather than waiting. And a **scheduler restart can
   orphan a job**: log goes silent, `hqstat` still says `RUNNING`. Confirm the process is
   actually alive (CPU/RAM still moving) before assuming the *workload* hung.

5. **On completion, summarize with the pnr-results skill** — exit code + cell/area for
   synth-only; WNS per corner + route DRC + Magic DRC + LVS for full P&R. Read the job's
   stderr with `hqlog <ID> --stream err` (or the LibreLane per-step logs under
   `runs/<tag>/<stage>/`) if the exit code is non-zero.

## Expected/known outcomes

- **Good numbers for the landscape config.** The reference clean run is **job 4851**
  (`m2_noextend`): exit **0** in 7 m 11 s, empty `error.log`, and every signoff check zero --
  route DRC 0 (converged at DRT iteration 4), Magic DRC 0, KLayout DRC 0, XOR 0,
  `design__power_grid_violation__count` 0 on both nets, and `design__lvs_error__count` 0
  with netgen reporting "Circuits match uniquely". Timing from
  `53-openroad-stapostpnr/summary.rpt`: setup worst slack **+19.0 ns** (nom_tt) / +32.8 ns
  (min_ff), hold worst slack **+0.37 ns** (min_ff) / +0.87 ns (nom_tt), setup and hold
  violation counts 0. 22 antenna violations remain and are not gated.

- **Read slack out of `summary.rpt`, not `metrics.json`.** `timing__setup__wns` and
  `timing__hold__wns` are clamped at 0 when timing is met, so metrics.json shows `0` on a
  design with +17.8 ns of margin. A `0` there means "no violation", not "zero slack".

- **`design__max_slew_violation__count` is ~3600 and `max_cap` ~211 on a passing run.** These
  are reported but not gated, so they do not stop the flow. Don't read them as a failure —
  and don't read them as fine, either; they are an open item, not a clean result.

- **`STA_CORNERS` runs two corners, not three.** `max_ss_125C_3v00` is commented out in
  `config.yaml` even though the lib is listed and CLAUDE.md describes a three-corner signoff.
  The slow corner is the one that catches setup, so a passing setup number here is weaker
  evidence than it looks. Say so when reporting timing.

- **A non-zero exit code is a real failure — check what deferred before excusing it.** The
  flow *does* reach exit 0 (job 4851), so a 2 is not the normal healthy outcome. Read
  `runs/<tag>/error.log`; it names the deferred checker. Historically this note claimed
  "the flow exits 2 on a clean physical result because of the deferred LVS (unwired `io_ss`
  bidir slots — RTL, not PD)". **That was wrong**, and it buried a genuine layout defect for
  several runs. Job 4850's 7 LVS errors were three top-level output pins physically shorted
  to VDD (`gpio_15_bidir_ie`, `gpio_10_bidir_cs`, `gpio_6_bidir_cs`), because the Metal2 PDN
  straps were extended to the die boundary and swept through the I/O band where the N/S
  Metal2 pins sit. Fixed in `librelane/classic/pdn_cfg.tcl` by withholding
  `-extend_to_boundary` from the Metal2 straps; the long comment there has the geometry.

  The general lesson: **route DRC 0 does not imply no shorts.** A DEF pin is a fixed
  terminal, so DRT routes around an overlapping power strap and reports clean; Magic
  extraction is the first step that sees the overlap. LVS is the only check that catches it,
  so never wave it through.

- **`DRT_SAVE_DRC_REPORT_ITERS=1`** (via `-c`) writes a DRC report every iteration, so you can
  read route violations out of a run that is still grinding — read one, then `hqdel` it.
  Run it as a *separate* job seeded from the first run's global-route state (`--only
  OpenROAD.DetailedRouting -i runs/<first>/*-globalrouting/state_out.json -c 'DRT_THREADS=N'`,
  distinct `--run-tag`) rather than cancelling the original.
