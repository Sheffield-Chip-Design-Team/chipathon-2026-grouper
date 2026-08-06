# Grouper SoC Verification Plan

**Design doc:** [Grouper SoC Specification](../Hardware/design/Grouper%20SoC%20Specification.md)
**Source:** [Schematic Review](../Hardware/Schematic%20Review.md) §5 "Verification Summary" — top-level testbench architecture.
**Scope:** Integration-level verification only — CPU, interconnect (L1/L2 fabric), ROM/RAM, boot sequence, memory map, clocking/reset. Peripheral-internal verification lives in the block plans under [`blocks/`](blocks/): [UART](../Hardware/verification/blocks/UART%20Verification%20Plan.md), [GPIO Mux](../Hardware/verification/blocks/GPIO%20Mux%20Verification%20Plan.md), [SPI Master](../Hardware/verification/blocks/SPI%20Master%20Verification%20Plan.md), [SPI Slave](../Hardware/verification/blocks/SPI%20Slave%20Verification%20Plan.md), [QSPI](blocks/QSPI%20Verification%20Plan.md).

---

## Testbench Architecture

Per the Schematic Review's top-level testbench diagram:

```
                    ┌─────────────────────────┐
                    │  Clock + Reset Control   │
                    │  Interrupt Checker /     │
                    │  Interrupt Interface     │
                    └───────────┬─────────────┘
                                │
┌──────────────┐    ┌──────────▼──────────┐    ┌──────────────────┐
│  External    │    │      Core SoC        │    │  SPI S / SPI M /  │
│  AHB-Lite    │◄──►│  SRAM, Bootloader ROM,│◄──►│  QSPI / UART      │
│  Interface   │    │  PicoRV32 CPU,        │    │  each with own    │
│  (AHB VIP,   │    │  Memory Bus / L1      │    │  block VIP,       │
│   passive)   │    │  Fabric, AHB-Lite     │    │  routed through   │
└──────────────┘    │  Decoder / L2 Fabric  │    │  GPIO IO MUX +    │
                     └───────────────────────┘    │  MUX CTRL         │
                                                    └──────────────────┘
```

The core SoC (SRAM + boot ROM + CPU + L1/L2 fabric) is **not** individually VIP-wrapped — it's verified as a unit via the top-level directed test plus the checks below, consistent with the block-scope decision documented in [Grouper SoC Specification](../Hardware/design/Grouper%20SoC%20Specification.md). Each of the 5 peripherals reuses its own block-level VIP (see the block plans) rather than a separate top-level-only VIP.

**Existing infrastructure:** `hw/tb/picorv32_hello_tb.sv` + the `tb_top` FuseSoC target (`grouper_soc.core`, run via `fusesoc run --target=tb_top grouper_soc`) is the current top-level directed testbench — a "hello world" test exercising UART, RAM, ROM, and CPU, and validating the software build flow. This plan extends that test rather than replacing it.

## Verification Components Needed

| Component | Status | Notes |
|---|---|---|
| Clock + Reset Control | **Exists**, informally — `hw/tb/picorv32_hello_tb.sv`'s `reset()` task and clock generator | Formalize into a reusable component if/when this testbench grows beyond one directed test. |
| Interrupt Checker / Interrupt Interface | **Missing** | GrouperSoC's IRQ sources (`uart_rx_irq`, `uart_rx_error_irq` today, more as SPI/QSPI/GPIO land — see `hw/rtl/cpu/cpu_ss.sv`'s `NUM_IRQ` parameter) need a checker confirming each source reaches the CPU's `irq` input correctly and at the right priority/masking behavior. |
| External AHB-Lite Interface (AHB VIP, passive) | **Exists** — `hw/dv/uvc/ahb3lite/` (`is_active=False` mode already supported per `ahb3lite_agent.py`) | Reuse in passive mode to observe/checkpoint internal bus traffic during the top-level test, per the Schematic Review's diagram. |
| Per-peripheral VIPs | **Partial** — UART exists (`hw/dv/uvc/uart/`); SPI/QSPI/GPIO don't yet | Reuse the block-level VIPs being built per the block verification plans — do not duplicate them at the top level. |
| GPIO IO MUX + MUX CTRL routing checker | **Missing**, blocked | Depends on the [GPIO Mux](../Hardware/design/blocks/GPIO%20Mux.md) pin-sharing scheme being defined first. |
| Scoreboard(s) | **Missing** | Top-level scoreboard needs: boot-flow state tracking (ROM→RAM bank-switch), memory-map address-decode correctness, and IRQ aggregation correctness. |

## Traceability Matrix

