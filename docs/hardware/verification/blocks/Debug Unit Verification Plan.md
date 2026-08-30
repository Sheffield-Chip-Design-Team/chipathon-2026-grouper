# Debug Unit Verification Plan

**Design doc:** [Debug Unit](../../design/blocks/Debug%20Unit.md)
**DV status:** No RTL, no VIP, no tests exist yet. The design document is specification only.

---

## Directed Verification

No bench exists yet — the block has no RTL. This section plans the **directed
cocotb bench** so it can be built alongside the RTL rather than retrofitted,
and so the split against the MDV flow below is deliberate from the start.

Planned wiring, following the pattern of the other blocks:

```bash
source .env/bin/activate
fusesoc run ahb_debug_unit_directed
```

- **Bench:** `hw/tb/debug/test_debug_unit.py`
- **Core:** `hw/tb/debug/debug_unit_directed.core` (`sharc:soc_ip:ahb_debug_unit_directed`), toplevel `ahb_debug_unit`
- **Bus helpers:** `hw/tb/tb_utils/ahb_utils.py` for the subordinate port
- **New helpers needed:** a debug-port driver, an AHB subordinate model that can
  stall and error on demand, and the CPU stub described below

Items are numbered `V-DBG-DIR-NNN`, a separate series from the `STM`/`CHK`/`COV`
items so directed coverage stays traceable on its own. **All are currently
unimplemented**; the Test column names the test that should exist.

Register the leg in `.github/sim-ci-targets.yaml` as `ahb_debug_unit_directed`
with `fail_ok: false` from the outset. This block can halt the CPU and corrupt
memory accesses, so a silently failing leg is worse here than anywhere else in
the design.

### `GRPR-DBG-002` / `-028` / `-037` / `-038` — register map and software visibility

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-DBG-DIR-001` | `test_register_decode` | Each of the ten registers is distinct and at its specified offset | `-002`, `-028` |
| `V-DBG-DIR-002` | `test_reset_values` | Every register reads its specified reset value, with the debug strap low | `-002` |
| `V-DBG-DIR-003` | `test_ctrl_bit_readback` | Each `CTRL` field written and read back independently | `-002` |
| `V-DBG-DIR-004` | `test_status_w1c` | The four sticky bits set, survive a read, and clear only on write-1 | `-002`, `-037` |
| `V-DBG-DIR-005` | `test_readonly_writes_rejected` | Writes to `STATUS`'s RO bits and to the capture registers are rejected with a two-cycle error response | `-002` |
| `V-DBG-DIR-006` | `test_post_mortem_readback` | Run a session that sets each sticky bit and populates the captures, release, then reconstruct it from registers alone. **The only view firmware ever gets**, since the CPU is halted during a session | `-037` |
| `V-DBG-DIR-007` | `test_regs_readable_with_lock_active` | The subordinate port answers CPU reads with a lock active but the CPU running, and reads are never gated on `DBG_EN`/`LOCK_EN` | `-038` |

### `GRPR-DBG-006` … `-009` — ownership and handover

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-DBG-DIR-008` | `test_lock_and_release` | A lock is taken and released with no other traffic; ownership and status bits track | `-007`, `-013` |
| `V-DBG-DIR-009` | `test_lock_refused_when_disabled` | A lock with `LOCK_EN` = 0, and a second lock while one is active, are both refused with `STATUS.REJECTED` and leave ownership undisturbed | `-007` |
| `V-DBG-DIR-010` | `test_handover_atomicity_sweep` | **The highest-value test in this plan.** Request a lock at every cycle offset relative to an in-flight CPU transfer — on both the AHB and RAM paths, and against a subordinate stretching `HREADY`. The CPU transfer must complete with correct data and no retry | `-009` |
| `V-DBG-DIR-011` | `test_ownership_exclusive` | Always-on assertion: the CPU and debug sources never both drive a non-IDLE `HTRANS` or an active RAM strobe in the same cycle | `-006`, `-008` |
| `V-DBG-DIR-012` | `test_release_waits_for_transfer` | A release during an outstanding debug transfer completes that transfer first | `-013` |
| `V-DBG-DIR-013` | `test_release_needs_no_cpu` | A release is accepted and completes with the CPU halted throughout, proving it does not depend on any CPU or AHB access | `-013` |

