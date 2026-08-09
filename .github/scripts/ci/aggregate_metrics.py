#!/usr/bin/env python3
"""Merge every metrics-<target>.json produced by report_target.py (one per
CI job, downloaded into --results-dir) into the sim-metrics artifact:
metrics.json, metrics.csv and summary.md. Runs once, in the final always()
job, so it still produces output even when some simulation jobs failed.

Targets are emitted grouped - lint, then directed + TB, then pyUVM (see
report_target.GROUPS) - and alphabetically within each group, so the CSV
rows and the summary page read in the same order every run.
"""
import argparse
import csv
import datetime
import json
import os
from pathlib import Path

from report_target import COVERAGE_CATEGORIES, GROUPS
from summary_page import render_summary


def _coverage_cell(value):
    """A category's value in metrics-<target>.json's "coverage" dict is
    either a {pct,hit,total} detail dict or the literal string "N/A" (see
    report_target.apply_coverage_scope) - the CSV only wants the percentage,
    or "N/A" verbatim.
    """
    return value["pct"] if isinstance(value, dict) else value


def sort_key(target: dict):
    """Group order first (lint, directed_tb, pyuvm), then target name. A
    group this script doesn't know sorts after the known ones rather than
    crashing, so adding one to sim-ci-targets.yaml can't lose its rows.
    """
    group = target.get("group")
    rank = GROUPS.index(group) if group in GROUPS else len(GROUPS)
    return (rank, group or "", target["target"])


def default_run_metadata():
    server = os.environ.get("GITHUB_SERVER_URL", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    run_url = f"{server}/{repo}/actions/runs/{run_id}" if (server and repo and run_id) else None
    return {
        "git_sha": os.environ.get("GITHUB_SHA"),
        "run_id": run_id or None,
        "run_url": run_url,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results-dir", required=True, type=Path,
                     help="Directory to search recursively for metrics-*.json")
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--git-sha", help="Overrides $GITHUB_SHA")
    ap.add_argument("--run-id", help="Overrides $GITHUB_RUN_ID")
    ap.add_argument("--run-url", help="Overrides the computed $GITHUB_SERVER_URL/... run URL")
    args = ap.parse_args()

    run_meta = default_run_metadata()
    if args.git_sha:
        run_meta["git_sha"] = args.git_sha
    if args.run_id:
        run_meta["run_id"] = args.run_id
    if args.run_url:
        run_meta["run_url"] = args.run_url
    run_meta["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()

    target_files = sorted(args.results_dir.rglob("metrics-*.json"))
    if not target_files:
        raise SystemExit(f"No metrics-*.json files found under {args.results_dir}")

    targets = sorted((json.loads(f.read_text()) for f in target_files), key=sort_key)

    args.out_dir.mkdir(parents=True, exist_ok=True)

    (args.out_dir / "metrics.json").write_text(
        json.dumps({"run": run_meta, "targets": targets}, indent=2)
    )

    csv_path = args.out_dir / "metrics.csv"
    with csv_path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "timestamp", "git_sha", "run_id", "group", "target",
            "tests_total", "tests_run", "tests_passed", "tests_failed", "tests_skipped",
            "pass_rate",
            *[f"coverage_{cat}_pct" for cat in COVERAGE_CATEGORIES],
        ])
        for t in targets:
            coverage = t.get("coverage") or {}
            writer.writerow([
                run_meta["timestamp"], run_meta["git_sha"], run_meta["run_id"],
                t.get("group", ""), t["target"],
                t["tests_total"], t.get("tests_run"), t["tests_passed"], t["tests_failed"],
                t.get("tests_skipped", 0), t["pass_rate"],
                *[_coverage_cell(coverage.get(cat, "N/A")) for cat in COVERAGE_CATEGORIES],
            ])

    summary_path = args.out_dir / "summary.md"
    summary_path.write_text(render_summary(run_meta, targets, GROUPS))

    print(f"Wrote {args.out_dir / 'metrics.json'}, {csv_path} and {summary_path} "
          f"for {len(targets)} target(s)")


if __name__ == "__main__":
    main()
