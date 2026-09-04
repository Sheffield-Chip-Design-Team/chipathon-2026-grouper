# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

GrouperSoC is an entry for the 2026 Chipathon — an open-source chip design event where teams design blocks that are integrated onto a shared GF180MCU die and fabricated by wafer.space.

The SoC is a `picorv32` (RV32EMC) CPU with an AHB-Lite bus fabric and a set of AHB peripherals. Status of the five peripheral blocks:

| Block | RTL | Block-level TB | Wired into `periph_ss` |
|---|---|---|---|
| UART | `hw/rtl/uart/` | `hw/tb/uart/`, `hw/dv/ahb_uart/` | yes |
| GPIO Mux | `hw/rtl/gpio/` (+ `hw/rtl/io_ss.sv`) | `hw/tb/gpio/` | yes (inside `io_ss`) |
| SPI Slave | `hw/rtl/spi_s/` | `hw/tb/spi_s/` | yes |
| SPI Master | `hw/rtl/spi_m/` | `hw/tb/spi_m/` (18/21 pass — see `spi_m_bugs.md`) | yes |
| QSPI | `hw/rtl/qspi/` | `hw/tb/qspi/` | yes |

Both SPI Master and QSPI are now wired into `periph_ss`; no fabric slot holds a stub any more. The SPI Master's pads reach GPIO pins 4–7 through `io_ss`, and `sw/tests/test_spi_m.c` drives it at the top level against an APS6404L PSRAM model (`hw/tb/models/aps6404l.py`) — the `sw_spi_m` CI leg. Its block-level TB still has three real failures; see `hw/rtl/spi_m/spi_m_bugs.md` (`SPIM-ISSUE-027`).

CPU memory is planned as a unified 4 KiB SRAM built from four `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros (1024 × 8-bit words each, with byte/bit write enables) — see `ip/gf180mcu_ocd_ip_sram/` (vendored as a git submodule). **This is not yet integrated.** `hw/rtl/memory/ram_ss.sv` and `hw/pd/wrappers/sram1024x8_wrapper.sv` exist but are instantiated nowhere; `hw/rtl/memory/ahb_ram.sv` is still a behavioural `logic [] memory []` array, so the current hardened netlist implements RAM as a flop array. See "Outstanding RAM work" below.

## Commands

Simulation is FuseSoC + Verilator (RTL) and cocotb + Icarus (chip-level / GL). Physical design is LibreLane via Nix.

```bash
# one-time environment setup
python3.12 -m venv .env          # 3.12+; 3.13 is the max for fusesoc + cocotb
source .env/bin/activate
pip install -e .                 # deps are pinned in pyproject.toml

# fetch IP submodules (ip/picorv32, ip/gf180mcu_ocd_ip_sram)
git submodule update --init --recursive

# register this repo with fusesoc; it scans recursively, so ip/picorv32/picorv32.core
# is found without a library entry of its own
fusesoc library add grouper_soc .
```

`--no-export` keeps sources in place instead of copying them into the work root, so paths in error messages point at the real files.

```bash
# lint the whole SoC (seconds; catches an unelaboratable block before a slow leg)
fusesoc run --no-export --target=lint sharc:soc_ip:grouper_soc

# top level, SystemVerilog TB - boots from ROM, runs sw/src/main.c, prints "Bye!"
fusesoc run --no-export --target=tb_top sharc:soc_ip:grouper_soc_tb

# top level, cocotb TB - same SoC driven from hw/tb/top/test_soc.py
fusesoc run --no-export sharc:soc_ip:grouper_soc_directed