> `V-DBG-DIR-011` is cheap and belongs in *every* test, not just its own. It
> catches the class of bug directed stimulus misses, and it is the one property
> whose violation corrupts CPU memory accesses.

### `GRPR-DBG-010` … `-012`, `-017` — addressing and transfers

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-DBG-DIR-014` | `test_address_map_equivalence` | The same address from the debug port and from the CPU stub reaches the same target, under both bank-switch settings | `-010` |
| `V-DBG-DIR-015` | `test_reach_all_targets` | Sweep ROM, RAM, the bank-switch register, and every AHB peripheral window — the requirement that any peripheral can be driven arbitrarily | `-011` |
| `V-DBG-DIR-016` | `test_multibeat_ascending` | Multi-beat transfers of 2, 4 and N beats access consecutive ascending addresses, including one crossing a decode boundary | `-012` |
| `V-DBG-DIR-017` | `test_bus_error_capture` | An error response and an unmapped address each set `STATUS.BUS_ERR`, capture address and cause, return `dbg_rsp_err`, and **retain the lock** | `-017` |

### `GRPR-DBG-014` … `-016` — persistence, reset, watchdog

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-DBG-DIR-018` | `test_lock_survives_transport_events` | A lock persists across the transport's chip-select deassertion and unrelated traffic | `-014` |
| `V-DBG-DIR-019` | `test_reset_sweep` | Reset at idle, mid-lock, mid-transfer and mid-step releases the lock, clears debug state, and — critically — leaves the CPU's freeze and reset inputs deasserted so the CPU is never stranded | `-015`, `-033` |
| `V-DBG-DIR-020` | `test_watchdog_fires_when_idle` | A lock idle past `CTRL.TIMEOUT` auto-releases and sets `STATUS.TIMEOUT` | `-016` |
| `V-DBG-DIR-021` | `test_watchdog_restarts_on_activity` | A lock kept busy with periodic transfers does not time out | `-016` |

### `GRPR-DBG-019` … `-021` — lockout flavours

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-DBG-DIR-022` | `test_freeze_preserves_state` | PC and register file identical before and after a freeze-style lock; execution resumes at the stalled instruction | `-019`, `-020` |
| `V-DBG-DIR-023` | `test_reset_flavour_restarts` | A reset-style lock restarts the CPU at its reset vector on release | `-019`, `-020` |
| `V-DBG-DIR-024` | `test_lock_mode_latched` | `CTRL.LOCK_MODE` is sampled at entry; changing it mid-lock has no effect, and `STATUS.LOCK_MODE_ACT` reports the latched value | `-019` |
| `V-DBG-DIR-025` | `test_bank_switch_refused_in_freeze` | A bank-switch write during a freeze is refused with `STATUS.BUS_ERR` and does not reset the CPU | `-021` |

### `GRPR-DBG-022` … `-027` — CPU debug access

| Item | Test | What it does | Req |
|---|---|---|---|
| `V-DBG-DIR-026` | `test_debug_ops_gated` | Every debug operation is refused with `DBG_EN` = 0, and refused while the CPU is running | `-022` |
| `V-DBG-DIR-027` | `test_state_read_pc_and_regs` | PC and each GPR read back correctly, stable across repeated reads, unaffected by the read itself | `-023`, `-029` |
| `V-DBG-DIR-028` | `test_state_read_bad_selector` | A selector outside the table is refused with `dbg_rsp_err`; `0x10`–`0x1F` cover x0–x15 only on this RV32E core | `-023` |
| `V-DBG-DIR-029` | `test_trace_record_capture` | The trace record and its valid bit track the most recent retirement; valid clears on resume | `-024` |
| `V-DBG-DIR-030` | `test_step_counts` | Steps of 1, 2, 255 and 0 retire exactly the requested count (0 treated as 1), return to halted, and set `STATUS.STEP_DONE` | `-025` |
| `V-DBG-DIR-031` | `test_no_redirect_operation` | Debug-port command `4'h8` and the vacated SPI opcode are refused, and CPU execution flow is unchanged | `-026` |
| `V-DBG-DIR-032` | `test_resume_leaves_lock` | Resume clears `STATUS.CPU_HALTED` and leaves `STATUS.LOCK_ACTIVE` set — resuming and releasing are separate operations | `-027` |

