# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

GrouperSoC is an entry for the 2026 Chipathon — an open-source chip design event where teams design blocks that are integrated onto a shared GF180MCU die and fabricated by wafer.space.

The SoC is a `picorv32` (RV32EMC) CPU with an AHB-Lite bus fabric and a small set of AHB peripherals. Five peripheral building blocks are being defined, designed, and verified for this entry:

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

# fetch IP submodules (ip/picorv32, ip/gf180mcu_ocd_ip_sram)
git submodule update --init --recursive

# register this repo with fusesoc; it scans recursively, so ip/picorv32/picorv32.core
# is found without a library entry of its own
fusesoc library add grouper_soc .

# lint the SoC RTL only (fast; the RTL core has no testbench of its own)
fusesoc run --no-export --target=lint grouper_soc

# run the top-level testbench (SystemVerilog, Verilator 5+ required in PATH).
# Note this is grouper_soc_tb, a separate core - `grouper_soc` has no tb_top.
fusesoc run --no-export --target=tb_top grouper_soc_tb
```

Testbenches live in their own cores next to the files they drive: `sharc:soc_ip:grouper_soc_tb` (`hw/tb/top/grouper_soc_tb.core`, targets `tb_top`/`tb_top_debug`) and `sharc:soc_ip:grouper_soc_directed` (`hw/tb/top/grouper_soc_directed.core`, cocotb, targets `default`/`debug`). `grouper_soc` itself is RTL-only, with `default` and `lint` targets. A plain `tb_top` run is slow — it has no console output unless built `--target=tb_top_debug` (DEBUG_PERIPH + `FW_DEBUG=1`).

Firmware images consumed by the ROM (`hw/rtl/memory/ahb_rom.sv`, default `code.hex`/`code.vmem`, overridable via `` `PROG_FILE_HEX``/`` `PROG_FILE_VMEM` `` defines) live in `sw/`. `sw/scripts/build_fw.sh` rebuilds them; `sw/scripts/build_rom_boot.sh` builds the separate 64-byte dry-run boot ROM in `sw/dry_run/`.

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

