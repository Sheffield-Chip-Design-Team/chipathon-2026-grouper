#!/bin/bash
# SGE job body: render a GDS already present in the synced design tree to a
# PNG via KLayout, run *directly* inside the scheduler's own container image
# (no nested `docker run` -- the homelab-sge worker image for this project
# *is* hpretl/iic-osic-tools:chipathon26, the same image gds-plot's local
# raster_gds.sh launches, so klayout + its embedded pycairo/PIL/numpy are
# already on PATH). See the gds-plot skill for why raster_gds.py (Region +
# pycairo) is used instead of render_gds.py (LayoutView.save_image(), broken
# as of 2026-08-19).
#
# /foss/designs is read-only -- fine here, this only *reads* the GDS and the
# script, and writes just the PNG, so (unlike the LibreLane PnR jobs) there's
# no need to copy the whole tree into /foss/runs first.
#
# Required env (set via `hqsub --env` or by writing them into a copy of this
# script -- see SKILL.md):
#   GDS_IN    path to the .gds, relative to /foss/designs/grouper-sim/grouper
#             e.g. final/gds/grouper_soc_chip_core.gds
# Optional:
#   OUT_NAME  output PNG filename, written under /foss/runs (default render.png)
#   WIDTH     default 2400
#   HEIGHT    default 1600

set -uo pipefail

: "${GDS_IN:?set GDS_IN to a .gds path relative to /foss/designs/grouper-sim/grouper}"
OUT_NAME=${OUT_NAME:-render.png}
WIDTH=${WIDTH:-2400}
HEIGHT=${HEIGHT:-1600}

DESIGN_ROOT=/foss/designs/grouper-sim/grouper
SCRIPT="$DESIGN_ROOT/.claude/skills/gds-plot/scripts/raster_gds.py"
GDS_ABS="$DESIGN_ROOT/$GDS_IN"
OUT="/foss/runs/$OUT_NAME"

echo "===== host $(hostname)  job ${JOB_ID:-manual} ====="
echo "gds:    $GDS_ABS"
echo "out:    $OUT"
echo "script: $SCRIPT"

[ -e "$GDS_ABS" ] || { echo "FATAL: gds not found: $GDS_ABS (did you rsync it to NFS first?)"; exit 1; }
[ -e "$SCRIPT" ] || { echo "FATAL: raster_gds.py not found: $SCRIPT (did you rsync .claude/skills/gds-plot to NFS first?)"; exit 1; }

mkdir -p "$(dirname "$OUT")"

# No X server / VNC in this job's container session -- same as raster_gds.sh's
# `-e QT_QPA_PLATFORM=offscreen` on the docker path. Without it klayout aborts
# trying to load the "xcb" Qt platform plugin instead of running headless.
export QT_QPA_PLATFORM=offscreen

klayout -z -r "$SCRIPT" \
    -rd "gds=$GDS_ABS" \
    -rd "out=$OUT" \
    -rd "width=$WIDTH" -rd "height=$HEIGHT"
rc=$?

echo "===== klayout exit code: $rc ====="
ls -la "$OUT" 2>/dev/null
ln -sfn "$OUT" /foss/runs/latest_render.png 2>/dev/null

exit $rc