### The CPU stub

Most of the rows above depend on a CPU stub, which is the component this bench
most depends on and the one worth building first. It must issue AHB and RAM
transfers on command, respond to `cpu_freeze` and `cpu_rst_req`, retire
instructions on demand so `cpu_retire` means something, and expose a PC and a
register-file read port.

A real picorv32 is deliberately **not** the right DUT companion for most of
these. `V-DBG-DIR-010` needs a CPU that can be told "start a transfer and hold
it outstanding for N cycles", which a real core will not do on request. Use the
real `cpu_ss` for the SoC-level test only.

### Requirements deliberately not in this section

- `GRPR-DBG-004` (no arbitration between debug sources) — a negative
  requirement with no second source to drive. Verified by review and
  elaboration; a test that cannot fail would be worse than none.
- `GRPR-DBG-030` / `-031` (no port-count parameter, widths match the fabric) —
  elaboration properties.
- `GRPR-DBG-032` / `-033` (single clock domain, reset style) — structural,
  established by inspection and CDC lint.
- `GRPR-DBG-034` … `-036` (latency bounds) — measurable in the directed bench,
  but they are performance targets rather than functional behaviour and belong
  with the timing checks in the MDV matrix.

### What this bench does not attempt

No functional coverage collection, no constrained randomisation, no reference
model, and no SoC-level integration. The alternate-boot acceptance test in
particular belongs in `hw/tb/top/` against the real CPU, not here.

## MDV Testbench Architecture

The block has four interfaces, and a testbench has to drive or model all of
them. That is the main thing distinguishing this plan from the peripheral
plans: the DUT is a bus **manager**, so the testbench must provide
subordinates for it to talk to, and it controls the CPU, so the testbench must
model a CPU well enough for halt, step, and resume to mean something.

```
   ┌────────────────┐  debug port   ┌──────────────┐  m_* AHB   ┌──────────────┐
   │ Debug-port     │──────────────▶│              │───────────▶│ AHB3Lite     │
   │ driver (new)   │◀──────────────│              │            │ subordinate  │
   └────────────────┘               │  Debug Unit  │            │ model        │
   ┌────────────────┐  s_* AHB      │    (DUT)     │  ram_*     └──────────────┘
   │ AHB3Lite Agent │◀─────────────▶│              │───────────▶┌──────────────┐
   │ (exists)       │               │              │            │ RAM model    │
   └────────────────┘               │              │            └──────────────┘
   ┌────────────────┐  cpu_*        │              │
   │ CPU stub       │◀─────────────▶│              │
   │ (new)          │               └──────┬───────┘
   └────────────────┘                      │
                              ┌────────────▼────────────┐
                              │       Scoreboard        │
                              └─────────────────────────┘
```

**The CPU stub is the interesting new component.** It must model enough of
`cpu_ss` to exercise the requirements: issue AHB and RAM transfers, respond to
`cpu_freeze` and `cpu_rst_req`, retire instructions on demand so `cpu_retire`
means something for step counting, and expose a program counter and a
register-file read port. A full picorv32 is *not* required for most tests and
would make the atomicity tests (`V-DBG-STM-005`) much harder to control — a
stub that can be told "start a transfer and hold it outstanding for N cycles"
is what those need. A separate integration test at SoC level should use the
real CPU.

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| AHB3Lite Agent | **Exists** — `hw/dv/uvc/ahb3lite/` | Reuse for the subordinate port (register access). May also serve as the manager-side monitor on `m_*`. |
| AHB3Lite subordinate model | **Missing — new** | A target for debug-sourced transfers. Must be able to insert wait states and return an error response on demand (`V-DBG-STM-012`). |
| RAM model | **Partly exists** — `hw/tb/models/` holds an SRAM model | A fixed single-cycle target on the `ram_*` port, matching `ram_ss`'s no-handshake behaviour. |
| CPU stub | **Missing — new** | See above. The component this plan most depends on. |
| Debug-port driver | **Missing — new** | Drives the valid/ready request channel and consumes responses. Transport-agnostic, so it is reusable for any future transport. |
| Scoreboard / reference model | **Missing** | Tracks bus ownership, lock state, and CPU state; checks every transfer reached the right target with the right data. |
| Functional coverage collector | **Missing** | See `V-DBG-COV-*`. |