- `cpu_ss` (`hw/rtl/cpu_ss.sv`) instantiates `picorv32` as **RV32EMC** — `ENABLE_REGS_16_31=0` (RV32E, x0–x15 only), `COMPRESSED_ISA=1`, `ENABLE_MUL`/`ENABLE_DIV`/`ENABLE_IRQ`, no barrel shifter, `PROGADDR_RESET=0x0`, `PROGADDR_IRQ=0x10`. The ISA choice is load-bearing for software: `sw/scripts/build_fw.sh` builds `-march=rv32emc -mabi=ilp32e`, and `sw/src/irq_vec.S`/`start.S` skip the x16–x31 IRQ context save under `__riscv_e`. Building firmware `rv32i*` would emit registers the CPU does not have. It hand-converts picorv32's native `mem_*`/`mem_la_*` memory interface into AHB-Lite (`HADDR`/`HTRANS`/etc signals) — there is no PCPI coprocessor attached. picorv32 is the sole AHB-Lite master; the fabric is single-master, no arbitration needed.
- `periph_ss` (`hw/rtl/periph/periph_ss.sv`) owns the `ahb3lite_intf` SystemVerilog interfaces for each slave and instantiates `ahb_interconnect` plus each peripheral. A `DEBUG_PERIPH` ifdef adds a fourth slave (`ahb_debug`).
- Address decode lives in `hw/rtl/interconnect/ahb_interconnect.sv` (currently ROM `0x0000_0000`–`0x7fff_ffff`, RAM `0x8000_0000`–`0x8fff_ffff`, UART `0x9000_0000`–`0x9000_000f`, Debug `0xf000_0000`–`0xffff_ffff` under `DEBUG_PERIPH`). New peripherals (SPI S/M, QSPI, GPIO Mux) will need a slave port added to `ahb_interconnect`/`periph_ss` and an address range carved out here.
- `hw/rtl/ahb3lite/` defines the shared `ahb3lite_intf` interface and `ahb3lite_pkg` (transfer-type constants, byte-select helpers used by memory-mapped slaves like `ahb_ram`/`ahb_rom`).
- `hw/rtl/common/` holds small reusable building blocks (clock dividers/gating, synchronizers, FIFO, shift register, downcounter) intended for reuse across the new peripherals.
- `hw/rtl/reg_blk/ahb_reg_blk.sv` is a generic parameterized AHB register block (`NUM_REGS`), likely the base for peripheral CSR blocks.
- `ip/picorv32/` is the team's picorv32 fork (`Sheffield-Chip-Design-Team/picorv32`), vendored as a git submodule. It is the single source of the CPU RTL for **both** flows: FuseSoC resolves `yosys:cpu_ip:picorv32:1.0.0` from `ip/picorv32/picorv32.core` by recursive scan of the `grouper_soc` library, and the LibreLane configs list `dir::../../ip/picorv32/picorv32.v` directly. Nothing under `librelane/` may reference `fusesoc_libraries/` — that directory is gitignored tool cache, so a path into it is unpinned and absent on a fresh clone.
- `ip/gf180mcu_ocd_ip_sram/` is a separate git repo (Open Circuit Design's experimental 3.3 V GF180MCU SRAM macros) vendored as a submodule — this is the macro family backing the 4 KiB CPU SRAM plan (`sram1024x8m8wm1` × 4). `hw/rtl/memory/ahb_ram.sv` is still a behavioral `logic [] memory []` array, not yet the hardened macro.
- **The `DRY_RUN` define** (`librelane/classic/dry_run_config.yaml` only) builds a PnR-only variant of the SoC that omits the SRAM macros entirely: `ahb_ram.sv` becomes counters on the address and data lines, `ahb_rom.sv` shrinks to 64 bytes holding the `sw/dry_run/rom_boot.S` stub that jumps to the RAM window on reset, and `ahb_spi_s` is replaced by `ahb_stub_slave`. It exists to characterize area/congestion/timing at 1100×1100 before the hardened RAM lands — it is not functional, and nothing in simulation should ever define it. That config also carries its own `dry_run.sdc` (constraining `chip_core`'s ports, not `chip_top`'s `*_PAD` ones) and `dry_run_pdn_cfg.tcl` (no `sram_grid`).

## Planning docs caveat

`planning/` is inconsistent and should be treated cautiously — cross-check anything you read there against the actual RTL before relying on it:

- A handful of files (`planning/Hardware/UART.md`, `AHB-Lite Bus.md`) are legitimate but mostly-empty GrouperSoC stubs (owner/status/TODO placeholders) — they explicitly reference "GrouperSoC" and this project's `CPU_RESET`/unified-4kB-SRAM plan.
- Most of the larger docs (`System Architecture.md`, `Hardware/Grouper-SoC-Specification.md`, `Register Map.md`, `SoC Memory Strategy.md`, `Work Allocation.md`, `DFT.md`, `Test Plan.md`, `Hardware/RAM wrapper.md`) describe a different, unrelated chip — a 4-antenna MIMO LoRa-gateway DSP ASIC ("Trouper": ΣΔ decimators, Schmidl-Cox correlator, SX1257 AFEs, PSRAM replay buffer, 544 KB baseband SRAM, etc. — none of which exists in this repo's RTL). `Grouper-SoC-Specification.md` is even internally titled "Trouper DSP Chip Specification".
- Several files under `planning/Hardware/` also have filename/content mismatches (e.g. `GPIO.md`'s body is the SPI Master spec, `QSPI.md`'s body is also the SPI Master spec) — apparent copy/paste errors from templating.

Do not use register addresses, memory maps, or block descriptions from these contaminated docs as ground truth for GrouperSoC — verify against `hw/rtl/`, `grouper_soc.core`, and `hw/dv/` instead.
