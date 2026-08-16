# Grouper SoC gf180mcu Chipathon 2026 ASIC


# Grouper SoC — Simulation Quick Start

## 1) Create + activate a virtual environment
```bash
python3.12 -m venv .env
source .env/bin/activate
```

## 2) Install python simulation dependencies
```bash
pip install -e .
```

## 3) Fetch the IP submodules and add the FuseSoC library
```bash
# picorv32 (ip/picorv32) and the SRAM macros (ip/gf180mcu_ocd_ip_sram)
git submodule update --init --recursive
fusesoc library add grouper_soc .
```
FuseSoC scans this repo recursively, so `ip/picorv32/picorv32.core` is picked
up by the `grouper_soc` library — picorv32 does **not** need a library entry of
its own. The ASIC flow reads the same submodule path directly
(`librelane/*/config.yaml`), so RTL sim and PnR compile identical sources at a
commit pinned by git.

## 4) Run simulations

Every simulation is a FuseSoC `run` against a core and one of its targets.
`--no-export` keeps the sources in place instead of copying them into the work
root, which makes the paths in error messages point back at the real files.

### Lint (fastest sanity check, no simulation)

```bash
fusesoc run --no-export --target=lint sharc:soc_ip:grouper_soc
```

Verilator elaborates the whole SoC and stops. Seconds, and it catches an
unconnected port or an unelaboratable block before you spend minutes on a
build. Every peripheral has one too, e.g. `sharc:comms_ip:ahb_uart`.

### Top level, SystemVerilog testbench

```bash
fusesoc run --no-export --target=tb_top sharc:soc_ip:grouper_soc_tb
```

Boots the CPU out of ROM and runs `sw/src/main.c` to completion; the run is
good when the console reaches `Bye!`.

> [!IMPORTANT]
> The core is **`grouper_soc_tb`**, not `grouper_soc`. `grouper_soc` is RTL
> only — it has just `default` and `lint`, and no testbench of its own.

Other targets on this core: `tb_top_debug` adds the `ahb_debug` peripheral and
builds the firmware with `-DDEBUG`, so `debug()`/`debug_str()` produce output;
`tb_top_trace` adds picorv32's instruction trace on top of that. Both change
the design under test by instantiating a ninth AHB slave, so use plain
`tb_top` when you want the configuration that tapes out.

### Top level, cocotb testbench

```bash
fusesoc run --no-export sharc:soc_ip:grouper_soc_directed
```

Same SoC, driven from Python (`hw/tb/top/test_soc.py`) rather than
SystemVerilog, so the testbench can drive stimulus and assert on pad state.
Targets: `default`, `debug`, `trace` — the same three tiers as above.

### Running a specific firmware test

`FW_TEST` selects which top level in `sw/tests` gets built in place of
`sw/src/main.c`; `sw/scripts/build_fw.sh --list` shows what is available
(`fibonnaci`, `gpio`, `stdlib_fmt`, `stdlib_str`, `uart_echo`, …).

```bash
FW_TEST=gpio fusesoc run --no-export sharc:soc_ip:grouper_soc_directed
```

`test_soc.py` keys off the same variable: most firmware only has to reach
`TEST_RESULT: PASS`, while `gpio` and `uart_echo` get a dedicated test that
drives the pads or the console. The tests that don't apply to the selected
firmware report as skipped, which is expected and is not a failure.

`FW_DEBUG=1` builds with `-DDEBUG` without switching target, and pairs with
`--target=debug`.

### Peripheral block-level tests

Each block has its own cocotb suite, independent of the SoC:

```bash
fusesoc run ahb_uart_directed        # UART, directed
fusesoc run ahb_uart_pyuvm           # UART, pyuvm
fusesoc run ahb_gpio_ctrl_directed   # GPIO, directed
fusesoc run ahb_qspi_directed        # QSPI, directed
fusesoc run ahb_spi_s_directed       # SPI slave
```

These are exactly what CI runs — see `.github/sim-ci-targets.yaml` for the
full matrix and which legs are currently allowed to fail.

### Toolchain note

Anything at the top level builds firmware through `sw/scripts/build_fw.sh`, so
it needs a bare-metal RISC-V GCC on `PATH`. The default prefix is
`riscv64-unknown-elf-`; override it with `CROSS` if yours differs, e.g.
`CROSS=riscv-none-elf-`. It must support `-march=rv32emc -mabi=ilp32e`, which
is what `cpu_ss.sv`'s RV32E picorv32 configuration requires — a toolchain
without that multilib fails with "Cannot find suitable multilib set". The
lint and peripheral targets above need no toolchain at all.

### Waveforms

Every simulation target writes a dump into its work root under
`build/<core>/<target>/`. View with GTKWave or Surfer.

## Running Implementation 

This repository contains a Nix flake that provides a shell with the [`leo/gf180mcu`](https://github.com/librelane/librelane/tree/leo/gf180mcu) branch of LibreLane.

Simply run `nix-shell` in the root of this repository.

> [!NOTE]
> Since we are working on a branch of LibreLane, OpenROAD needs to be compiled locally. This will be done automatically by Nix, and the binary will be cached locally. 

With this shell enabled, run the implementation:

```
make librelane
```

## View the Design

After completion, you can view the design using the OpenROAD GUI:

```
make librelane-openroad
```

Or using KLayout:

```
make librelane-klayout
```

## Verification and Simulation

We use [cocotb](https://www.cocotb.org/), a Python-based testbench environment, for the verification of the chip.
The underlying simulator is Icarus Verilog (https://github.com/steveicarus/iverilog).

The testbench is located in `cocotb/chip_top_tb.py`. To run the RTL simulation, run the following command:

```
make sim
```

To run the GL (gate-level) simulation, run the following command:

```
make sim-gl
```

> [!NOTE]
> You need to have the latest implementation of your design in the `final/` folder. After a run has completed without errors, the final views will be copied to `final/`.

In both cases, a waveform file will be generated under `cocotb/sim_build/chip_top.fst`.
You can view it using a waveform viewer, for example, [GTKWave](https://gtkwave.github.io/gtkwave/).

```
make sim-view
```

## Additional Requirements
- This flow requires at least python 3.12 (3.13 is the maximum version for fusesoc + cocotb)
- Verilator 5+ is required in PATH.
- A bare-metal RISC-V GCC in PATH, for the firmware build (see the toolchain
  note under "Run simulations"). `riscv64-unknown-elf-` by default, or set
  `CROSS` to whatever prefix yours uses. It must provide an `rv32emc`/`ilp32e`
  multilib. Only the top-level targets need it; lint and the peripheral
  block-level tests do not.

