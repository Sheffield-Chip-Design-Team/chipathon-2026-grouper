# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

GrouperSoC is an entry for the 2026 Chipathon — an open-source chip design event where teams design blocks that are integrated onto a shared GF180MCU die and fabricated by wafer.space.

The SoC is a `picorv32` (RV32IM) CPU with an AHB-Lite bus fabric and a small set of AHB peripherals. Five peripheral building blocks are being defined, designed, and verified for this entry:

- UART (implemented — see `hw/rtl/uart/`)
- SPI Slave
- SPI Master
- QSPI
- GPIO Mux

CPU memory is a unified 4 KiB SRAM built from four `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros (1024 × 8-bit words each, with byte/bit write enables) — see `ip/gf180mcu_ocd_ip_sram/` (vendored as a git submodule).

The current top level (`picorv32_hello_top` / `picorv32_hello_core`) is a bring-up SoC: CPU + AHB-Lite fabric + ROM + RAM + UART only. SPI S/M, QSPI, and GPIO Mux are not yet wired into `periph_ss`/`ahb_interconnect` — that integration is part of the outstanding work.

## Commands

Simulation uses [FuseSoC](https://github.com/olofk/fusesoc) + Verilator, driven by `grouper_soc.core`.

```bash
# one-time environment setup
python3 -m venv .env
source .env/bin/activate
pip install --upgrade pip
pip install -r sim-requirements.txt

# register this repo and the picorv32 core library with fusesoc
fusesoc library add grouper_soc .
fusesoc library add https://github.com/Sheffield-Chip-Design-Team/picorv32
fusesoc library update picorv32

# run the top-level testbench (picorv32_hello_tb, SystemVerilog, Verilator 5+ required in PATH)
fusesoc run --no-export --target=tb_top grouper_soc
```

There is only one FuseSoC target defined today (`tb_top`, toplevel `picorv32_hello_tb`) — per-peripheral RTL sims are run directly against the block testbenches (e.g. `hw/tb/uart_wtb.sv`) rather than through FuseSoC.

Firmware images consumed by the ROM (`hw/rtl/rom/ahb_rom.sv`, default `code.hex`/`code.vmem`, overridable via `` `PROG_FILE_HEX``/`` `PROG_FILE_VMEM` `` defines) live in `sw/`.

### Block-level DV (cocotb + pyuvm)

`hw/dv/` contains pyuvm-style UVCs (`hw/dv/uvc/ahb3lite`, `hw/dv/uvc/uart`) and per-block test suites (`hw/dv/ahb_uart`, `hw/dv/ahb_reg_block`) built on cocotb. There is no committed Makefile/runner or `requirements.txt` for this flow yet — tests must be wired into whatever cocotb-compatible simulator invocation you already use (set `COCOTB_TEST_MODULES` to the relevant `tests/*.py` module). Check `hw/dv/ahb_uart/README.md` for the one documented example before assuming a run pattern for a new block.

## Architecture

```
picorv32_hello_top (pads: sysclk, reset_btn_n, uart_tx, uart_rx)
  └─ picorv32_hello_core
       ├─ cpu_ss           picorv32 core + native-memory-interface → AHB-Lite master bridge
       └─ periph_ss        AHB-Lite interconnect + peripheral slaves
            ├─ ahb_interconnect  (address decode + response mux)
            ├─ ahb_rom
            ├─ ahb_ram
            └─ ahb_uart          (wraps hw/rtl/uart/{uart.sv,uart_tx.sv,uart_rx.sv,uart_clk_div.sv})
```

- `cpu_ss` (`hw/rtl/cpu/cpu_ss.sv`) instantiates `picorv32` with `ENABLE_MUL`/`ENABLE_DIV`/`ENABLE_IRQ`, no barrel shifter, no compressed ISA, `PROGADDR_RESET=0x0`, `PROGADDR_IRQ=0x10`. It hand-converts picorv32's native `mem_*`/`mem_la_*` memory interface into AHB-Lite (`HADDR`/`HTRANS`/etc signals) — there is no PCPI coprocessor attached. picorv32 is the sole AHB-Lite master; the fabric is single-master, no arbitration needed.
- `periph_ss` (`hw/rtl/periph/periph_ss.sv`) owns the `ahb3lite_intf` SystemVerilog interfaces for each slave and instantiates `ahb_interconnect` plus each peripheral. A `DEBUG_PERIPH` ifdef adds a fourth slave (`ahb_debug`).
- Address decode lives in `hw/rtl/interconnect/ahb_interconnect.sv` (currently ROM `0x0000_0000`–`0x7fff_ffff`, RAM `0x8000_0000`–`0x8fff_ffff`, UART `0x9000_0000`–`0x9000_000f`, Debug `0xf000_0000`–`0xffff_ffff` under `DEBUG_PERIPH`). New peripherals (SPI S/M, QSPI, GPIO Mux) will need a slave port added to `ahb_interconnect`/`periph_ss` and an address range carved out here.
- `hw/rtl/ahb3lite/` defines the shared `ahb3lite_intf` interface and `ahb3lite_pkg` (transfer-type constants, byte-select helpers used by memory-mapped slaves like `ahb_ram`/`ahb_rom`).
- `hw/rtl/common/` holds small reusable building blocks (clock dividers/gating, synchronizers, FIFO, shift register, downcounter) intended for reuse across the new peripherals.
- `hw/rtl/reg_blk/ahb_reg_blk.sv` is a generic parameterized AHB register block (`NUM_REGS`), likely the base for peripheral CSR blocks.
- `ip/gf180mcu_ocd_ip_sram/` is a separate git repo (Open Circuit Design's experimental 3.3 V GF180MCU SRAM macros) vendored as a submodule — this is the macro family backing the 4 KiB CPU SRAM plan (`sram1024x8m8wm1` × 4). `hw/rtl/sram/ahb_ram.sv` in the current bring-up top is a behavioral `logic [] memory []` array, not yet the hardened macro.

## Planning docs caveat

`planning/` is inconsistent and should be treated cautiously — cross-check anything you read there against the actual RTL before relying on it:

- A handful of files (`planning/Hardware/UART.md`, `AHB-Lite Bus.md`) are legitimate but mostly-empty GrouperSoC stubs (owner/status/TODO placeholders) — they explicitly reference "GrouperSoC" and this project's `CPU_RESET`/unified-4kB-SRAM plan.
- Most of the larger docs (`System Architecture.md`, `Hardware/Grouper-SoC-Specification.md`, `Register Map.md`, `SoC Memory Strategy.md`, `Work Allocation.md`, `DFT.md`, `Test Plan.md`, `Hardware/RAM wrapper.md`) describe a different, unrelated chip — a 4-antenna MIMO LoRa-gateway DSP ASIC ("Trouper": ΣΔ decimators, Schmidl-Cox correlator, SX1257 AFEs, PSRAM replay buffer, 544 KB baseband SRAM, etc. — none of which exists in this repo's RTL). `Grouper-SoC-Specification.md` is even internally titled "Trouper DSP Chip Specification".
- Several files under `planning/Hardware/` also have filename/content mismatches (e.g. `GPIO.md`'s body is the SPI Master spec, `QSPI.md`'s body is also the SPI Master spec) — apparent copy/paste errors from templating.

Do not use register addresses, memory maps, or block descriptions from these contaminated docs as ground truth for GrouperSoC — verify against `hw/rtl/`, `grouper_soc.core`, and `hw/dv/` instead.
