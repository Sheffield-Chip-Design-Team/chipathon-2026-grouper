#!/usr/bin/env python3
"""Render the aggregated metrics as a GitHub-flavoured Markdown page.

Written to sim-metrics/summary.md by aggregate_metrics.py and appended to
$GITHUB_STEP_SUMMARY by the workflow's metrics job, so a run's simulation
results are readable on the Actions run page without downloading the
artifact or opening 16 job logs.

Kept separate from the CSV/JSON writing so the page can be regenerated from
an existing metrics.json (see aggregate_metrics.py --from-metrics).
"""

# Coverage categories worth a column on the page. The CSV carries all of
# COVERAGE_CATEGORIES; fsm_state/fsm_arc are "N/A" for every target in this
# design (Verilator finds no FSMs it recognizes), so they'd be six columns
# of noise here.
SUMMARY_COVERAGE_CATEGORIES = ["line", "toggle", "branch", "expr"]

GROUP_LABELS = {
    "lint": "Lint",
    "directed_tb": "Directed + TB",
    "pyuvm": "pyUVM",
}

PASS, FAIL, KNOWN_FAIL, NO_TESTS = "Pass", "Fail", "Known fail", "Skipped"

def target_status(t: dict) -> str:
    """A target that only skipped tests is called out rather than counted as
    a pass - nothing was actually exercised (report_target.write_metrics
    exits nonzero on it too).
    """
    if t["tests_failed"]:
        return KNOWN_FAIL if t.get("fail_ok") else FAIL
    if not t.get("tests_run", t["tests_total"]):
        return NO_TESTS
    return PASS


def _pct(value) -> str:
    return "n/a" if value is None else f"{value * 100:.0f}%"


def _coverage_cell(coverage: dict, cat: str) -> str:
    value = coverage.get(cat, "N/A")
    return f"{value['pct']:.1f}%" if isinstance(value, dict) else "-"


def _totals(targets: list) -> dict:
    keys = ["tests_total", "tests_run", "tests_passed", "tests_failed", "tests_skipped"]
    totals = {k: sum(t.get(k, 0) for t in targets) for k in keys}
    totals["pass_rate"] = (totals["tests_passed"] / totals["tests_run"]) if totals["tests_run"] else None
    return totals


def _target_table(targets: list) -> list:
    header = ["Target", "Result", "Run", "Pass", "Fail", "Skip", "Pass rate"]
    header += [c.capitalize() for c in SUMMARY_COVERAGE_CATEGORIES]
    lines = [
        "| " + " | ".join(header) + " |",
        "|" + "---|" * len(header),
    ]
    for t in targets:
        coverage = t.get("coverage") or {}
        row = [
            f"`{t['target']}`",
            target_status(t),
            str(t.get("tests_run", "")),
            str(t["tests_passed"]),
            str(t["tests_failed"]),
            str(t.get("tests_skipped", 0)),
            _pct(t["pass_rate"]),
            *[_coverage_cell(coverage, c) for c in SUMMARY_COVERAGE_CATEGORIES],
        ]
        lines.append("| " + " | ".join(row) + " |")

    totals = _totals(targets)
    subtotal = [
        f"**{len(targets)} target(s)**", "",
        f"**{totals['tests_run']}**", f"**{totals['tests_passed']}**",
        f"**{totals['tests_failed']}**", f"**{totals['tests_skipped']}**",
        f"**{_pct(totals['pass_rate'])}**",
        *[""] * len(SUMMARY_COVERAGE_CATEGORIES),
    ]
    lines.append("| " + " | ".join(subtotal) + " |")
    return lines


def _failure_details(targets: list) -> list:
    """Every failing test, with the first line of its error, in one
    collapsed block - so a red run can be triaged from the summary page
    instead of by opening each job's log.
    """
    failures = [
        (t["target"], test)
        for t in targets
        for test in t.get("tests", [])
        if test.get("status") == "failed"
    ]
    if not failures:
        return []

    lines = [
        "",
        f"<details><summary><b>Failing tests ({len(failures)})</b></summary>",
        "",
    ]
    for target, test in failures:
        msg = (test.get("error_msg") or "").strip().splitlines()
        detail = f" — {msg[0][:200]}" if msg else ""
        lines.append(f"- `{target}` · `{test['name']}`{detail}")
    lines += ["", "</details>"]
    return lines


def render_summary(run_meta: dict, targets: list, group_order: list) -> str:
    totals = _totals(targets)
    blocking = [t for t in targets if target_status(t) == FAIL]
    known = [t for t in targets if target_status(t) == KNOWN_FAIL]
    empty = [t for t in targets if target_status(t) == NO_TESTS]

    if blocking:
        verdict = f"**{len(blocking)} of {len(targets)} targets failed**"
    elif known or empty:
        verdict = f"**All blocking targets passed** ({len(targets)} total)"
    else:
        verdict = f"**All {len(targets)} targets passed**"

    notes = []
    if known:
        notes.append(f"{len(known)} known-failing (non-blocking)")
    if empty:
        notes.append(f"{len(empty)} ran no tests")
    if totals["tests_skipped"]:
        notes.append(f"{totals['tests_skipped']} test(s) skipped, excluded from the pass rate")

    sha = run_meta.get("git_sha") or ""
    lines = [
        "# Simulation Summary",
        "",
        verdict + (" — " + ", ".join(notes) if notes else ""),
        "",
        f"{totals['tests_passed']}/{totals['tests_run']} tests passed "
        f"({_pct(totals['pass_rate'])}) across {len(targets)} target(s).",
        "",
    ]
    meta_bits = [f"Commit `{sha[:12]}`" if sha else None,
                 f"[Run log]({run_meta['run_url']})" if run_meta.get("run_url") else None,
                 run_meta.get("timestamp")]
    lines += [" · ".join(b for b in meta_bits if b), ""]

    for group in group_order:
        in_group = [t for t in targets if t.get("group") == group]
        if not in_group:
            continue
        lines += [f"## {GROUP_LABELS.get(group, group)}", ""]
        lines += _target_table(in_group)
        lines.append("")

    lines += _failure_details(targets)
    lines += [
        "",
        "<sub>Coverage columns are Verilator's line/toggle/branch/expr; `-` means the target "
        "collects no coverage of that category. `metrics.csv` in the **sim-metrics** artifact "
        "has the full breakdown, fsm_state/fsm_arc included.</sub>",
        "",
    ]
    return "\n".join(lines)
