#!/usr/bin/env python3
"""Run one DV target's `fusesoc run` (per a .github/dv-ci-targets.yaml entry)
and report its results, in one step. Used by the CI 'sim' matrix job - see
report_target.py for the standalone equivalent that works against results
already sitting in a build/ work root from a previous run.

results.xml/coverage.dat paths are derived from FuseSoC's own work-root
convention (build/<resolved VLNV with ':' -> '_'>/<fusesoc_target>/) rather
than passed in, so they can't drift out of sync with the core/target names.
"""
import argparse
import shlex
import subprocess
import sys
from pathlib import Path

from report_target import (
    coverage_line_pct,  # noqa: F401 (re-exported for callers that only need this)
    parse_cocotb_results,
    parse_exit_code,
    parse_log_grep,
    write_metrics,
)


def resolve_vlnv(core: str) -> str:
    """FuseSoC work-root directory names use the fully-resolved VLNV
    (name:library:name:VERSION), not whatever partial/unversioned core
    string was passed to `fusesoc run` - resolve it via `core-info` rather
    than requiring every dv-ci-targets.yaml entry to hardcode a version.
    """
    out = subprocess.run(["fusesoc", "core-info", core], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("Name:"):
            return line.split(":", 1)[1].strip()
    raise RuntimeError(f"could not resolve VLNV for core {core!r} from `fusesoc core-info` output:\n{out}")


def work_root(core: str, fusesoc_target: str) -> Path:
    return Path("build") / resolve_vlnv(core).replace(":", "_") / fusesoc_target


def run_fusesoc(core: str, fusesoc_target: str, fusesoc_args: str, log_file: Path) -> int:
    cmd = ["fusesoc", "run", *shlex.split(fusesoc_args), f"--target={fusesoc_target}", core]
    print(f"+ {' '.join(cmd)}")
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("w") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            sys.stdout.write(line)
            log.write(line)
        proc.wait()
    return proc.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", required=True, help="Metrics target name, e.g. ahb_uart_pyuvm")
    ap.add_argument("--core", required=True, help="FuseSoC CAPI2 VLNV")
    ap.add_argument("--fusesoc-target", required=True)
    ap.add_argument("--kind", required=True, choices=["cocotb", "log-grep", "exit-code"])
    ap.add_argument("--fusesoc-args", default="", help="Extra `fusesoc run` flags, e.g. --build")
    ap.add_argument("--success-pattern", default="", help="Required text in the log (--kind log-grep)")
    ap.add_argument("--out-dir", required=True, type=Path)
    args = ap.parse_args()

    if args.kind == "log-grep" and not args.success_pattern:
        ap.error("--kind log-grep requires --success-pattern")

    root = work_root(args.core, args.fusesoc_target)
    log_file = args.out_dir / f"{args.name}.log"
    exit_code = run_fusesoc(args.core, args.fusesoc_target, args.fusesoc_args, log_file)

    results_xml = root / "results.xml"
    coverage_dat = root / "coverage.dat"

    if args.kind == "cocotb":
        if not results_xml.is_file():
            tests = [{
                "name": "results_xml_present", "classname": None, "passed": False,
                "sim_time_ns": None, "wall_time_s": None,
                "error_msg": f"{results_xml} not found (build likely failed before cocotb ran)",
            }]
        else:
            tests = parse_cocotb_results(results_xml)
    elif args.kind == "log-grep":
        tests = parse_log_grep(log_file, args.success_pattern)
    else:
        tests = parse_exit_code(exit_code)

    return write_metrics(args.name, args.kind, tests, coverage_dat, args.out_dir)


if __name__ == "__main__":
    sys.exit(main())