# pick a firmware top level from sw/tests (build_fw.sh --list shows them)
FW_TEST=gpio_regs fusesoc run --no-export sharc:soc_ip:grouper_soc_directed
```

`grouper_soc` is **RTL-only** (`default`, `lint`). The testbenches are separate cores: `sharc:soc_ip:grouper_soc_tb` (`hw/tb/top/grouper_soc_tb.core` — `tb_top`, `tb_top_debug`, `tb_top_trace`) and `sharc:soc_ip:grouper_soc_directed` (`hw/tb/top/grouper_soc_directed.core` — `default`, `debug`, `trace`).

The `debug`/`trace` tiers set `DEBUG_PERIPH=true`, which instantiates a **ninth** AHB slave (`ahb_debug`). That is not the configuration that tapes out — use plain `tb_top`/`default` for the 8-slave shipping fabric. `debug` also needs firmware built with `-DDEBUG` (`FW_DEBUG=1`, which those targets set), otherwise `debug()`/`debug_str()` compile to no-ops.

### Block-level tests

Each peripheral has a lint target on its RTL core and, where it exists, a cocotb suite in its own core:

```bash
fusesoc run ahb_uart_directed        # sharc:comms_ip:ahb_uart_directed
fusesoc run ahb_uart_pyuvm           # sharc:comms_ip:ahb_uart_pyuvm  (pyuvm)
fusesoc run ahb_gpio_ctrl_directed
fusesoc run ahb_qspi_directed
fusesoc run ahb_spi_s_directed
```

`.github/sim-ci-targets.yaml` is the authoritative matrix — it lists every core/target CI runs and which legs are `fail_ok: true` (currently `ahb_uart_mdv` and `ahb_spi_s_directed`). Add a new block's legs there.

`hw/dv/` holds the pyuvm layer: reusable UVCs (`hw/dv/uvc/{ahb3lite,uart,gpio}`) and the `hw/dv/ahb_uart/` suite. `hw/tb/` holds the lighter directed cocotb tests plus shared helpers in `hw/tb/tb_utils/`.

### Firmware

Firmware images consumed by the ROM (`hw/rtl/memory/ahb_rom.sv`, default `code.hex`/`code.vmem`, overridable via `` `PROG_FILE_HEX``/`` `PROG_FILE_VMEM` `` defines) live in `sw/`. `sw/scripts/build_fw.sh` rebuilds them; `sw/scripts/build_rom_boot.sh` builds the separate 64-byte dry-run boot ROM in `sw/dry_run/`.

Anything at the top level runs `build_fw.sh` as a pre-build hook, so it needs a bare-metal RISC-V GCC on `PATH` supporting `-march=rv32emc -mabi=ilp32e`. Default prefix `riscv64-unknown-elf-`, override with `CROSS`. Lint and block-level targets need no toolchain.

#### The 4 KiB RAM budget for `sw/tests`

The CI software legs run the `default` target, which links a **RAM-resident**
image (`sw/boot/ram.ld`): code, rodata, data, bss *and* the stack share one
4 KiB region. That is the binding constraint on anything in `sw/tests`, and it
is much tighter than it looks, because the fixed cost is most of it:

| | bytes |
|---|---|
| library + startup + `g_test_*` harness (mostly the `printf` formatter, ~1.2 KiB) | ~2330 |
| `.irq` — `irq_regs` (48) + IRQ stack (384) | 432 |
| main stack — measured worst case is ~250 (`g_check_eq_str` → `printf` → `g_vfprintf` → `emit_num`) | ≥320 |
| **left for the test itself** | **~1000** |

So a test file gets roughly **1 KiB** of its own code and rodata. Each
`G_CHECK*` costs ~75 bytes — the call site plus the stringified expression in
rodata — so ~13 checks is a full image. When one stops fitting, the linker
says `region 'RAM' overflowed by N bytes`; split it into two more specific
tests and give each its own CI leg rather than trimming checks.

To check a test without running a simulation:

```bash
FW_TEST=<name> ./sw/scripts/build_fw.sh --link ram --baud 625000 --no-disasm
grep -E '_eirq|_estack' sw/build/firmware.map     # stack = _estack - _eirq
```


### Physical design

`nix-shell` in the repo root gives a shell with the `leo/gf180mcu` branch of LibreLane (OpenROAD is compiled locally on first use and cached).

```bash
make clone-pdk       # fetches wafer-space/gf180mcu into ./gf180mcu (not present by default)
make librelane       # full flow; SLOT=1x1 by default (1x1, 0p5x1, 1x0p5, 0p5x0p5)
make librelane-openroad / librelane-klayout      # open the last run
make sim / sim-gl    # cocotb/chip_top_tb.py against RTL / the netlist in final/
```

> The `make librelane*` targets pass `librelane/slots/slot_$(SLOT).yaml` and `librelane/config.yaml`, but those paths do not exist — the configs live under `librelane/chip/`. `librelane/classic/config.yaml` likewise points `PNR_SDC_FILE` at a `grouper_chip_top.sdc` that isn't there (only `grouper_chip_core.sdc` is). Fix the paths before trusting a `make librelane` invocation.

