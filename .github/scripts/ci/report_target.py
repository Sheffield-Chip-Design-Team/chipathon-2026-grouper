#!/usr/bin/env python3
"""Summarize one DV target's test results (and coverage, if present) into
metrics-<target>.json, and exit nonzero if the target should be considered
failed.

cocotb's own results.xml has no pass/fail count attributes (must count
<testcase>/<failure> elements), and cocotb never forces the simulator
process to exit nonzero on a failing test - so this is the only reliable
place to compute per-target pass/fail for the cocotb-based jobs.
"""
import argparse
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Matches lines from `verilator_coverage <file>`'s flat "Coverage Summary:"
# block, e.g. "  fsm_state : 0.0% (  0/  0)" - padding/width varies with the
# magnitude of the counts, so whitespace is deliberately loose here.
_COVERAGE_SUMMARY_RE = re.compile(
    r"^\s*(?P<category>\w+)\s*:\s*(?P<pct>[\d.]+)%\s*\(\s*(?P<hit>\d+)\s*/\s*(?P<total>\d+)\s*\)\s*$"
)

# All categories verilator_coverage's flat summary can report. Every
# metrics-<target>.json's "coverage" object always has exactly these keys -
# either a {pct,hit,total} detail dict, or the literal string "N/A" for a
# category that --coverage-scope suppressed (or that has no coverage.dat
# at all, e.g. a lint-only target). aggregate_metrics.py imports this list
# too, so the CSV's coverage_*_pct columns can't drift out of sync with it.
COVERAGE_CATEGORIES = ["line", "toggle", "branch", "expr", "fsm_state", "fsm_arc"]
COVERAGE_SCOPES = ["full", "line", "none"]


def parse_cocotb_results(results_xml: Path):
    root = ET.parse(results_xml).getroot()
    tests = []
    for testcase in root.iter("testcase"):
        failure = testcase.find("failure")
        skipped = testcase.find("skipped")
        tests.append(
            {
                "name": testcase.get("name"),
                "classname": testcase.get("classname"),
                "passed": failure is None and skipped is None,
                "sim_time_ns": float(testcase.get("sim_time_ns", 0.0)),
                "wall_time_s": float(testcase.get("time", 0.0)),
                "error_msg": failure.get("error_msg") if failure is not None else None,
            }
        )
    return tests


def parse_log_grep(log_file: Path, success_pattern: str):
    text = log_file.read_text(errors="replace")
    passed = success_pattern in text
    return [
        {
            "name": "log_contains_success_marker",
            "classname": None,
            "passed": passed,
            "sim_time_ns": None,
            "wall_time_s": None,
            "error_msg": None if passed else f"pattern {success_pattern!r} not found in log",
        }
    ]


def parse_exit_code(exit_code: int):
    passed = exit_code == 0
    return [
        {
            "name": "process_exit_code",
            "classname": None,
            "passed": passed,
            "sim_time_ns": None,
            "wall_time_s": None,
            "error_msg": None if passed else f"exited with code {exit_code}",
        }
    ]


