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
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


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


def coverage_line_pct(coverage_dat: Path, info_out: Path) -> float | None:
    if not coverage_dat.is_file():
        return None
    try:
        subprocess.run(
            ["verilator_coverage", "--write-info", str(info_out), str(coverage_dat)],
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"warning: verilator_coverage failed on {coverage_dat}: {e}", file=sys.stderr)
        return None
    # Verilator's lcov output has no LF:/LH: summary lines, just raw
    # DA:<line>,<hits> records - compute lines-found/lines-hit ourselves.
    lines_found = lines_hit = 0
    for line in info_out.read_text().splitlines():
        if line.startswith("DA:"):
            lines_found += 1
            if int(line[3:].split(",", 1)[1]) > 0:
                lines_hit += 1
    if lines_found == 0:
        return None
    return 100.0 * lines_hit / lines_found


def write_metrics(target: str, kind: str, tests: list, coverage_dat: Path | None, out_dir: Path) -> int:
    """Write metrics-<target>.json and return the process exit code to use
    (0 if every test passed, 1 otherwise). Shared by report_target's own CLI
    and run_target.py, so both produce identical metrics output.
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    coverage_pct = None
    if coverage_dat:
        coverage_pct = coverage_line_pct(coverage_dat, out_dir / f"{target}.info")

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
        "coverage_line_pct": coverage_pct,
        "sim_time_ns_total": sum(t["sim_time_ns"] or 0 for t in tests) or None,
        "wall_time_s_total": sum(t["wall_time_s"] or 0 for t in tests) or None,
        "tests": tests,
    }

    out_file = out_dir / f"metrics-{target}.json"
    out_file.write_text(json.dumps(metrics, indent=2))
    print(f"Wrote {out_file}: {tests_passed}/{tests_total} passed"
          + (f", {coverage_pct:.1f}% line coverage" if coverage_pct is not None else ""))

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

    return write_metrics(args.target, args.kind, tests, args.coverage_dat, args.out_dir)


if __name__ == "__main__":
    sys.exit(main())
