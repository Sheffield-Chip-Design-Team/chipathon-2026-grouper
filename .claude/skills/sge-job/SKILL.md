---
name: sge-job
description: GrouperSoC-specific homelab-sge usage — the NFS designs layout, how the repo maps into the container, PDK selection inside the image, and where LibreLane run outputs land. For general hqsub/hqstat/hqdel/hqhost/hqwait/hqlogin mechanics, use the hlab-sge skill first; this skill only covers what's specific to this repo. Triggers on "submit a job", "check job <ID>", "hqsub", "hqstat", "SGE", "job scheduler", "PDK on SGE", "sync to NFS".
---

# homelab-sge — GrouperSoC-specific usage

For the general `hq*` CLI (submit, poll, log, wait, cancel, interactive sessions,
auth token setup), use the **hlab-sge** skill — this skill only covers what's specific to
GrouperSoC: how the repo is staged onto NFS, how it maps into the container, PDK selection,
and where LibreLane writes its run outputs.

```bash
export HLAB_SGE_URL=http://nas.home:4783
```

## The repo lives on NFS — sync before every job

Jobs read the repo from NFS at:

```
host:      /srv/eda/designs/timothyjabez/chipathon-2026-grouper
container: /foss/designs/chipathon-2026-grouper
```

NFS is **not** a git checkout and does not track your local working tree. Sync your working
copy across before each submit:

```bash
LOCAL=/home/james/projects/grouper
NFS=/srv/eda/designs/timothyjabez/chipathon-2026-grouper
rsync -a --exclude='.git' --exclude='librelane/classic/runs' "$LOCAL/" "$NFS/"
```

- **Never `rsync --delete`.** Run artifacts under `librelane/classic/runs/` live on NFS
  only (they're gitignored and not in your local tree), and `--delete` wipes them.
- **Initialize the SRAM submodule first.** `ip/gf180mcu_ocd_ip_sram` (the macro
  `lib`/`lef`/`gds`) is a real dependency of the hardened RAM flow and is absent until
  checked out: `git submodule update --init --recursive` before the first sync.
- Sanity-check the file that matters actually made it across before trusting a run, e.g.
  `diff "$LOCAL/librelane/classic/config_1650x1100_keepdlyc_fanout32.yaml" \
        "$NFS/librelane/classic/config_1650x1100_keepdlyc_fanout32.yaml"`.

Write job scripts to NFS too (not just locally) — `hqsub`'s positional script argument must
resolve to a path the daemon can read.

## PDK selection inside the container

Don't rely on an inherited `PDK` env var — set it explicitly at the top of every job script
for GF180 work:

```bash
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
```

`librelane` inside the container is at `/foss/tools/bin/librelane`. GrouperSoC hardens with
the foundry 5V standard cells `gf180mcu_fd_sc_mcu7t5v0` at 3.3 V core — always pass
`--pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0` explicitly (see the pnr-run / run-pnr
skills for the full invocation).

For Magic-based flows (DRC/extraction), pass the rcfile explicitly rather than relying on
the ambient environment:

```bash
RCFILE="$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc"
magic -dnull -noconsole -rcfile "$RCFILE" ...
```

## Where LibreLane run outputs land

Run the LibreLane classic flow from the config's own directory, so outputs land under
`librelane/classic/runs/<run-tag>/`:

```
container:  /foss/designs/chipathon-2026-grouper/librelane/classic/runs/<tag>/
host:       /srv/eda/designs/timothyjabez/chipathon-2026-grouper/librelane/classic/runs/<tag>/
```

Each `<tag>/` is a set of numbered stage subdirectories (`06-yosys-synthesis`,
`37-openroad-globalrouting`, `53-openroad-stapostpnr`, `*-openroad-detailedrouting`,
`*-checker-magicdrc`, …); stage numbers shift with which steps the config gates on/off.
`librelane/classic/runs/` is gitignored — the run directories exist on NFS only. Use
`--run-tag <tag> --overwrite` to name a run deterministically instead of the default
timestamp tag. See **pnr-results** for the read commands.

## Job stdout / stderr

The scheduler captures each job's streams; retrieve them with `hqlog <id> [--stream err]`
(see the hlab-sge skill). LibreLane also writes its own per-step logs inside each
`runs/<tag>/<stage>/` directory — those are usually the more useful ones for a PnR failure.

## Environment inside the container

| Variable | Value |
|----------|-------|
| `JOB_ID` | Numeric job ID |
| `JOB_NAME` | Job name passed to `hqsub` |
| `PDK_ROOT` | `/foss/pdks` (set it yourself; don't assume it's inherited) |

## Complete example — a synth-only sanity job

```bash
export HLAB_SGE_URL=http://nas.home:4783
LOCAL=/home/james/projects/grouper
NFS=/srv/eda/designs/timothyjabez/chipathon-2026-grouper

# 1. Sync the working tree (never --delete; submodule initialized first)
rsync -a --exclude='.git' --exclude='librelane/classic/runs' "$LOCAL/" "$NFS/"

# 2. Write the job script to NFS
cat > "$NFS/librelane/classic/synth_check.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
export PDK_ROOT=/foss/pdks PDK=gf180mcuD STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
cd /foss/designs/chipathon-2026-grouper/librelane/classic
/foss/tools/bin/librelane config_1650x1100_keepdlyc_fanout32.yaml \
    --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --to Yosys.Synthesis --run-tag synth_check --overwrite
EOF

# 3. Submit and wait
JOB_ID=$(hqsub --name grouper-synth-check --cpus 2 --mem 4G \
    "$NFS/librelane/classic/synth_check.sh" | grep -oP '\d+')
hqwait "$JOB_ID"

# 4. Read results with the pnr-results skill
```