## MDV Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-DBG-STM-001` | Stimulus | Issue reads and writes on the debug port to every reachable target | `GRPR-DBG-001` | New directed test |
| `V-DBG-CHK-001` | Check | AHB-Lite manager protocol compliance on `m_*` | `GRPR-DBG-001` | AHB agent protocol checks |
| `V-DBG-STM-002` | Stimulus | Register read/write walk of the block's own window | `GRPR-DBG-002` | New directed test |
| `V-DBG-CHK-002` | Check | AHB-Lite subordinate protocol compliance on `s_*`, including a two-cycle error response | `GRPR-DBG-002` | Scoreboard |
| `V-DBG-CHK-003` | Check | Exactly one debug port is present and usable | `GRPR-DBG-003` | Elaboration + directed test |
| `V-DBG-CHK-029` | Check | No selection, priority, or arbitration logic exists between debug sources — a review and elaboration check rather than a stimulus test, since there is no second source to drive | `GRPR-DBG-004` | Review + elaboration |
| `V-DBG-CHK-004` | Check | Request/response handshake is well formed; no second request accepted while one is outstanding | `GRPR-DBG-005` | Protocol assertions |
| `V-DBG-CHK-005` | Check | **Never two owners.** Assertion that the CPU and debug sources never both drive a non-IDLE `HTRANS` or an active RAM strobe in the same cycle | `GRPR-DBG-006` | Formal or always-on assertion |
| `V-DBG-STM-004` | Stimulus | Request a lock with `LOCK_EN` = 0, and again while a lock is already active | `GRPR-DBG-007` | New directed test |
| `V-DBG-CHK-006` | Check | Both refusals leave ownership undisturbed and set `STATUS.REJECTED` | `GRPR-DBG-007` | Scoreboard |
| `V-DBG-CHK-007` | Check | The non-owning source's `HTRANS` is IDLE and its RAM strobes inactive, in every ownership state | `GRPR-DBG-008` | Assertion |
| `V-DBG-STM-005` | Stimulus | **The atomicity sweep.** Request a lock at every cycle offset relative to an in-flight CPU transfer — on both the AHB and RAM paths, and against a subordinate stretching `HREADY` | `GRPR-DBG-009` | New directed test, the highest-value test in this plan |
| `V-DBG-CHK-008` | Check | The in-flight CPU transfer completes with correct data and no retry; ownership moves only after it does | `GRPR-DBG-009` | Scoreboard |
| `V-DBG-STM-006` | Stimulus | Address the same target from the debug port and from the CPU stub, under both bank-switch settings | `GRPR-DBG-010` | New directed test |
| `V-DBG-CHK-009` | Check | A given address selects the same target either way | `GRPR-DBG-010` | Scoreboard |
| `V-DBG-STM-007` | Stimulus | Sweep ROM, RAM, bank-switch register, and every AHB peripheral window | `GRPR-DBG-011` | Address-sweep test |
| `V-DBG-COV-001` | Coverage | Every decode target reached from the debug port at least once | `GRPR-DBG-011` | Coverage collector |
| `V-DBG-STM-008` | Stimulus | Multi-beat transfers of 2, 4, and N beats, including one crossing a decode boundary | `GRPR-DBG-012` | New directed test |
| `V-DBG-CHK-010` | Check | A release request during an outstanding debug transfer waits for it to complete | `GRPR-DBG-013` | Scoreboard |
| `V-DBG-STM-009` | Stimulus | Deassert the transport's chip select mid-lock; run unrelated transport traffic | `GRPR-DBG-014` | New directed test |
| `V-DBG-STM-010` | Stimulus | Assert reset at multiple points: idle, mid-lock, mid-transfer, mid-step | `GRPR-DBG-015`, `GRPR-DBG-033` | New directed test |
| `V-DBG-CHK-011` | Check | Reset releases the lock, clears debug state, returns ownership, and leaves the CPU's freeze and reset inputs deasserted so the CPU is never stranded | `GRPR-DBG-015`, `GRPR-DBG-033` | Scoreboard |
| `V-DBG-STM-011` | Stimulus | Take a lock and go idle past the watchdog period; separately, keep it active with periodic transfers | `GRPR-DBG-016` | New directed test |
| `V-DBG-CHK-012` | Check | The watchdog releases on the first case and does not on the second; `STATUS.TIMEOUT` set only on the first | `GRPR-DBG-016` | Scoreboard |
| `V-DBG-STM-012` | Stimulus | Target an address that errors, and one that decodes to nothing | `GRPR-DBG-017` | New directed test |
| `V-DBG-CHK-013` | Check | `STATUS.BUS_ERR` set, `BUSADDR`/`BUSERR` capture the right address and cause, `dbg_rsp_err` returned, lock retained | `GRPR-DBG-017` | Scoreboard |
| `V-DBG-CHK-014` | Check | A status command is answered with no lock active, and after a refused lock | `GRPR-DBG-018` | Scoreboard |
| `V-DBG-STM-013` | Stimulus | Take a lock in each flavour; change `CTRL.LOCK_MODE` mid-lock and confirm it does not take effect | `GRPR-DBG-019` | New directed test |
| `V-DBG-COV-002` | Coverage | Both flavours exercised, entered and released | `GRPR-DBG-019` | Coverage collector |
| `V-DBG-CHK-015` | Check | **Freeze:** CPU PC and register file identical before and after; execution resumes at the stalled instruction. **Reset:** CPU restarts at its reset vector | `GRPR-DBG-020` | Scoreboard, CPU stub state compare |
| `V-DBG-STM-014` | Stimulus | Write the bank-switch register from the debug port during a freeze-style lock | `GRPR-DBG-021` | New directed test |
| `V-DBG-CHK-016` | Check | The write is refused, `STATUS.BUS_ERR` set, and the CPU is not reset | `GRPR-DBG-021` | Scoreboard |
| `V-DBG-STM-015` | Stimulus | Issue each debug operation with `DBG_EN` = 0, and with the CPU running | `GRPR-DBG-022` | New directed test |
| `V-DBG-CHK-017` | Check | All are refused with `STATUS.REJECTED`; CPU state untouched | `GRPR-DBG-022` | Scoreboard |
| `V-DBG-STM-016` | Stimulus | Read PC, each GPR, and the trace record; repeat the same read twice | `GRPR-DBG-023` | New directed test |
| `V-DBG-CHK-018` | Check | Values match the CPU stub's state, are stable across repeated reads, and an out-of-range selector returns `dbg_rsp_err` | `GRPR-DBG-023` | Scoreboard |
| `V-DBG-CHK-019` | Check | The trace record and its valid bit track the most recent retirement; valid clears on resume | `GRPR-DBG-024` | Scoreboard |
| `V-DBG-STM-017` | Stimulus | Step 1, 2, 255, and 0 instructions | `GRPR-DBG-025` | New directed test |
| `V-DBG-CHK-020` | Check | Exactly the requested count retires (0 treated as 1), CPU returns to halted, `STATUS.STEP_DONE` set | `GRPR-DBG-025` | Scoreboard |
| `V-DBG-CHK-021` | Check | No arbitrary-redirect operation exists: debug-port command `4'h8` and SPI opcode `0x56` are refused with `dbg_rsp_err`, and CPU execution flow is unchanged by them | `GRPR-DBG-026` | New directed test, negative |
| `V-DBG-CHK-022` | Check | Resume clears `STATUS.CPU_HALTED` and leaves `STATUS.LOCK_ACTIVE` unchanged | `GRPR-DBG-027` | Scoreboard |
| `V-DBG-STM-019` | Stimulus | Read every register in the map over the AHB subordinate port | `GRPR-DBG-028` | New directed test |
| `V-DBG-STM-021` | Stimulus | Run a debug session that sets each sticky bit and populates the capture registers, release the lock, then read everything from firmware | `GRPR-DBG-037` | New directed test |
| `V-DBG-CHK-030` | Check | Sticky `STATUS` bits, `LOCK_MODE_ACT`, and the `BUSADDR`/`BUSDATA`/`BUSERR` capture all survive the release with the values the session produced, and clear only on W1C or reset | `GRPR-DBG-037` | Scoreboard |
| `V-DBG-CHK-031` | Check | The subordinate port answers CPU reads with a lock active but the CPU running, and register reads are never gated on `CTRL.DBG_EN` or `CTRL.LOCK_EN` | `GRPR-DBG-038` | Scoreboard |
| `V-DBG-CHK-023` | Check | Reads have no architectural side effects; a stepped instruction has exactly its own effect | `GRPR-DBG-029` | Scoreboard |
| `V-DBG-CHK-024` | Check | No port-count parameter exists; the block elaborates with exactly one debug port | `GRPR-DBG-030` | Elaboration check |
| `V-DBG-CHK-025` | Check | No clock other than `HCLK` in the block; lint clean for CDC | `GRPR-DBG-032` | Lint + review |
| `V-DBG-CHK-026` | Check | AHB word transfer completes within 4 `HCLK` plus target wait states | `GRPR-DBG-034` | Scoreboard timing check |
| `V-DBG-CHK-027` | Check | RAM word transfer completes within 3 `HCLK` | `GRPR-DBG-035` | Scoreboard timing check |
| `V-DBG-CHK-028` | Check | Handover latency bounded by the longest permitted CPU transfer | `GRPR-DBG-036` | Scoreboard timing check |

