---
name: run-pnr
description: Submit a LibreLane synthesis or full P&R run for the GrouperSoC chip core to the homelab-sge scheduler, poll it to completion, and summarize the outcome. Use when the user asks to "run synth", "run P&R", "do PnR", "check timing on my RTL changes", or similar for grouper_soc_chip_core.
---

# run-pnr

Runs LibreLane (synth-only or full flow) on homelab-sge for `grouper_soc_chip_core`, then
polls to completion and summarizes. This ties three skills together:

- **pnr-run** — the LibreLane invocation, the working landscape 1650×1100 config, and the PD
  knobs/gotchas.
- **sge-job** — NFS sync, container paths, PDK selection.
- **pnr-results** — reading WNS / DRC / LVS / area out of the finished run.

Ask the user (via `AskUserQuestion` if ambiguous) which they want:

- **Synth-only** (`--to Yosys.Synthesis`) — ~15 s, checks elaboration / latches / cell count,
  no timing/DRC/LVS signal.
- **Global-route checkpoint** (`--to OpenROAD.GlobalRouting`) — ~2–5 min, floorplan + PDN +
  placement + CTS + GRT and a global-route wirelength, but timing is estimated (see the
  mid-flow gotcha in pnr-run).
- **Full P&R to signoff** — placement, CTS, route, `OpenROAD.STAPostPNR`, Magic DRC, LVS.
  ~8–9 min on 20 cores for a healthy run.

Confirm the config with the user if they don't name one — default to the landscape
**`config_1650x1100_keepdlyc_fanout32.yaml`** (the working copy), but note a portrait
`config_1330x1370_keepdlyc_fanout32.yaml` also exists.

## Steps

1. **Sync the repo to NFS** (see sge-job). Initialize `ip/gf180mcu_ocd_ip_sram` first, never
   `--delete`:

   ```bash
   export HLAB_SGE_URL=http://nas.home:4783
   LOCAL=/home/james/projects/grouper
   NFS=/srv/eda/designs/timothyjabez/chipathon-2026-grouper
   rsync -a --exclude='.git' --exclude='librelane/classic/runs' "$LOCAL/" "$NFS/"
   ```

2. **Write the job script to NFS** (`hqsub` needs it at a daemon-readable path):

   ```bash
   cat > "$NFS/librelane/classic/pnr_<tag>.sh" << 'EOF'
   #!/bin/bash
   set -euo pipefail
   export PDK_ROOT=/foss/pdks PDK=gf180mcuD STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
   cd /foss/designs/chipathon-2026-grouper/librelane/classic
   /foss/tools/bin/librelane config_1650x1100_keepdlyc_fanout32.yaml \
       --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
       [--to Yosys.Synthesis] \
       --run-tag <tag> --overwrite
   EOF
   ```

   There is **no `--image` flag** on `hqsub` — the scheduler picks the container image.

3. **Submit:**

   ```bash
   hqsub --name grouper-pnr-<tag> \
       --cpus <2 synth-only | 20 full P&R> --mem <4G synth-only | 12G full P&R> \
       "$NFS/librelane/classic/pnr_<tag>.sh"
   ```

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

   **Runtime is a diagnostic.** A healthy full flow is 8–9 min. Over ~15 min means broken,
   not busy — check the DRT trend (`grep -hoE "Number of violations = [0-9]+"
   runs/<tag>/*detailedrouting/*.log`) rather than waiting. And a **scheduler restart can
   orphan a job**: log goes silent, `hqstat` still says `RUNNING`. Confirm the process is
   actually alive (CPU/RAM still moving) before assuming the *workload* hung.

5. **On completion, summarize with the pnr-results skill** — exit code + cell/area for
   synth-only; WNS per corner + route DRC + Magic DRC + LVS for full P&R. Read the job's
   stderr with `hqlog <ID> --stream err` (or the LibreLane per-step logs under
   `runs/<tag>/<stage>/`) if the exit code is non-zero.

## Expected/known outcomes

- **The flow exits 2 on a clean physical result** because of the deferred LVS (unwired
  `io_ss` bidir slots — RTL, not PD). Don't report that as a PnR failure. Landscape config:
  route DRC 0, Magic DRC 0, setup WNS ≈ +12 ns, hold WNS ≈ +0.3 ns are the good numbers.
- **`DRT_SAVE_DRC_REPORT_ITERS=1`** (via `-c`) writes a DRC report every iteration, so you can
  read route violations out of a run that is still grinding — read one, then `hqdel` it.
  Run it as a *separate* job seeded from the first run's global-route state (`--only
  OpenROAD.DetailedRouting -i runs/<first>/*-globalrouting/state_out.json -c 'DRT_THREADS=N'`,
  distinct `--run-tag`) rather than cancelling the original.
