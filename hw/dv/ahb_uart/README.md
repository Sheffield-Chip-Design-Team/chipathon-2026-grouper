# UART pyuvm/cocotb bench

A pyuvm bench for the AHB-wrapped UART (`hw/rtl/uart/ahb_uart.sv`), driven through a
FuseSoC + cocotb + Verilator target.

## Layout
- `tbench/ahb_uart_env.py` — `UartAhbEnv`: wires up the AHB3Lite VIP (`hw/dv/uvc/ahb3lite/`),
  the UART VIP (`hw/dv/uvc/uart/`, one active agent driving/self-observing `uart_rx`, one
  passive agent monitoring `uart_tx`), and the pyuvm register model (`uart_reg_model.py`),
  registering their `ConfigDB` config/sequencer/model handles (`UART_CFG`, `UART_AHB_SEQR`,
  `UART_SEQR`, `UART_REG_MODEL`, `UART_TX_MONITOR`). Also picks the baud rate once, at
  `build_phase` time, before any component starts - see `randomize_baud` below.
- `uart_clk_math.py` — `clk_div_for_baud`/`pick_random_baud_rate`: the DUT-specific baud
  rate <-> `CTRL.clk_div` register math, and the candidate baud rates used when
  randomizing.
- `uart_reg_model.py` — a pyuvm register model (frontdoor only, no backdoor) for
  CTRL/STATUS/TXDATA/RXDATA: `UartRegBlock` (the four registers + their fields, matching
  `hw/rtl/uart/ahb_uart.sv`'s actual bit layout) and `Ahb3LiteRegAdapter` (translates
  generic register reads/writes into `AHB3LiteSeqItem` transactions).
- `tests/uart_test.py` — the cocotb entrypoint (`ahb_uart_cocotb.core`'s `cocotb_module`
  points straight at this module, not a separate wrapper - see note below). Defines
  `UartHelloWorldTest` (reset + send one byte through the UART VIP, read it back over AHB),
  `UartSanityTest` (an older, pin-bit-banging variant of the same check), and
  `UartRandomTest` (constrained-random baud/config/reset/data, see below).
- `sequences/uart_ahb_base_sequence.py` — `UartAhbBaseSequence`: shared AHB
  read/write/register-access helpers (`reg_write`/`reg_read`, routed through
  `uart_reg_model.py`), `configure_uart`/`wait_for_status`, DUT reset (`reset_dut`), and
  raw pin bit-banging (`drive_uart_frame`/`drive_break_condition`).
- `sequences/uart_ahb_sequence_lib.py` — every concrete sequence: `UartHelloWorldSequence`/
  `UartSanitySequence` (the two fixed sequences above), plus the constrained-random "move"
  sequences (`UartRandomResetSequence`, `UartRandomBitbangFrameSequence`,
  `UartRandomDutTransmitSequence`) and the top-level orchestrator
  (`UartRandomMoveSequence`) that layers a random selection/order/count of them together
  in one test run.
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
pip install -r sim-requirements.txt  # pinned fusesoc/cocotb/pyuvm/edalize versions
pip install -e .                    # editable-installs `hw` so hw.dv... imports resolve
                                     # inside the sim without any PYTHONPATH juggling
fusesoc library add grouper_soc .   # only needed once per checkout
```

Must be run from the repo root (`chipathon-2026-grouper`):

```bash
fusesoc run --target=default sharc:comms_ip:ahb_uart_pyuvm
```

`UartHelloWorldTest`, `UartSanityTest`, and `UartRandomTest` all run by default (cocotb
discovers every `@pyuvm.test()` in the imported module). To run just one:

```bash
TESTCASE=UartHelloWorldTest fusesoc run --target=default sharc:comms_ip:ahb_uart_pyuvm
```

Every component logs through pyuvm's built-in `self.logger` (not a custom logging setup — see
`hw/dv/uvc/uart/uart_driver.py` etc.). Default level is INFO (one line per UART frame/byte and
per AHB transfer). Set `UVM_VERBOSITY=DEBUG` for per-bit/per-condition detail, or `WARNING`/`ERROR`
to quiet it down:

```bash
UVM_VERBOSITY=DEBUG fusesoc run --target=default sharc:comms_ip:ahb_uart_pyuvm
```

## Constrained-random testing

`UartRandomTest` picks a random valid baud rate once at env build time (before any
component starts - baud can't be changed live mid-sequence, since `UartDriver`/
`UartMonitor` each cache their bit period once in `start_of_simulation_phase`), then runs
`UartRandomMoveSequence`, which layers a random count/order of smaller "moves" together in
one test: mid-test DUT resets, clean/bad-stop-bit/break bit-banged frames, constrained-random
bytes sent through the real VIP (`UartRandomByteSequence` in `hw/dv/uvc/uart/uart_sequences.py`),
and bytes written to `TXDATA` that the DUT itself transmits (checked via the passive
`uart_tx_agent`'s monitor).

Reproducibility rides on cocotb's own `RANDOM_SEED` env var (seeds Python's global `random`
before any pyuvm phase runs, and is always logged - `UartTestBase.build_phase` re-logs it
through `self.logger` too, so it shows up in the pyuvm-formatted log stream):

```bash
TESTCASE=UartRandomTest fusesoc run --target=default sharc:comms_ip:ahb_uart_pyuvm

# reproduce a specific failure
TESTCASE=UartRandomTest RANDOM_SEED=12345 fusesoc run --target=default sharc:comms_ip:ahb_uart_pyuvm
```

## Coverage

`ahb_uart_cocotb.core` compiles with Verilator's `--coverage` (line/toggle/functional),
which writes `coverage.dat` into the work root (`build/sharc_comms_ip_ahb_uart_pyuvm_0.0.1/default/`)
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
verilator_coverage --annotate coverage_annotated build/sharc_comms_ip_ahb_uart_pyuvm_0.0.1/default/coverage.dat
```