`cocotb/chip_top_tb.py` is still the unmodified wafer.space template: it runs a counter test, sources `../src/chip_top.sv` (this repo's equivalents are in `hw/pd/`), and pulls the PDK's `sram512x8m8wm1` model rather than the OCD `sram1024x8m8wm1` one. It needs rewriting before `make sim`/`sim-gl` means anything here.

## Architecture

```
grouper_soc_top          (clk, async_rst_n, uart_tx/rx, gpio_{in,out,oe,cs,sl,ie,pu,pd}[15:0])
  ├─ sync × (1 + NUM_GPIO)   reset resynchroniser + 2-FF synchroniser per GPIO input,
  │                          each bypassable via gpio_sync_en_n (a deliberate CDC opt-out)
  └─ digital_ss
       ├─ cpu_ss       picorv32 + native-memory-interface → AHB-Lite master bridge
       │               irq = {uart_rx_error_irq, uart_rx_irq}
       └─ periph_ss
            ├─ ahb_interconnect_ss   address decode + response mux, 8 slaves (9 with DEBUG_PERIPH);
            │                        buffers the ROM and RAM ports through ahb_conn_buff
            ├─ ahb_rom
            ├─ ahb_ram
            ├─ ahb_uart              wraps hw/rtl/uart/{uart,uart_tx,uart_rx,uart_clk_div}.sv
            ├─ io_ss                 pad control + ahb_gpio_ctrl
            ├─ ahb_spi_s
            ├─ ahb_qspi              pads via io_ss, GPIO 8-14
            ├─ ahb_spi_m             pads via io_ss, GPIO 4-7
            ├─ (ext periph slot)     brought out as digital_ss's ext_ahb_m_if_* ports,
            │                        tied off at grouper_soc_top
            └─ ahb_debug             DEBUG_PERIPH only
```

### Address map

Decode lives in `hw/rtl/ahb_interconnect_ss.sv` (~line 217). Contiguous 4 KiB windows from zero — **not** the old sparse `0x8000_0000`/`0x9000_0000` layout:

| Slot | Range | Size |
|---|---|---|
| ROM | `0x0000_0000`–`0x0000_1fff` | 8 KiB |
| RAM | `0x0000_2000`–`0x0000_2fff` | 4 KiB |
| UART | `0x0000_3000`–`0x0000_3fff` | 4 KiB |
| GPIO CTRL | `0x0000_4000`–`0x0000_4fff` | 4 KiB |
| QSPI | `0x0000_5000`–`0x0000_5fff` | 4 KiB |
| SPI Master | `0x0000_6000`–`0x0000_6fff` | 4 KiB |
| SPI Slave | `0x0000_7000`–`0x0000_7fff` | 4 KiB |
| External periph | `0x0001_0000`–`0x0001_ffff` | 64 KiB |
| Debug | `0xf000_2000`–`0xf000_2fff` | 4 KiB (`DEBUG_PERIPH` only) |

Adding a peripheral means a slave port on `ahb_interconnect_ss` (`SLOT_*` localparam + `hsel` case arm + port set) and an instance in `periph_ss`.

### Notes on specific blocks

- `cpu_ss` (`hw/rtl/cpu_ss.sv`) instantiates `picorv32` as **RV32EMC** — `ENABLE_REGS_16_31=0` (RV32E, x0–x15 only), `COMPRESSED_ISA=1`, `ENABLE_MUL`/`ENABLE_DIV`/`ENABLE_IRQ`/`ENABLE_IRQ_TIMER`, no barrel shifter, `PROGADDR_RESET=0x0`, `PROGADDR_IRQ=0x10`, no PCPI. The ISA choice is load-bearing for software: `build_fw.sh` builds `-march=rv32emc -mabi=ilp32e`, and `sw/src/irq_vec.S`/`start.S` skip the x16–x31 IRQ context save under `__riscv_e`. Building firmware `rv32i*` would emit registers the CPU does not have. `cpu_ss` hand-converts picorv32's native `mem_*`/`mem_la_*` interface into AHB-Lite; picorv32 is the sole master, so the fabric needs no arbitration.
- `periph_ss` (`hw/rtl/periph_ss.sv`) uses discrete `logic` bundles per slave, not the `ahb3lite_intf` interface. Inside `ahb_interconnect_ss` the ROM and RAM ports each get an `ahb_conn_buff`; every other slave is a direct assign off the shared `HADDR`/`HWDATA` with a per-slave `HSEL`.
- `hw/rtl/ahb3lite/` defines `ahb3lite_intf` and `ahb3lite_pkg` (transfer-type constants, byte-select helpers used by `ahb_ram`/`ahb_rom`). The interface itself is used by the DV UVCs rather than by `periph_ss`.
- `hw/rtl/common/` holds reusable building blocks (`clk_div`, `clk_gate`, `clk_out`, `sync`, `pulse_sync`, `small_sync_fifo`, `shift_reg`, `downcounter`) shared across peripherals.
- `ip/picorv32/` is the team's fork (`Sheffield-Chip-Design-Team/picorv32`), a submodule, and the single source of CPU RTL for **both** flows: FuseSoC resolves `yosys:cpu_ip:picorv32:1.0.0` from `ip/picorv32/picorv32.core` by recursive scan, and the LibreLane configs list `dir::../../ip/picorv32/picorv32.v` directly. Nothing under `librelane/` may reference `fusesoc_libraries/` — that is gitignored tool cache, so a path into it is unpinned and absent on a fresh clone.
- `hw/pd/` holds the physical-design wrappers: `grouper_soc_chip_core.sv`, `grouper_soc_chip_top.sv`, `slot_defines.svh`, `grouper_soc.sdc`, and `wrappers/sram1024x8_wrapper.sv`.
- `librelane/classic/` hardens `grouper_soc_chip_core` (macro flow, 1100×1100, signs off at 3.3 V across `nom_tt_025C_3v30` / `min_ff_n40C_3v60` / `max_ss_125C_3v00`); `librelane/chip/` is the `chip_top` padring flow with per-slot configs. `final/` holds the last run's saved views (`nl`, `pnl`, `sdf`, `lib`, `spef`, `gds`, …).
- **The `DRY_RUN` define** (`librelane/classic/dry_run_config.yaml` only) builds a PnR-only variant that omits the SRAM macros entirely: `ahb_ram.sv` becomes counters on the address and data lines, `ahb_rom.sv` shrinks to 64 bytes holding the `sw/dry_run/rom_boot.S` stub, and `ahb_spi_s` is replaced by `ahb_stub_slave`. It characterises area/congestion/timing before the hardened RAM lands — it is not functional, and nothing in simulation should ever define it. That config carries its own `dry_run.sdc` (constraining `chip_core`'s ports, not `chip_top`'s `*_PAD` ones) and `dry_run_pdn_cfg.tcl` (no `sram_grid`).

### Outstanding RAM work

Three things block the macro RAM, in order:

1. **`ram_ss` is not instantiated.** Wire it into `ahb_ram` behind the `USE_MACRO_RAM` parameter and add `ram_ss.sv` to the `rtl` fileset in `grouper_soc.core`. `ram_ss` is four byte-lane macros of 1024 × 8 b, i.e. 1024 words × 32 b = 4 KiB, so `ahb_ram`'s default `MEM_WIDTH=11` (2 KiB) has to become 12 to match — and the RAM decode window is already 4 KiB. The macro placements in `librelane/classic/config.yaml` already name `u_ram_ss.gen_macro_ram.gen_sram[N].u_wrapper.u_sram_macro`, so they are aspirational until this lands.
2. **`ahb_ram` cannot drive a single-port SRAM.** Its read path uses address-phase `word_address` while its write path uses registered `word_address_r`; a flop array serves both in one cycle, a single-port macro with one `A` port cannot. `HREADYOUT` is hardwired to `'1`, so there is no stall mechanism. Needs a wait state on write-followed-by-read, or a write-data bypass.
3. **Gate-level simulation needs the macro's behavioural model** (`ip/gf180mcu_ocd_ip_sram/cells/.../sram1024x8m8wm1.v`). Synthesis consumes `__blackbox_pp.v`, so the netlist instance is empty. The model carries its own `specify` timing checks and requires `CEN` to be seen high before its first falling edge, or it latches "memory is not operational". Use Icarus, not Verilator — Verilator has no `$sdf_annotate` and ignores `specify` blocks.

## Docs caveat

`docs/` (formerly `planning/`) is a mix of current and stale material — cross-check anything you read there against the actual RTL before relying on it.

Current structure:

```
docs/Gantt.md                                  superseded by the Progress doc
docs/Progress and Plan - 4 July 2026.md        rolling plan, dated 4 July 2026
docs/hardware/Schematic Review.md              the one confirmed-authoritative source doc
docs/hardware/design/Grouper SoC Specification.md
docs/hardware/design/blocks/{UART,GPIO Mux,SPI Master,SPI Slave,QSPI}.md
docs/hardware/verification/Grouper SoC Verification Plan.md
docs/hardware/verification/blocks/*.md
docs/software/Bootloader.md                    empty stub
```

The earlier contamination — a batch of docs describing an unrelated "Trouper" MIMO LoRa-gateway DSP ASIC — was deleted (see the Progress doc). What survives was rebuilt from the Schematic Review, but it is still **planning** material: the block docs and verification plans describe intended behaviour, and several blocks they specify are stubbed or unwired in RTL. In particular, the Verification Plan describes a ROM→RAM bank-switch boot flow that the current `ahb_interconnect_ss` address map does not implement.

Do not take register addresses, memory maps, or block descriptions from `docs/` as ground truth. Verify against `hw/rtl/`, `grouper_soc.core`, and `.github/sim-ci-targets.yaml` instead.
