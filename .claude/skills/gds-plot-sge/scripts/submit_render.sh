#!/bin/bash
# Driver: sync the repo to NFS, submit a GDS render job to homelab-sge, wait
# for it, and copy the resulting PNG back into the local working tree.
# Run this from the *host* (not inside a container) with hq* on PATH and
# HLAB_SGE_URL / the token already configured -- see the hlab-sge skill.
#
# Usage:
#   .claude/skills/gds-plot-sge/scripts/submit_render.sh <gds-rel-path> [out-name] [width] [height]
#
# <gds-rel-path> is relative to the repo root, e.g.:
#   final/gds/grouper_soc_chip_core.gds
#
# The rendered PNG is copied back to reports/<out-name> (default render.png).

set -euo pipefail

die() { printf 'submit_render.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: submit_render.sh <gds-rel-path> [out-name] [width] [height]"

GDS_REL=$1
OUT_NAME=${2:-render.png}
WIDTH=${3:-2400}
HEIGHT=${4:-1600}

LOCAL=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository."
NFS=/srv/eda/designs/james/grouper-sim/grouper
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ -e "$LOCAL/$GDS_REL" ] || die "gds not found locally: $LOCAL/$GDS_REL"

export HLAB_SGE_URL=${HLAB_SGE_URL:-http://nas.home:4783}

echo "==> syncing $LOCAL -> $NFS"
rsync -a --exclude='.git/' --exclude='librelane/classic/runs/' --exclude='.env/' \
      "$LOCAL/" "$NFS/"

echo "==> writing job script to NFS"
# hqsub has no --env flag (checked via `hqsub --help`, contradicting some
# older skill notes) -- bake the parameters into a generated copy of the
# template job script instead of relying on env-var injection.
JOB_DIR="$NFS/.claude/skills/gds-plot-sge/scripts"
mkdir -p "$JOB_DIR"
GEN_SCRIPT="$JOB_DIR/raster_gds_job.$$.sh"
{
  echo "#!/bin/bash"
  echo "export GDS_IN=$(printf '%q' "$GDS_REL")"
  echo "export OUT_NAME=$(printf '%q' "$OUT_NAME")"
  echo "export WIDTH=$(printf '%q' "$WIDTH")"
  echo "export HEIGHT=$(printf '%q' "$HEIGHT")"
  tail -n +2 "$SCRIPT_DIR/raster_gds_job.sh"
} > "$GEN_SCRIPT"
chmod +x "$GEN_SCRIPT"

echo "==> submitting"
JOB_ID=$(hqsub --name gds-plot-render --cpus 1 --mem 4G "$GEN_SCRIPT" | awk '{print $NF}')
[ -n "$JOB_ID" ] || die "hqsub did not return a job id"
echo "==> job $JOB_ID submitted, waiting..."

RC=0
hqwait "$JOB_ID" || RC=$?
rm -f "$GEN_SCRIPT"

RUN_DIR=$(hqstat --json --all 2>/dev/null | python3 -c '
import json,sys
jid = sys.argv[1]
data = json.load(sys.stdin)
jobs = data if isinstance(data, list) else data.get("jobs", data)
for j in jobs:
    if str(j.get("id")) == jid:
        print(j.get("run_dir", ""))
        break
' "$JOB_ID" 2>/dev/null) || true

echo "==> job $JOB_ID finished, exit code $RC"
hqlog "$JOB_ID" --stream err | tail -40 || true

[ -n "$RUN_DIR" ] || die "could not resolve run_dir for job $JOB_ID; check with: hqstat --json --all"

SRC_PNG="$RUN_DIR/$OUT_NAME"
[ -e "$SRC_PNG" ] || die "expected output not found: $SRC_PNG (job may have failed -- see hqlog $JOB_ID --stream err above)"

mkdir -p "$LOCAL/reports"
cp "$SRC_PNG" "$LOCAL/reports/$OUT_NAME"
echo "==> wrote $LOCAL/reports/$OUT_NAME"

exit $RC
