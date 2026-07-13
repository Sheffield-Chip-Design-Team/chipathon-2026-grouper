# UART pyuvm/cocotb bench

A pyuvm bench for the AHB-wrapped UART (`hw/rtl/uart/ahb_uart.sv`), driven through a
FuseSoC + cocotb + Verilator target.

## Layout
- `tbench/ahb_uart_env.py` — `UartAhbEnv`: wires up the AHB3Lite VIP (`hw/dv/uvc/ahb3lite/`)
  and the UART VIP (`hw/dv/uvc/uart/`), and registers their `ConfigDB` config/sequencer
  handles (`UART_CFG`, `UART_AHB_SEQR`, `UART_SEQR`).
- `tests/uart_test.py` — the cocotb entrypoint (`ahb_uart_cocotb.core`'s `cocotb_module`
  points straight at this module, not a separate wrapper - see note below). Defines
  `UartHelloWorldTest` (reset + send one byte through the UART VIP, read it back over AHB)
  and `UartSanityTest` (an older, pin-bit-banging variant of the same check).
- `sequences/uart_ahb_sequences.py` — `UartHelloWorldSequence`/`UartSanitySequence` plus
  the shared `UartAhbBaseSequence` AHB read/write helpers.
- `tbench/uart_rx_config.py` — superseded by `hw/dv/uvc/uart/uart_config.py`'s `UartConfig`;
  left in place but unused by the current test path.
- `ahb_uart_cocotb.core` — FuseSoC core file for this testbench.

Note: `cocotb_module` must point at the module where `@pyuvm.test()` is actually applied
(`tests/uart_test.py`), not at a wrapper that just re-imports the test classes. pyuvm's
`test()` decorator returns the plain, undecorated class and separately attaches the real
cocotb test object to its *own defining module's* namespace (via `inspect.stack()`) - that
hidden object doesn't travel with the class if something else re-imports it, so cocotb's
`discover_tests` finds nothing in a wrapper module.

## Run

```bash
source .env/bin/activate            # repo venv, see top-level CLAUDE.md
pip install fusesoc cocotb pyuvm
fusesoc library add grouper_soc .   # only needed once per checkout
```

Must be run from the repo root (`chipathon-2026-grouper`), and `PYTHONPATH` must include
it so `hw.dv...` imports resolve inside the sim — edalize's cocotb support inherits your
shell's environment as-is, it does not set `PYTHONPATH` itself. Easiest to set it inline
on the same command so there's no separate step to forget:

```bash
PYTHONPATH="$PWD:$PYTHONPATH" fusesoc run --target=default sharc:dv:ahb_uart_cocotb
```

Both `UartHelloWorldTest` and `UartSanityTest` run by default (cocotb discovers every
`@pyuvm.test()` in the imported module). To run just one:

```bash
PYTHONPATH="$PWD:$PYTHONPATH" TESTCASE=UartHelloWorldTest fusesoc run --target=default sharc:dv:ahb_uart_cocotb
```

Every component logs through pyuvm's built-in `self.logger` (not a custom logging setup — see
`hw/dv/uvc/uart/uart_driver.py` etc.). Default level is INFO (one line per UART frame/byte and
per AHB transfer). Set `UVM_VERBOSITY=DEBUG` for per-bit/per-condition detail, or `WARNING`/`ERROR`
to quiet it down:

```bash
PYTHONPATH="$PWD:$PYTHONPATH" UVM_VERBOSITY=DEBUG fusesoc run --target=default sharc:dv:ahb_uart_cocotb
```

## Coverage

`ahb_uart_cocotb.core` compiles with Verilator's `--coverage` (line/toggle/functional),
which writes `coverage.dat` into the work root (`build/sharc_dv_ahb_uart_cocotb_0.0.1/default/`)
once the test finishes.

There's no CAPI2-hook-based report: edalize's cocotb-aware `Sim` flow (`edalize/flows/sim.py`)
invokes the simulator directly rather than through the Makefile `run` target, so
`hooks: post_run:` scripts are never triggered for a `cocotb_module` target — confirmed against
0.6.8, the latest edalize release, so this isn't a version issue. Use `run_with_coverage.sh`
instead, which runs the sim and then prints the coverage summary in one command:

```bash
hw/dv/ahb_uart/run_with_coverage.sh
```

Any extra arguments (e.g. `TESTCASE=...` doesn't work this way since it's an env var, but
CLI flags do) are passed straight through to `fusesoc run`. The actual coverage-reporting
step lives in `hw/dv/ahb_uart/scripts/report_coverage.sh` (just `verilator_coverage
coverage.dat`, run from the work root) if you want to invoke it standalone against an
existing `coverage.dat`.

For an annotated per-line source view instead of the summary:

```bash
verilator_coverage --annotate coverage_annotated build/sharc_dv_ahb_uart_cocotb_0.0.1/default/coverage.dat
```
