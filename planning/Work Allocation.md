# Work Allocation Summary

This note turns the block specs into assignable workstreams. The intent is to make it obvious who can own what, where the subblocks are, and what each lane must deliver.

## 1. SoC Architecture

- Boot flow
- Memory Map
- Debug System
- Bus Arbritration Scheme
 

## 2. SoC RTL
 
Blocks:

- `AHB-Lite Bus`
- `SPI Slave`
- `SPI Master`
- `IRQ Controller`
- `Status Register Bank`
- `SWD TAP`

Subblocks:

- custom PicoRV32-to-AHB-Lite wrapper/master side
- slave decode and register access
- SPI transaction sequencing
- IRQ latch/clear path
- debug access path

Responsibilities:

- keep the control plane coherent and easy to debug
- support firmware load and register access
- surface status, IRQs, and control safely
- avoid bus contention and wait-state bugs

Deliverables:

- AHB-Lite wrapper and interconnect
- clean register read/write path
- interrupt handling path
- debug access for bring-up

## 3. Firmware / Algorithms

Blocks / notes:

- `PicoRV32 RV32IM integration`
- `AGC`
- `MIMO Algorithms`

Subblocks:

- W computation for `NT=1` and `NT=2`
- AGC loop
- branch enable / disable policy
- IRQ handling and packet-state control
- branch-health / fallback policy
- algorithm selection and adaptation policy

Responsibilities:

- own the control-policy layer
- decide when to trust MRC, EGC, SC, or bypass
- manage per-antenna gain and health state
- keep the firmware logic feasible on PicoRV32

Deliverables:

- firmware control loop
- AGC convergence behavior
- algorithm-comparison results
- in-the-loop control policy

## 4. Verification

Blocks / notes:

- `Test Plan`
- cocotb directed block tests (using pyuvm drivers)
- pyuvm style top-level verification

Subblocks:
- block-level testbenches
- end-to-end packet regressions
- RTL-vs-Python comparison
- register and handoff verification
- AFE capture-path testing
- in-the-loop checks

Responsibilities:
- prove the implementation matches the spec
- catch packet handoff, fixed-point, and bus bugs early
- keep the FPGA tests staged and focused

Deliverables:
- block test coverage
- integration simulation
- FPGA bring-up and common-tone AFE characterization

## 9. Physical Design

Blocks / notes:
- Trial Synthesis
- SRAM
- floorplan / P&R

Subblocks:
- SRAM macro 
- area/timing/power closure
- clock distribution
- placement constraints

Responsibilities:
- Validate Tim Edwards's SRAM 
- keep the design within timing and area budgets
- feed back implementation constraints to the RTL owners

Deliverables:
- workable SRAM macro strategy
- floorplan-ready estimates
- timing-risk reduction

## Assignment Rule

For each workstream, assign one owner who is accountable for the block/spec closure and one reviewer who is accountable for cross-checking interfaces with adjacent workstreams.