## Suggested Tests

Roughly in the order they should be written — each depends on the ones above.

- **Register sanity.** Read/write walk of the block's own window, reset values,
  W1C behaviour on the sticky `STATUS` bits.
- **Post-mortem readback.** Run a session that produces errors, timeouts and a
  step, release, then confirm firmware can reconstruct what happened from the
  registers alone. This is the only view firmware ever gets of a session, since
  the CPU is halted while one is running, so it is worth testing directly
  rather than assuming it falls out of the register walk.
- **Lock and release.** Take and release a lock in each flavour with no other
  traffic; confirm ownership and status bits track.
- **Handover atomicity** (`V-DBG-STM-005`). The highest-value test here, and
  the one most likely to find a real bug: sweep the lock request across every
  cycle offset of an in-flight CPU transfer, on both paths, including against a
  subordinate inserting wait states. A failure here corrupts CPU memory
  accesses, which is the worst failure mode this block has.
- **Ownership exclusivity assertion** (`V-DBG-CHK-005`). Always on, in every
  test. Cheap, and it catches the class of bug that directed tests miss.
- **Address-map equivalence.** The same address from the CPU and from the debug
  port reaches the same target, under both bank-switch settings.
- **Error paths.** Error response, unmapped address, refused commands, and the
  bank-switch-during-freeze case.
