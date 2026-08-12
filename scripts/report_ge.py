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


def find_yosys_log(target: Path) -> Path:
    """Locate the Yosys synthesis log inside a run directory."""
    if target.is_file():
        return target

    candidates = [
        p
        for p in target.rglob("*.log")
        if "yosys" in str(p.relative_to(target)).lower()
    ]
    if not candidates:
        # Some flows keep a single top-level log; fall back to any log that
        # actually contains the lines we care about.
        candidates = [
            p for p in target.rglob("*.log") if "Chip area for" in _read(p)
        ]
    if not candidates:
        raise FileNotFoundError(f"no Yosys log with area data under {target}")

    # Synthesis is the first Yosys step, so prefer the earliest-numbered dir.
    return sorted(candidates)[0]


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


def parse_metrics(run_dir: Path):
    """Fallback: the run's own metrics, if the log has moved or been pruned."""
    for name in ("metrics.json", "final_metrics.json"):
        for path in run_dir.rglob(name):
            try:
                data = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            area = data.get("design__instance__area__total") or data.get(
                "design__instance__area"
            )
            if area:
                return [(str(data.get("design__name", "top")), float(area), True)]
    return []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", type=Path, help="LibreLane run directory (or a Yosys log)")
    ap.add_argument("--match", help="only report modules whose name contains this")
    ap.add_argument(
        "--multiplier",
        type=float,
        help="also show area x MULT, for sizing a stub against unbuilt features",
    )
    args = ap.parse_args()

    if not args.run.exists():
        print(f"error: {args.run} does not exist", file=sys.stderr)
        return 1

    try:
        log = find_yosys_log(args.run)
        rows = parse_log(_read(log))
        source = log
    except FileNotFoundError as exc:
        rows = parse_metrics(args.run) if args.run.is_dir() else []
        source = f"{args.run}/metrics.json"
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