| Verification Item | Type | Description | Req ID | Test / Component |
|---|---|---|---|---|
| `V-SOC-STM-001` | Stimulus | Assert power-on-reset, release, observe first fetch | `GRPR-SOC-001` | Extend `picorv32_hello_tb` |
| `V-SOC-CHK-001` | Check | First instruction fetch address equals the resolved reset vector (`0x0000_1000`, pending the address-discrepancy open item) | `GRPR-SOC-001` | Scoreboard |
| `V-SOC-STM-002` | Stimulus | Drive a known program image over UART into the boot ROM's load path | `GRPR-SOC-002` | Extend `picorv32_hello_tb`, reuse UART VIP |
| `V-SOC-CHK-002` | Check | RAM contents match the transmitted image byte-for-byte after load completes | `GRPR-SOC-002` | Scoreboard |
| `V-SOC-STM-003` | Stimulus | Execute the Bank Switch Reset PCPI instruction from a running program | `GRPR-SOC-003` | New directed test |
| `V-SOC-CHK-003` | Check | ROM and RAM regions are swapped in the address map immediately after the instruction executes | `GRPR-SOC-003` | Scoreboard |
| `V-SOC-CHK-004` | Check | CPU fetches and executes correctly from RAM post-swap (continuation of `V-SOC-STM-002`/`003`) | `GRPR-SOC-004` | Scoreboard |
| `V-SOC-STM-004` | Stimulus | Exercise SPI Master/QSPI-based external storage access from a running program, both immediately post-boot and via NOR-flash boot-bypass | `GRPR-SOC-005` | Coordinate with [SPI Master](../Hardware/verification/blocks/SPI%20Master%20Verification%20Plan.md) and [QSPI](blocks/QSPI%20Verification%20Plan.md) plans |
| `V-SOC-CHK-005` | Check | Both storage-access paths behave per `GRPR-SOC-005` | `GRPR-SOC-005` | Scoreboard, coordinated with block-level scoreboards |
| `V-SOC-STM-005` | Stimulus | Sweep every address in and around each memory-map region (ROM, RAM, UART, GPIO CTRL, QSPI, SPI M, external peripheral), including boundary and unmapped addresses | `GRPR-SOC-006` | New directed test — full address-decode sweep |
| `V-SOC-COV-001` | Coverage | Every memory-map region hit at least once at its low, high, and mid address; every unmapped gap hit at least once to confirm defined (error) behavior | `GRPR-SOC-006` | Coverage collector |
| `V-SOC-CHK-006` | Check | Interconnect behaves as a single-master, 2-level structure — no arbitration logic present/needed, confirmed by inspection + absence of contention scenarios in simulation | `GRPR-SOC-007` | Scoreboard / static check |
| `V-SOC-CHK-007` | Check | L1 register-stage timing/behavior between CPU and RAM | `GRPR-SOC-008` | **Blocked** — L1 fabric not yet implemented in RTL; write this check once it exists |
| `V-SOC-STM-006` | Stimulus | Drive back-to-back AHB transactions to multiple peripherals in sequence and interleaved | `GRPR-SOC-009` | New directed + randomized test |
| `V-SOC-CHK-008` | Check | L2 decoder routes each transaction to the correct peripheral with no misrouting or lost transactions | `GRPR-SOC-009` | Scoreboard, passive AHB VIP |
| `V-SOC-CHK-009` | Check | PicoRV32 is the sole bus master; no other master-capable signals ever assert `HTRANS`/drive the bus | `GRPR-SOC-010` | Passive AHB VIP monitor, static check |
| `V-SOC-CHK-010` | Check | System clock frequency matches the resolved clock plan | `GRPR-SOC-011` | **Blocked** — depends on the unresolved clock-plan open item (see design doc) |
| `V-SOC-STM-007` | Stimulus | Assert/deassert reset at multiple points during operation (idle, mid-transaction, mid-boot) | `GRPR-SOC-012` | New directed test |
| `V-SOC-CHK-011` | Check | Reset behavior is async-assert/sync-deassert everywhere, and the system reaches a clean, repeatable post-reset state each time | `GRPR-SOC-012` | Scoreboard |

`GRPR-SOC-013`–`GRPR-SOC-016` (physical design requirements) are not covered by functional/simulation verification — they're tracked as synthesis/place-and-route/DRC signoff items outside this plan's scope.

## Suggested Tests

- **Boot-over-UART end-to-end** (`V-SOC-STM-002`/`CHK-002`): extend the existing `picorv32_hello_tb` "hello world" flow into a directed test that loads a known image over UART and checks RAM contents directly, not just observed program behavior.
- **Bank-switch reset correctness** (`V-SOC-STM-003`/`CHK-003`/`004`): directed test executing the PCPI bank-switch instruction and confirming the address-space swap plus continued correct execution from RAM.
- **Full memory-map address-decode sweep** (`V-SOC-STM-005`/`COV-001`): systematically sweep every region boundary in the target memory map, including a directed check at the flagged `0x0001_0000` vs `0x0000_1000` reset-vector discrepancy address once it's resolved.
- **Back-to-back multi-peripheral AHB traffic** (`V-SOC-STM-006`/`CHK-008`): randomized sequence of transactions across all present peripherals, checked by the passive AHB VIP + scoreboard for correct routing and no lost/misrouted transfers.
- **Interrupt aggregation/priority** *(new, once more IRQ sources than UART exist)*: assert multiple IRQ sources simultaneously, confirm the CPU's `irq` vector reflects all of them correctly per `hw/rtl/cpu/cpu_ss.sv`'s bit mapping (timer / bus-error / external sources).
- **GPIO mux routing correctness end-to-end** *(blocked)*: once the GPIO Mux pin-sharing scheme is defined, a top-level test exercising each peripheral's pins through the shared physical pads and confirming no cross-peripheral interference.
- **Reset-at-arbitrary-point stress** (`V-SOC-STM-007`/`CHK-011`): reset injected at random points across a running test sequence (idle, mid-AHB-transaction, mid-boot-load), confirming clean recovery every time.

## Open Items

- `V-SOC-CHK-007` (L1 fabric) blocked — the L1 register stage doesn't exist in RTL yet.
- `V-SOC-CHK-010` (clock frequency) blocked on the unresolved system clock plan.
- GPIO mux routing verification blocked on the undefined pin-sharing scheme.
- No top-level scoreboard exists yet — needed for boot-flow, address-decode, and IRQ-aggregation checks.
- No committed cocotb runner/Makefile beyond the existing FuseSoC `tb_top` Verilator flow (see the top-level `CLAUDE.md`) — the pyuvm/cocotb block-level flows and this SystemVerilog-testbench top-level flow are not yet unified into one runner.
