---
name: sge-job
description: GrouperSoC-specific homelab-sge usage — the NFS designs layout, how the repo is snapshotted into the container, the read-only /foss/designs constraint, PDK selection inside the image, and where LibreLane run outputs land. For general hqsub/hqstat/hqdel/hqhost/hqwait/hqlogin mechanics, use the hlab-sge skill first; this skill only covers what's specific to this repo. Triggers on "submit a job", "check job <ID>", "hqsub", "hqstat", "SGE", "job scheduler", "PDK on SGE", "sync to NFS".
---

# homelab-sge — GrouperSoC-specific usage

For the general `hq*` CLI (submit, poll, log, wait, cancel, interactive sessions,
auth token setup), use the **hlab-sge** skill — this skill only covers what's specific to
GrouperSoC: how the repo is staged onto NFS, how it maps into the container, why
`/foss/designs` being read-only changes every LibreLane invocation, PDK selection, and
where run outputs land.

```bash
export HLAB_SGE_URL=http://nas.home:4783
```

## Paths — the SGE owner here is `james`

| Purpose | Host path (NFS) | Container path |
|---------|-----------------|----------------|
| Staged repo | `/srv/eda/designs/james/grouper-sim/grouper/` | `/foss/designs/grouper-sim/grouper/` |
| Job stdout | `/srv/eda/logs/james/job-<ID>.o` | — |
| Job stderr | `/srv/eda/logs/james/job-<ID>.e` | — |
| Submitted script copy | `/srv/eda/logs/james/job-<ID>.sh` | — |
| Writable job output | `/srv/eda/runs/james/<project>/<ID>/` | `/foss/runs/` |

> **Older docs and scripts point at `/srv/eda/designs/timothyjabez/chipathon-2026-grouper`.
> That is a different user's tree and is mode 0770 — `james` gets `Permission denied` on it.**
> Anything still naming `timothyjabez` is stale; use the `james` paths above.

The `job-<ID>.sh` copies are the best record of how a past job was actually set up —
`hqsub` doesn't record its own flags anywhere you can read back, so reconstruct intent from
the script plus `hqstat --json`.

`/srv/eda/shared` (mounted read-only at `/foss/shared`, `SHARED_DIR` env var, present in
every job with no submit-time flag) exists on this scheduler but holds no GrouperSoC data —
it's the LoRa capture store for the Trouper project. Nothing here needs it.

## Sync before every job — and know that `hqsub` snapshots

NFS is **not** a git checkout and does not track your local working tree. Sync your working
copy across before each submit:

```bash
LOCAL=/home/james/projects/grouper
NFS=/srv/eda/designs/james/grouper-sim/grouper
rsync -a --exclude='.git/' --exclude='librelane/classic/runs/' --exclude='.env/' \
      "$LOCAL/" "$NFS/"
```

