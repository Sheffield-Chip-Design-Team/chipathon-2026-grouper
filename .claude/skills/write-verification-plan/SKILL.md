---
name: write-verification-plan
description: Create or revise evidence-based block-level RTL verification plans for GrouperSoC from design source, specifications, traceability, risks, formal properties, and actual tests. Use when asked to write a verification plan, test plan, verification closure tracker, coverage plan, or requirement-to-test matrix for one or more Verilog/SystemVerilog blocks under `hw/rtl/`, especially documents under `docs/hardware/verification/`.
---

# Write Verification Plan

Create a precise closure tracker, not a generic list of desirable tests. Separate
what is already verified from partial evidence, missing tests, analysis-only
requirements, and specification/RTL conflicts.

Read [references/plan-template.md](references/plan-template.md) before drafting.

> **GrouperSoC docs caveat:** `docs/` is a mix of current and stale planning material.
> `docs/hardware/Schematic Review.md` is the one confirmed-authoritative source doc; the block
> docs and existing verification plans describe *intended* behavior, and several blocks they
> specify are stubbed or unwired in RTL. **Do not take register addresses, memory maps, or
> block descriptions from `docs/` as ground truth** — verify against `hw/rtl/`, the block
> `.core` files, and `.github/sim-ci-targets.yaml`.

## Workflow

### 1. Establish scope

1. Read repository guidance (`CLAUDE.md`).
2. Resolve every requested DUT to its current `hw/rtl/<area>/<block>.sv` file (and its AHB
   wrapper, e.g. `hw/rtl/uart/` wrapped by `ahb_uart`).
3. Create one plan per DUT unless the user explicitly requests a combined interface/system
   plan. Shared tests may appear in multiple plans when each plan explains the block-specific
   evidence they provide.
4. Default the output to
   `docs/hardware/verification/blocks/<Block> Verification Plan.md` (block plans), or
   `docs/hardware/verification/Grouper SoC Verification Plan.md` (the system plan).
5. Preserve unrelated worktree changes.

### 2. Build the evidence set

Inspect sources in this order:

1. Current RTL, including its top-level instantiation and integration wiring (the block's AHB
   wrapper, its slot in `hw/rtl/periph_ss.sv`, and the address decode in
   `hw/rtl/ahb_interconnect_ss.sv`).
2. `docs/hardware/Schematic Review.md` (authoritative) and
   `docs/hardware/design/Grouper SoC Specification.md` requirement rows for the block.
3. The block's design doc under `docs/hardware/design/blocks/` — treat as intent, not truth.
4. Any traceability / open-risks material that exists; flag it if stale.
5. Existing cocotb (`hw/tb/<block>/`, `hw/dv/`), pyuvm UVCs (`hw/dv/uvc/`), and the
   SystemVerilog TBs. Read test bodies, assertions, stimulus ranges, and scoreboards.
6. The block's `.core` file and `.github/sim-ci-targets.yaml` to establish what is actually
   compiled, how it runs, and which legs are `fail_ok` (i.e. known-failing).

Use `rg`/`rg --files` to find relevant material. Never infer coverage from a filename or a
traceability entry alone.

Treat current RTL and the Schematic Review as primary evidence. Flag stale secondary docs
instead of silently copying them — the address map in older docs (a ROM→RAM bank-switch boot
flow, a sparse `0x8000_0000` layout) does **not** match the current contiguous decode in
`ahb_interconnect_ss.sv`.

### 3. Audit behavior and requirements

For each requirement and meaningful RTL behavior:

- Identify reset behavior, state transitions, legal/illegal inputs, boundary values,
  precedence on simultaneous events, sticky/pulse lifetime, and protocol timing (AHB-Lite
  handshake, `HREADYOUT`, byte-select).
- Trace each output and side effect through integration wiring where needed.
- Identify clock-domain, reset-domain (the per-GPIO 2-FF synchronisers and their
  `gpio_sync_en_n` bypass are a deliberate CDC opt-out), clock-enable, and bus contracts.
- Look for undocumented robustness cases revealed by RTL review.
- Record explicit non-goals and assign interface behavior to the owning block.
- Flag specification/RTL/test disagreements as resolution-gated rows. Do not invent an
  expected result when the contract is unresolved.

### 4. Classify existing evidence

Use these status rules consistently:

- `✅ done` — the named current test/property directly checks the stated behavior and has
  credible pass evidence. Cite a known target/commit only when it exists in repository
  evidence. **A leg marked `fail_ok: true` in `sim-ci-targets.yaml` is not passing** — do not
  mark its rows done.
- `🟨 partial` — relevant evidence exists but does not close the row, is integration-only
  where cycle-level proof is missing, or is stale and needs a current rerun.
- `⬜ new` / `⬜ planned` — no adequate current test or signoff evidence exists.
- `⚠️ spec/RTL issue` — expected behavior must be resolved before the test can be finalized.
- `ANALYSIS` / `INTERFACE` — use only where the requirement is legitimately satisfied by
  analysis, construction, or another block.

Do not mark a requirement done merely because a test writes or reads the associated register.
State the observable pass criterion.

### 5. Write the plan

Follow the referenced template and the style of the existing block plans under
`docs/hardware/verification/blocks/`.

Include:

1. DUT, scope, and exact inputs reviewed.
2. Current methodology and honest closure gaps.
3. A functional-coverage / constrained-random strategy tied to identified axes.
4. A numbered test table with test, type, testbench, requirement/gap, and status.
5. Directed closure order that resolves contract issues before writing tests.
6. Exact runnable regression commands using current paths — `fusesoc run --no-export
   <target>` against the block's core (see the block-regression skill and
   `.github/sim-ci-targets.yaml`).
7. Explicit non-goals and interface boundaries.

Keep each row atomic enough to have one clear pass criterion. Retain directed tests after
randomization; close on coverage or documented waivers, not seed count.

### 6. Validate

1. Cross-check every requirement ID and register address against its source in the Schematic
   Review / spec **and** against `hw/rtl/`.
2. Confirm every named test function/file exists and actually exercises the claimed behavior.
3. Confirm commands reference current FuseSoC cores/targets and required environment.
4. Run `git diff --check` on the new plan.
5. Run lightweight available validation where useful (e.g. `fusesoc run --no-export
   --target=lint` on the block). If a simulator is unavailable, say so; do not claim a run.
6. Report the created files and the most important surfaced gaps.

## Guardrails

- Do not modify RTL, tests, specifications, or traceability unless the user also requested
  implementation or reconciliation.
- Do not copy historical "done" claims without repository evidence; a `fail_ok` leg is not
  done.
- Do not require deterministic reset values from intentionally resetless storage.
- Do not confuse RTL simulation at a target frequency with STA/signoff closure.
- Do not hide interface conflicts under a broad "integration test" row.
- Quote the Schematic Review / spec accurately when citing it; do not weaken SHALL language.
- Remember which blocks are stubbed/unwired (SPI Master and QSPI hold `ahb_stub_slave` in
  `periph_ss`; the macro RAM is not yet integrated) — a plan for those must say so, not
  describe them as live.
