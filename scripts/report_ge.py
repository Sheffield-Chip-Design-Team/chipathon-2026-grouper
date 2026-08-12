#!/usr/bin/env python3
"""Report per-module gate-equivalent area from a LibreLane run.

Scrapes the "Chip area for module" lines that Yosys' `stat -liberty` writes and
divides by the area of one NAND2, so blocks can be compared in GE rather than
in raw square microns.

    python3 scripts/report_ge.py librelane/measure/runs/ge_spi_m
    python3 scripts/report_ge.py librelane/classic/runs/<tag> --match ahb_stub_slave

See librelane/measure/README.md for how the GE constant was derived and how the
numbers feed back into ahb_stub_slave's TARGET_GE.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# One gate equivalent is the area of one gf180mcu_fd_sc_mcu7t5v0__nand2_1.
#
# Derived from librelane/classic/build.log: 1215 nand2_1 instances totalling
# 1.33e4 um^2, which snaps to 5 sites on the 0.56 x 3.92 um site grid. Swap
# this if the standard cell library ever changes.
UM2_PER_GE = 10.976
STD_CELL_LIBRARY = "gf180mcu_fd_sc_mcu7t5v0"

AREA_RE = re.compile(r"^\s*Chip area for (top )?module '(.+)':\s*([0-9.eE+-]+)\s*$")

# Verilog-literal parameter values as yosys spells them in $paramod names,
# e.g. "s32'00000000000000000000000000100000".
PARAM_VAL_RE = re.compile(r"^s?(\d+)'([01]+)$")


# Yosys' own generic cell names, e.g. $_AND_, $_DFF_P_, $_MUX_. Their presence
# in a stat means the netlist is only partly mapped to the standard cell
# library, so its area is an undercount.
GENERIC_CELL_RE = re.compile(r"\$_[A-Z0-9]+_")


def area_reports(target: Path):
    """Every file under `target` that carries a Yosys area report."""
    files = sorted(
        p
        for pat in ("*.log", "*.rpt", "*.txt")
        for p in target.rglob(pat)
    )
    return [(p, _read(p)) for p in files if "Chip area for" in _read(p)]


def rank(entry):
    """Sort key picking the most complete area report.

    A synthesis step emits several stats. `reports/post_dff.rpt` is taken after
    dfflibmap but before abc, so its combinational logic is still generic gates
    contributing no area - it undercounts badly (flops only). Prefer a stat with
    no generic cells left, then one that names a top module, then the one
    written last.
    """
    path, text = entry
    return (
        not GENERIC_CELL_RE.search(text),
        "Chip area for top module" in text,
        path.stat().st_mtime,
    )


def find_yosys_log(target: Path):
    """Pick the most complete Yosys area report in a run directory.

    Returns (path, fully_mapped).
    """
    if target.is_file():
        return target, not GENERIC_CELL_RE.search(_read(target))

    candidates = area_reports(target)
    if not candidates:
        raise FileNotFoundError(
            f"no file under {target} contains a 'Chip area for' line "
            f"- did synthesis run?"
        )

    best = max(candidates, key=rank)
    return best[0], not GENERIC_CELL_RE.search(best[1])


def _read(path: Path) -> str:
    return path.read_text(errors="replace")


def pretty_name(raw: str) -> str:
    """Turn a yosys module name into something readable.

    Parameterised modules arrive as
    `$paramod\\ahb_stub_slave\\ADDR_WIDTH=s32'...\\TARGET_GE=s32'...`; keep the
    base name and append the parameters that actually distinguish instances.
    """
    name = raw.lstrip("\\")
    if not name.startswith("$paramod"):
        return name

    parts = name.split("\\")[1:]
    if not parts:
        return name

    base, params = parts[0], []
    for chunk in parts[1:]:
        if "=" not in chunk:
            continue
        key, _, val = chunk.partition("=")
        m = PARAM_VAL_RE.match(val)
        if m:
            val = str(int(m.group(2), 2))
        params.append(f"{key}={val}")

    return f"{base} [{', '.join(params)}]" if params else base


def parse_log(text: str):
    """Yield (name, area_um2, is_top) for every area line in the log."""
    seen = {}
    for line in text.splitlines():
        m = AREA_RE.match(line)
        if not m:
            continue
        is_top, raw, area = bool(m.group(1)), m.group(2), float(m.group(3))
        # Yosys prints the same module once per `stat` invocation; the last one
        # is the post-mapping number we want.
        seen[(raw, is_top)] = area

    return [(raw, area, is_top) for (raw, is_top), area in seen.items()]


# Total standard cell area of the design, as LibreLane names it. This is the
# post-synthesis mapped area - the number a `--to Yosys.Synthesis` run exists to
# produce - and it is whole-design only, never per-module.
AREA_METRIC_KEYS = ("design__instance__area", "design__instance__area__total")


def parse_metrics(run_dir: Path):
    """Read the design's total cell area from a run's metrics.

    A run carries one metrics file per step, so prefer the run-level
    final_metrics.json and otherwise the highest-numbered step - the last one to
    have touched the area.
    """
    paths = sorted(run_dir.rglob("final_metrics.json")) + sorted(
        run_dir.rglob("metrics.json"), reverse=True
    )
    for path in paths:
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        area = next((data[k] for k in AREA_METRIC_KEYS if data.get(k)), None)
        if area:
            return [(str(data.get("design__name", "top")), float(area), True)], path
    return [], None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", type=Path, help="LibreLane run directory (or a Yosys log)")
    ap.add_argument("--match", help="only report modules whose name contains this")
    ap.add_argument(
        "--multiplier",
        type=float,
        help="also show area x MULT, for sizing a stub against unbuilt features",
    )
    ap.add_argument(
        "--report",
        type=Path,
        help="read this file instead of auto-selecting one from the run",
    )
    ap.add_argument(
        "--list",
        action="store_true",
        help="list every area report in the run, best first, and exit",
    )
    args = ap.parse_args()

    if not args.run.exists():
        print(f"error: {args.run} does not exist", file=sys.stderr)
        return 1

    if args.list:
        found = area_reports(args.run) if args.run.is_dir() else []
        if not found:
            print(f"no area reports under {args.run}", file=sys.stderr)
            return 1
        w = max(len("Report"), max(len(str(p)) for p, _ in found))
        header = f"{'Report':<{w}}  {'Top area (um^2)':>15}  Fully mapped"
        print(header)
        print("-" * len(header))
        for path, text in sorted(found, key=rank, reverse=True):
            tops = [a for _, a, is_top in parse_log(text) if is_top]
            area = f"{max(tops):,.1f}" if tops else "-"
            mapped = "no (undercounts)" if GENERIC_CELL_RE.search(text) else "yes"
            print(f"{str(path):<{w}}  {area:>15}  {mapped}")
        return 0

    if args.report:
        args.run = args.report

    try:
        log, fully_mapped = find_yosys_log(args.run)
        rows, source = parse_log(_read(log)), log

        # A stat taken before abc (LibreLane's reports/post_dff.rpt) counts
        # flops but almost no combinational logic. The step's own metrics carry
        # the real post-synthesis total, so prefer them when that is all we
        # have - but only for the whole-design number, since they are not
        # per-module.
        if not fully_mapped and not args.match and args.run.is_dir():
            metric_rows, metric_path = parse_metrics(args.run)
            if metric_rows:
                rows, source = metric_rows, metric_path
            else:
                print(
                    f"warning: {log} still contains unmapped generic cells, so "
                    f"its area counts flops but little combinational logic, and "
                    f"no metrics.json was found to replace it. Run with --list "
                    f"to see what else is available.",
                    file=sys.stderr,
                )
    except FileNotFoundError as exc:
        rows, source = parse_metrics(args.run) if args.run.is_dir() else ([], None)
        if not rows:
            print(f"error: {exc}", file=sys.stderr)
            return 1

    rows = [(pretty_name(raw), area, is_top) for raw, area, is_top in rows]
    if args.match:
        rows = [r for r in rows if args.match in r[0]]
    if not rows:
        print(f"no matching modules in {source}", file=sys.stderr)
        return 1

    rows.sort(key=lambda r: r[1], reverse=True)

    name_w = max(len("Module"), max(len(r[0]) for r in rows))
    header = f"{'Module':<{name_w}}  {'Area (um^2)':>13}  {'GE':>9}"
    if args.multiplier:
        header += f"  {f'x{args.multiplier:g} GE':>11}"

    print(f"# {source}")
    print(f"# 1 GE = {UM2_PER_GE} um^2 (nand2_1, {STD_CELL_LIBRARY})")
    print()
    print(header)
    print("-" * len(header))
    for name, area, is_top in rows:
        ge = area / UM2_PER_GE
        line = f"{name:<{name_w}}  {area:>13,.1f}  {ge:>9,.0f}"
        if args.multiplier:
            line += f"  {ge * args.multiplier:>11,.0f}"
        if is_top:
            line += "   <- top"
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
