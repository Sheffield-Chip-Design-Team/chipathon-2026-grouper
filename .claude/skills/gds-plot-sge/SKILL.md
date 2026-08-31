---
name: gds-plot-sge
description: Render a GDS layout to a PNG by submitting a KLayout job to homelab-sge, for hosts (like this one) where the local user has no docker group membership so gds-plot's own docker-based raster_gds.sh can't run. Reuses gds-plot's raster_gds.py unmodified, run directly inside the SGE worker container (no nested docker) since that container already is hpretl/iic-osic-tools:chipathon26. Triggers on "render the gds" / "screenshot the layout" / "plot the die" when local docker access fails with a permission error, or when told to render via SGE.
---

# gds-plot-sge

`gds-plot`'s `raster_gds.sh` renders a GDS via `docker run hpretl/iic-osic-tools:chipathon26`.
That needs the local user in the `docker` group. **On this host `james` is not a member**
(`getent group docker` lists `timothyn`, `woodie`, `hlab-sge` — not `james`) and there's no
passwordless `sudo`, so `docker info` fails with `permission denied ... docker.sock` and the
local path is a dead end here.

The fix isn't a nested `docker run` inside an SGE job — it's simpler than that: the
homelab-sge worker **is already that same image** (`sge-job` skill confirms the
`chipathon26` container is what GrouperSoC PnR jobs run in, and `gds-plot`'s own "Known
issue" notes confirm `pycairo`/`PIL`/`numpy` are present in that image's KLayout-embedded
Python). So inside an SGE job, `klayout` is already on `PATH` — just run
`gds-plot`'s `scripts/raster_gds.py` directly, no docker layer at all.

## Use the driver

```bash
.claude/skills/gds-plot-sge/scripts/submit_render.sh <gds-rel-path> [out-name] [width] [height]
```

`<gds-rel-path>` is relative to the repo root. Example — the last saved-off P&R run:

```bash
.claude/skills/gds-plot-sge/scripts/submit_render.sh \
  final/gds/grouper_soc_chip_core.gds \
  grouper_soc_chip_core_render.png
```

This does, in order:

1. `rsync`s the working tree to `/srv/eda/designs/james/grouper-sim/grouper` (same target,
   same excludes as the `sge-job` skill's sync step — never `--delete`, run outputs under
   `librelane/classic/runs/` live on NFS only).
2. Generates a one-off copy of `scripts/raster_gds_job.sh` with `GDS_IN`/`OUT_NAME`/
   `WIDTH`/`HEIGHT` baked in as `export` lines at the top, and writes it to the same NFS
   tree. **`hqsub` has no `--env` flag** (checked directly with `hqsub --help`, contradicting
   an env-var-injection assumption that seemed natural from the `hlab-sge` skill's examples)
   — baking the values into the generated script is the actual way to parameterize a job.
3. `hqsub`s it (1 CPU, 4G — this is a KLayout raster job, not a PnR job) and `hqwait`s.
4. Resolves the job's `run_dir` via `hqstat --json --all` and copies
   `$run_dir/<out-name>` back to `reports/<out-name>` in the local working tree.
5. Prints the last 40 lines of job stderr either way, so a failure is diagnosable without a
   separate `hqlog` call.

Takes well under a minute of actual KLayout time (raster_gds.py is ~12s per the gds-plot
skill's own numbers); most of the wall-clock is the `rsync` and SGE queueing.

## Why no tree-copy-to-`/foss/runs` step

The `sge-job` skill's LibreLane examples copy the whole staged tree into `/foss/runs` first,
because `/foss/designs` is read-only and LibreLane wants to write `runs/<tag>/` back inside
the design tree. This job only **reads** the `.gds` and `raster_gds.py` (both fine read-only)
and **writes** a single PNG straight to `/foss/runs` — there's nothing else to make writable,
so skip that step entirely. Don't copy this pattern onto a job that needs to write anywhere
under the design tree itself.

## If you change `raster_gds.py`

Edit it once, in `gds-plot`'s copy (`.claude/skills/gds-plot/scripts/raster_gds.py`) —
`raster_gds_job.sh` here references that path directly
(`.claude/skills/gds-plot/scripts/raster_gds.py` under the synced NFS tree) rather than
keeping a second copy. `submit_render.sh`'s `rsync` step picks up any local edit
automatically on the next submit; there is nothing to duplicate or keep in sync by hand.

## Troubleshooting

- **`gds not found locally`** — `<gds-rel-path>` is checked against the local working tree
  before syncing; make sure the path is relative to the repo root, not absolute.
- **`could not resolve run_dir for job <id>`** — `hqstat --json --all` didn't have the job
  by the time the script queried it (rare race) or the job ID parse failed; run
  `hqstat --json --all | python3 -m json.tool | grep -A2 '"id": <id>'` by hand.
- **`expected output not found`** — the job ran but KLayout didn't produce the PNG; the
  printed stderr tail is almost always the answer (see `gds-plot`'s "three failure modes"
  section — the `-rd name=value` global-injection gotcha applies here too, unchanged, since
  this reuses the same script unmodified).
- **A stale job script left on NFS** — `submit_render.sh` writes
  `.claude/skills/gds-plot-sge/scripts/raster_gds_job.<pid>.sh` per invocation and deletes it
  after `hqwait` returns; one surviving after a hard failure (Ctrl-C mid-run) is harmless and
  safe to delete by hand.

## See also

- **gds-plot** — the underlying `raster_gds.py`/`render_gds.py`, the layer/color scheme, and
  why `render_gds.py`/`render_gds.sh` are broken and kept only for reference. Use that skill
  directly (not this one) on any host where the invoking user *is* in the `docker` group.
- **hlab-sge** — general `hqsub`/`hqstat`/`hqlog`/`hqwait` mechanics.
- **sge-job** — GrouperSoC's NFS layout, `/foss/designs` read-only constraint, and why PnR
  jobs (unlike this one) need the copy-to-`/foss/runs` step.
