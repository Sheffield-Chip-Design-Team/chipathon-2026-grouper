# Simple SPI Slave directed testbench

A minimal, self-contained cocotb directed test for the AHB-wrapped SPI slave
(`hw/rtl/spi_s/ahb_spi_s.sv`), driven through a FuseSoC + cocotb + Verilator
target.

For a fuller constrained-random, coverage-driven pyuvm bench for the same
DUT, see [`hw/dv/ahb_uart/`](../../hw/dv/ahb_uart/).

## Testbench Architecture

- `test_spi_s.py` — cocotb entry point for the SPI slave directed tests.
- `../tb_utils/ahb_utils.py` — shared AHB read/write helper functions.
- `spi_s_directed.core` — FuseSoC core describing the SPI slave simulation.

- `test_ctrl_rw` — verifies AHB read/write access to the CTRL register.
- Additional SPI transaction tests will be added as the RTL is implemented.

## Run

Environment setup (first time only)
```bash
# run at the repo root
python3.12 -m venv .env
source .env/bin/activate            # repo venv, see top-level CLAUDE.md
pip install fusesoc cocotb
fusesoc library add grouper_soc .   # only needed once per checkout
```

Must be run from the repo root (`chipathon-2026-grouper`), with `PYTHONPATH`
including it so the `hw.tb...`/`hw.dv...` imports resolve inside the sim:

```bash
PYTHONPATH="$PWD:$PYTHONPATH" fusesoc run --target=default sharc:comms_ip:ahb_spi_s_directed
```

Both `test_spi_tx_byte` and `test_spi_rx_byte` run by default (cocotb
discovers every `@cocotb.test()` in the module). To run just one:

```bash
PYTHONPATH="$PWD:$PYTHONPATH" TESTCASE=test_ctrl_rw fusesoc run --target=default sharc:comms_ip:ahb_spi_s_directed
```

Waveforms (`--trace-fst`) are written into the FuseSoC work root
(`build/sharc_comms_ip_ahb_spi_s_directed_0.0.1/default/`).