def coverage_breakdown(coverage_dat: Path) -> dict | None:
    """Parse verilator_coverage's flat "Coverage Summary:" block (line,
    toggle, branch, expr, fsm_state, fsm_arc) straight from stdout - no
    --write-info/.info file needed, and unlike the lcov format it actually
    has a place for toggle/branch/FSM data, not just line coverage.
    """
    if not coverage_dat.is_file():
        return None
    try:
        out = subprocess.run(
            ["verilator_coverage", str(coverage_dat)],
            check=True, capture_output=True, text=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        print(f"warning: verilator_coverage failed on {coverage_dat}: {e}", file=sys.stderr)
        return None

    breakdown = {}
    for line in out.splitlines():
        m = _COVERAGE_SUMMARY_RE.match(line)
        if m:
            hit, total = int(m["hit"]), int(m["total"])
            # 0/0 means there was nothing of this category to cover at all
            # (e.g. fsm_state on a design with no Verilator-recognizable
            # FSMs) - that's vacuously fully covered, not 0% covered, even
            # though Verilator's own summary text prints "0.0%" for it.
            pct = 100.0 if total == 0 else float(m["pct"])
            breakdown[m["category"]] = {"pct": pct, "hit": hit, "total": total}
    return breakdown or None


def apply_coverage_scope(full_breakdown: dict | None, coverage_scope: str) -> dict:
    """Always returns a dict with every COVERAGE_CATEGORIES key present -
    either the {pct,hit,total} detail for a category that was both
    collected and surfaced, or the literal string "N/A" for one that
    --coverage-scope suppressed, or that was never collected at all (no
    coverage.dat, e.g. a lint-only target).
    """
    result = {}
    for cat in COVERAGE_CATEGORIES:
        if coverage_scope == "none":
            result[cat] = "N/A"
        elif coverage_scope == "line" and cat != "line":
            result[cat] = "N/A"
        elif full_breakdown and cat in full_breakdown:
            result[cat] = full_breakdown[cat]
        else:
            result[cat] = "N/A"
    return result


def write_metrics(
    target: str, kind: str, tests: list, coverage_dat: Path | None, coverage_scope: str, out_dir: Path
) -> int:
    """Write metrics-<target>.json and return the process exit code to use
    (0 if every test passed, 1 otherwise). Shared by report_target's own CLI
    and run_target.py, so both produce identical metrics output.
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    full_breakdown = coverage_breakdown(coverage_dat) if coverage_dat and coverage_scope != "none" else None
    coverage = apply_coverage_scope(full_breakdown, coverage_scope)

    tests_total = len(tests)
    tests_passed = sum(1 for t in tests if t["passed"])
    tests_failed = tests_total - tests_passed

    metrics = {
        "target": target,
        "kind": kind,
        "tests_total": tests_total,
        "tests_passed": tests_passed,
        "tests_failed": tests_failed,
        "pass_rate": (tests_passed / tests_total) if tests_total else None,
        "coverage": coverage,
        "sim_time_ns_total": sum(t["sim_time_ns"] or 0 for t in tests) or None,
        "wall_time_s_total": sum(t["wall_time_s"] or 0 for t in tests) or None,
        "tests": tests,
    }

    out_file = out_dir / f"metrics-{target}.json"
    out_file.write_text(json.dumps(metrics, indent=2))
    cov_summary = ", " + ", ".join(
        f"{cat}={v['pct']:.1f}%" if isinstance(v, dict) else f"{cat}={v}"
        for cat, v in coverage.items()
    )
    print(f"Wrote {out_file}: {tests_passed}/{tests_total} passed{cov_summary}")

    return 1 if tests_failed else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target", required=True, help="Metrics target name, e.g. ahb_uart_pyuvm")
    ap.add_argument("--kind", required=True, choices=["cocotb", "log-grep", "exit-code"])
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--results-xml", type=Path, help="cocotb results.xml (--kind cocotb)")
    ap.add_argument("--log-file", type=Path, help="Captured stdout log (--kind log-grep)")
    ap.add_argument("--success-pattern", help="Substring that must appear in --log-file")
    ap.add_argument("--exit-code", type=int, help="Recorded process exit code (--kind exit-code)")
    ap.add_argument("--coverage-dat", type=Path, help="Optional Verilator coverage.dat to summarize")
    ap.add_argument("--coverage-scope", default="full", choices=COVERAGE_SCOPES,
                     help="full = report every category, line = only line (rest N/A), "
                          "none = no coverage at all (all categories N/A)")
    args = ap.parse_args()

    if args.kind == "cocotb":
        if not args.results_xml:
            ap.error("--kind cocotb requires --results-xml")
        if not args.results_xml.is_file():
            # Most likely a build/compile failure upstream, so cocotb never ran.
            # Still record a data point instead of crashing, so the aggregator
            # doesn't get a silent gap for this target.
            tests = [{
                "name": "results_xml_present", "classname": None, "passed": False,
                "sim_time_ns": None, "wall_time_s": None,
                "error_msg": f"{args.results_xml} not found (build likely failed before cocotb ran)",
            }]
        else:
            tests = parse_cocotb_results(args.results_xml)
    elif args.kind == "log-grep":
        if not args.log_file or not args.success_pattern:
            ap.error("--kind log-grep requires --log-file and --success-pattern")
        if not args.log_file.is_file():
            tests = [{
                "name": "log_contains_success_marker", "classname": None, "passed": False,
                "sim_time_ns": None, "wall_time_s": None,
                "error_msg": f"{args.log_file} not found (run likely failed before it was captured)",
            }]
        else:
            tests = parse_log_grep(args.log_file, args.success_pattern)
    else:
        if args.exit_code is None:
            ap.error("--kind exit-code requires --exit-code")
        tests = parse_exit_code(args.exit_code)

    return write_metrics(args.target, args.kind, tests, args.coverage_dat, args.coverage_scope, args.out_dir)


if __name__ == "__main__":
    sys.exit(main())
