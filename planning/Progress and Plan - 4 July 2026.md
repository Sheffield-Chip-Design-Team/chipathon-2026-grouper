# Grouper SoC — Progress & Plan

**Dated:** 4 July 2026
**Deadline:** 15 August 2026 (6 weeks from this document's date) — all tasks, including physical design/GDS, must close by then.

**Note on dating:** this document is written as a rolling plan anchored to 4 July. It is being compiled on 14 July — ten days (end of Week 2) into the six-week window — so Weeks 1–2 below reflect what has actually landed (per git history and the current LibreLane checkpoint), and Weeks 3–6 are the forward plan. This supersedes the stale schedule in [Gantt.md](Gantt.md), whose milestones (Phase 2 close 30 Jun, design review 1 Jul, FPGA validation 10 Aug, GDS freeze 1 Sep) no longer match reality — a 1 Sep tapeout target does not fit a 15 Aug deadline, and physical-design work is now well ahead of where that Gantt assumed.

**Sources used:** [Grouper SoC Specification](Hardware/design/Grouper%20SoC%20Specification.md), [Schematic Review](Hardware/Schematic%20Review.md), the 5 block docs under `Hardware/design/blocks/`, the verification plans under `Hardware/verification/`, `Hardware/verification/Grouper SoC Verification Plan.md`, `Software/Bootloader.md`, and the actual RTL/git history in `hw/rtl/` — not the older contaminated planning files (see the Spec's own "Why this document replaces most of the old planning folder" note).

---

## Progress to date (through 14 July)

### Architecture & documentation
- Schematic Review transcribed and treated as the one authoritative source deck.
- `Grouper SoC Specification.md` rebuilt from it (29 Jun), reconciling integration-level requirements (boot sequence, memory map, interconnect, clocking, physical design).
- Discovered and removed a bad planning-folder contamination issue: most of the old `planning/` docs (System Architecture, Register Map, Pinout, DFT, Test Plan, etc.) described an unrelated "Trouper" DSP/LoRa chip, not GrouperSoC — deleted rather than left as false ground truth.
- All 5 block-level design docs (UART, SPI Master, SPI Slave, QSPI, GPIO Mux) and their verification plans now exist with requirement IDs (`GRPR-*`) cross-referenced to verification items (`V-*-STM/CHK/COV`).
- **Open architectural questions surfaced by this review (see Risks below) — none resolved yet:** reset-vector address discrepancy, missing SPI Slave memory-map region, missing L1 fabric register stage, CPU ISA doc/RTL mismatch (RV32EMC vs. actual RV32IM), a three-way clock-frequency conflict (10/16/32 MHz), no pad list, no total area estimate, undefined GPIO Mux pin-sharing scheme.

### RTL / integration
- Bring-up SoC (`picorv32_hello_top` / `picorv32_hello_core`) running: PicoRV32 (RV32IM) + AHB-Lite fabric (L2 decode only, no L1 stage yet) + ROM + RAM + UART.
- UART (owner: Sam) is the only one of the 5 target peripherals actually implemented and wired into `periph_ss` — full register map, FIFOs, break/framing detection, RX synchronizer.
- SPI Master (Thiri), SPI Slave (Safaa), and QSPI (Tristan) are still at "RTL design starting" per the Schematic Review — **no RTL committed for any of the three yet.**
- GPIO Mux has no owner assigned and is pre-RTL, pre-detailed-requirements (still just the "2-stage synchroniser on each input" bullet plus inferred pin-routing role).
- Bootloader (`Software/Bootloader.md`) is an empty stub — no content beyond "TODO."

### Verification
- Block-level DV is real and active for UART only: pyUVM/cocotb AHB3-Lite + UART UVCs, register model, sequences, randomization, coverage, functional bugfixes (13–14 Jul commits).
- SPI Master, SPI Slave, QSPI, GPIO Mux verification plans are written (requirement lists exist) but have no testbench/VIP work started.
- Top-level DV is still the original "hello world" directed test (UART + RAM + ROM + CPU, build-flow smoke test only) — does not yet exercise any of the 4 unimplemented peripherals or the bank-switch reset boot flow.

### Physical design
- **First hardening checkpoint reached:** the bring-up subset (CPU core + RAM) taken through the LibreLane flow, closing at **20 MHz** with **63% utilisation**.
- This is CPU+RAM only — it does not yet include UART (or any other peripheral), the L1 fabric stage, or the target memory map, so it is a proof-of-flow result, not a representative area/timing number for the full chip.
- No pad list, no die-area/placement allocation on the shared multi-team die, no total gate-equivalent estimate (only SPI Master has a GE figure — 1,500–2,000 GE — and it's unconfirmed by synthesis).

---

## What's left to do

### Track 1 — Resolve cross-block blocking decisions (must happen before Track 2 can finish)
These block multiple peripherals simultaneously and should be first:

| Item | Blocks | Decision needed |
|---|---|---|
| System clock frequency | SPI Master (`GRPR-SPIM-010`), QSPI (`GRPR-QSPI-016`) | Pick one number — current RTL default is 10 MHz, SPI M checklist text says divide from 32 MHz, SPI M's own block diagram says 16 MHz |
| Reset vector address | Boot ROM, memory map | `0x0001_0000` (diagram) vs `0x0000_1000` (memory-map table + reset-vector annotation) — table is almost certainly right, needs a sign-off, not just this document's judgment |
| SPI Slave memory-map address | Interconnect decoder, SPI Slave RTL | No row exists in the target memory map; needs a 4 KiB slot assigned (e.g. `0x0000_7000`–`0x0000_7FFF`) |
| CPU ISA label | Interconnect diagram vs. RTL | Diagram says RV32EMC, RTL is actually RV32IM — fix the diagram or change the RTL config, but stop letting them disagree |
| GPIO Mux pin-sharing scheme | SPI Master, SPI Slave, QSPI external IO | Which physical pins are shared, ownership/priority rules, static vs. register-controlled — currently has zero documentation and no owner |

### Track 2 — RTL for the 3 outstanding peripherals + GPIO Mux
- SPI Master (Thiri) — first RTL commit; shift register, FSM (IDLE/CS_SETUP/TRANSFER/DONE), clock divider, MISO latch.
- SPI Slave (Safaa) — first RTL commit; also needs the firmware-load-path-vs-UART-boot relationship clarified first (open question in the block doc — is `fw_ld_*` an alternate boot path, a second-stage loader, or dead from the old design?).
- QSPI (Tristan) — first RTL commit; needs the status-register bit list redefined from scratch (source list is contaminated with Trouper sample-replay signals).
- GPIO Mux — needs an owner, then requirements + RTL, gated on the Track 1 pin-sharing decision.
- L1 fabric register stage — currently doesn't exist (`ahb_ram.sv` decodes directly off L2); needs implementing per `GRPR-SOC-008`.

### Track 3 — Integration
- Wire all 5 peripherals into `ahb_interconnect`/`periph_ss` against the target memory map (today only ROM/RAM/UART/debug are decoded, using a different bring-up address scheme entirely).
- Bank-switch reset PCPI instruction (swap ROM/RAM regions) — not yet implemented; currently no PCPI coprocessor is attached to `cpu_ss` at all.
- Bootloader firmware — presently nonexistent; needs at minimum a UART-load-to-RAM loader before the boot sequence in the spec is real.

### Track 4 — Verification
- Stand up block-level VIP/testbenches for SPI Master, SPI Slave, QSPI, GPIO Mux (UART's is the template to follow).
- Expand the top-level SoC testbench beyond "hello world" to cover all 5 peripherals and the full boot flow (UART load → bank-switch reset → execute from RAM).
- Work through each block's `V-*-STM/CHK/COV` list — several items are explicitly blocked today on Track 1 decisions (e.g. `V-SPIM-CHK-007`, `V-QSPI-CHK-010` blocked on the clock-plan question; `V-SOC-CHK-007` blocked on the missing L1 fabric).

### Track 5 — Physical design
- Harden the full SoC (all 5 peripherals + L1 fabric), not just the CPU+RAM subset, once Track 3 integration lands.
- Re-run LibreLane at whatever frequency Track 1 settles on — the current 20 MHz/63% number is not the final target and utilisation will move once 4 more peripherals are added.
- Produce a pad list and die placement — currently zero documentation exists for this, and it's a hard requirement for a shared multi-team die (wafer.space needs to know where GrouperSoC's pads land relative to everyone else's).
- Roll up a real total area estimate — only SPI Master has a GE figure today; UART, SPI Slave, QSPI, GPIO Mux all need one (from synthesis, not guesswork) before a total can exist.

---

## Suggested week-by-week (4 Jul – 15 Aug)

| Week | Dates | Focus |
|---|---|---|
| 1 (done) | 4–10 Jul | Spec/doc reconciliation; UART DV buildout continues; first LibreLane bring-up run started |
| 2 (done) | 11–17 Jul | Doc cross-referencing finished; UART UVC substantially complete (AHB3-Lite agent, reg model, sequences, coverage); **LibreLane checkpoint: CPU+RAM closes at 20 MHz, 63% util** |
| 3 | 18–24 Jul | Close out all Track 1 decisions (clock freq, reset vector, SPI Slave address, ISA label, GPIO pin-sharing scheme); first RTL for SPI Master + SPI Slave |
| 4 | 25–31 Jul | QSPI RTL; GPIO Mux RTL (owner assigned); L1 fabric stage; begin wiring all 5 peripherals into the interconnect; stand up VIPs for SPI M/S, QSPI, GPIO |
| 5 | 1–7 Aug | Finish full-SoC integration + bank-switch reset + bootloader; expand top-level DV to full boot flow; first GE rollup for all 5 blocks; draft pad list/die placement; begin full-SoC LibreLane hardening |
| 6 | 8–15 Aug | Close timing/area/DRC/LVS on full-SoC physical design; finish verification sign-off against the `V-*` cross-reference tables; final tapeout-readiness review |

## Top risks to the 15 Aug deadline

- **GPIO Mux has no owner and hasn't started.** It's a dependency for 3 of the 4 remaining peripherals' external IO — if it slips, SPI M/S and QSPI can't finalize their pin interfaces either.
- **No pad list yet, on a shared multi-team die.** This isn't purely internal — it depends on coordination with the other Chipathon teams sharing the die, which can't be fully controlled on this schedule.
- **Three peripherals + GPIO Mux need to go from zero RTL to integrated + verified + hardened in 6 weeks**, alongside resolving 5 blocking architectural decisions first. Track 1 needs to close in days, not weeks, or Track 2–5 have no floor to start from.
- **20 MHz/63% util is not representative of the final chip** — it's CPU+RAM only. Frequency and area could both move once the other 4 blocks land, which is a real risk to the Week 6 physical-design close.