- **Never `rsync --delete`.** Run artifacts under `librelane/classic/runs/` live on NFS
  only (they're gitignored and not in your local tree), and `--delete` wipes them.
- **Initialize the SRAM submodule first.** `ip/gf180mcu_ocd_ip_sram` (the macro
  `lib`/`lef`/`gds`) is a real dependency of the hardened RAM flow and is absent until
  checked out: `git submodule update --init --recursive` before the first sync. `rsync`
  copies submodule *contents*, so they must exist locally.
- Sanity-check that the files that matter made it across before trusting a run — `diff` the
  config, the SDC, and any RTL you just changed against the local copies.

**`hqsub` takes a content-addressed snapshot at submit time.** The job does not read
`/srv/eda/designs/james/...` live; the daemon hashes and copies it to
`/srv/eda/designs/james/.hlab-sge-snapshots/<digest>/` (visible as `source_dir` in
`hqstat --json`) and mounts *that*. Consequences:

- Editing NFS after `hqsub` returns has **no effect** on the already-queued job.
- Two rapid submits of different trees each get their own snapshot — but see the
  concurrent-`--project` warning in the hlab-sge skill.

Write job scripts to NFS too (not just locally) — `hqsub`'s positional script argument must
resolve to a path the daemon can read.

## `--project` changes the container mount point

Without `--project`, the whole `designs/james` root is snapshotted and this repo appears at
`/foss/designs/grouper-sim/grouper/`. **With** `--project grouper-sim`, the *project
directory itself* mounts at `/foss/designs`, so the path becomes `/foss/designs/grouper/`
— **not** `/foss/designs/grouper-sim/grouper/`. Getting this wrong burns a whole job on a
`cd: No such file or directory`, so check which mount mode a script assumes before reusing
it. The `james` designs root is small enough today that unscoped submits stage fine; if it
grows, switch to `--project grouper-sim` and fix the paths in the job script at the same
time.

## `/foss/designs` is read-only — LibreLane cannot write `runs/` in place

Since the 2026-07 NFS `manage_gids` change, `/foss/designs` is mounted **read-only** inside
the container. LibreLane's default is to create its output at `<design_dir>/runs/<tag>`,
which now fails:

```
OSError: [Errno 30] Read-only file system: '/foss/designs/.../librelane/classic/runs'
```

Two ways out, both proven here:

1. **Copy the staged tree into the writable area and run from there** — what the working
   GrouperSoC PnR job scripts do. `/foss/runs` is this job's own output dir and is writable:

   ```bash
   SRC=/foss/designs/grouper-sim/grouper
   WORK=/foss/runs/pnr-${JOB_ID:-manual}
   rm -rf "$WORK"; mkdir -p "$WORK/grouper"
   cp -a "$SRC/." "$WORK/grouper/"
   cd "$WORK/grouper/librelane/classic"
   ```

   This also lets the job *generate* files in the tree (see the ROM image note below), which
   a read-only mount forbids outright.

2. **`--force-run-dir <path>`** — point LibreLane's run dir at a writable path directly.
   **The directory must already exist**; click validates it before LibreLane would `mkdir -p`:

   ```bash
   OUT=${RUN_DIR:-/foss/runs}/pnr; mkdir -p "$OUT"
   librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 --force-run-dir "$OUT" config.yaml
   ```

Option 1 is the default for GrouperSoC because the flow needs a writable tree anyway.

## The ROM image must be built inside the job

`librelane/classic/config.yaml` sets `ROM_INIT_CONST`, so `hw/rtl/rom_ss.sv` \`include\`s
`code.vmem` resolved against `VERILOG_INCLUDE_DIRS` (`sw/boot`). **`sw/boot/code.vmem` is
gitignored and does not exist in a fresh tree** — synthesis fails on the missing include.
Build it in the job script, after the copy-to-writable step:

```bash
./sw/scripts/build_bootloader.sh --no-disasm     # writes sw/boot/{code.hex,code.vmem}
[ -s sw/boot/code.vmem ] || { echo "ROM image build failed"; exit 1; }
```

This needs a bare-metal RISC-V GCC supporting `-march=rv32emc -mabi=ilp32e`. The
`chipathon26` container has `riscv64-unknown-elf-gcc`; **the host does not**, so this step
cannot be done locally before the rsync. (`sw/scripts/build_rom_boot.sh` is the stale
sibling — it still targets the deleted `sw/dry_run/`; don't use it.)

## PDK selection inside the container

Don't rely on an inherited `PDK` env var — the image carries several PDKs (`gf180mcuD`,
`ihp-sg13g2`, …) and container startup can leave `PDK` pointing at the wrong one. Set it
explicitly at the top of every job script for GF180 work:

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
the ambient environment — a Magic run that starts in `ihp-sg13g2` before the script forces
`gf180mcuD` has bitten this scheduler before:

```bash
RCFILE="$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc"
magic -dnull -noconsole -rcfile "$RCFILE" ...
```

## Where LibreLane run outputs land

With the copy-to-`/foss/runs` pattern, the run tree ends up at:

```
container:  /foss/runs/pnr-<JOB_ID>/grouper/librelane/classic/runs/<tag>/
host:       /srv/eda/runs/james/default/<JOB_ID>/pnr-<JOB_ID>/grouper/librelane/classic/runs/<tag>/
```

(`default` is the `--project` value; with `--project grouper-sim` it becomes
`/srv/eda/runs/james/grouper-sim/<JOB_ID>/...`. `hqstat --json` reports the exact host path
as `run_dir`.) Dropping a `ln -sfn "$RUN" /foss/runs/run` at the end of the job script makes
it far easier to find afterwards.

Each `<tag>/` is a set of numbered stage subdirectories (`06-yosys-synthesis`,
`37-openroad-globalrouting`, `53-openroad-stapostpnr`, `*-openroad-detailedrouting`,
`*-checker-magicdrc`, …); stage numbers shift with which steps the config gates on/off.
Use `--run-tag <tag> --overwrite` to name a run deterministically instead of the default
timestamp tag. See **pnr-results** for the read commands.

## Job stdout / stderr

Retrieve with `hqlog <id> [--stream err]`, or read `/srv/eda/logs/james/job-<id>.{o,e}`
directly. LibreLane also writes its own per-step logs inside each `runs/<tag>/<stage>/`
directory — those are usually the more useful ones for a PnR failure.

## Environment inside the container

| Variable | Value |
|----------|-------|
| `JOB_ID` | Numeric job ID |
| `JOB_NAME` | Job name passed to `hqsub` |
| `RUN_DIR` | This job's writable output dir (`/foss/runs`) |
| `SHARED_DIR` | `/foss/shared`, read-only; no GrouperSoC data in it |
| `PDK_ROOT` | `/foss/pdks` — **set it yourself; don't assume it's inherited** |

## Complete example — a synth-only sanity job

```bash
export HLAB_SGE_URL=http://nas.home:4783
LOCAL=/home/james/projects/grouper
NFS=/srv/eda/designs/james/grouper-sim/grouper

# 1. Sync the working tree (never --delete; submodules initialized first)
rsync -a --exclude='.git/' --exclude='librelane/classic/runs/' --exclude='.env/' \
      "$LOCAL/" "$NFS/"

# 2. Write the job script to NFS
cat > "$NFS/librelane/classic/synth_check.sh" << 'EOF'
#!/bin/bash
set -uo pipefail
export PDK_ROOT=/foss/pdks PDK=gf180mcuD STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

# /foss/designs is read-only: stage into the writable per-job area.
SRC=/foss/designs/grouper-sim/grouper
WORK=/foss/runs/synth-${JOB_ID:-manual}
rm -rf "$WORK"; mkdir -p "$WORK/grouper" || exit 1
cp -a "$SRC/." "$WORK/grouper/" || exit 1
cd "$WORK/grouper" || exit 1

# config.yaml sets ROM_INIT_CONST, so rom_ss.sv includes sw/boot/code.vmem (gitignored).
./sw/scripts/build_bootloader.sh --no-disasm
[ -s sw/boot/code.vmem ] || { echo "ROM image build failed"; exit 1; }

cd librelane/classic || exit 1
/foss/tools/bin/librelane config.yaml \
    --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --to Yosys.Synthesis --run-tag synth_check --overwrite
EOF

# 3. Submit and wait
JOB_ID=$(hqsub --name grouper-synth-check --cpus 2 --mem 4G \
    "$NFS/librelane/classic/synth_check.sh" | awk '{print $NF}')
hqwait "$JOB_ID"

# 4. Read results with the pnr-results skill
```

For a full P&R, swap `--cpus 2 --mem 4G` for `--cpus 20 --mem 12G`, drop
`--to Yosys.Synthesis`, and poll `hqstat --json` on a wide interval rather than blocking in
`hqwait` (see the run-pnr skill). Pin with `--node gaming-pc` when you want the 22-core box
— but re-check `hqhost --json` for that node's `state`, since a pinned job whose node goes
`unreachable` waits in `PENDING` forever with no error.