- **Watchdog.** Fires when idle, does not fire when active.
- **Reset sweep.** Reset at idle, mid-lock, mid-transfer, mid-step. Confirm the
  CPU is never left frozen or held in reset by a reset of this block.
- **Step and state read.** Step counts of 1, 2, 255, 0; read back PC, GPRs, and
  trace after each.
- **Reserved-encoding refusal.** Confirm the vacated redirect encodings are
  refused cleanly rather than aliasing another operation (`DBG-SPEC-002`).
- **SoC-level alternate boot** — the acceptance test for the whole feature, and
  the one worth running against the real CPU rather than the stub: take a
  reset-style lock over a real transport, write an image into RAM, set the bank
  switch, release, and confirm the CPU executes the loaded image. Belongs in
  the top-level testbench (`hw/tb/top/`) rather than here.

## Open Items

- The CPU stub's fidelity is the main open question. It must be faithful enough
  that `V-DBG-CHK-015` (freeze preserves architectural state) means something,
  while remaining controllable enough for the atomicity sweep. Consider two
  configurations: a controllable stub for the directed tests and the real
  `cpu_ss` for the SoC-level test.
- `GRPR-DBG-004` (no arbitration between debug sources) is a negative
  requirement with no second source to drive, so it is verified by review and
  elaboration rather than by stimulus. That is the honest classification; a
  test that cannot fail would be worse than none.
- The CPU-side hooks this block needs (`cpu_retire`, `cpu_pc`, the register read
  port) do not exist in picorv32 today. Until they do,
  everything from `V-DBG-STM-013` onward can only be tested against the stub.
- Whether the step-retirement indication is `trace_valid` or a dedicated output
  is unresolved (`DBG-SPEC-006`), and it changes what the stub must model.
- No scoreboard, no VIP, no tests exist yet.
- No committed cocotb runner or core file for this block yet; it will need a
  `hw/rtl/debug/ahb_debug_unit.core` and a `hw/tb/debug/` suite registered in
  `.github/sim-ci-targets.yaml`.
