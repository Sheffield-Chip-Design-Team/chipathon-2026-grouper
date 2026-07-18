# Simple UART directed testbench

A minimal, self-contained cocotb directed test for the AHB-wrapped UART
(`hw/rtl/uart/ahb_uart.sv`), driven through a FuseSoC + cocotb + Verilator
target. No pyuvm — just plain `cocotb.test()`s that drive the AHB3-Lite bus
and the `uart_tx`/`uart_rx` pins directly.

For a fuller constrained-random, coverage-driven pyuvm bench for the same
DUT, see [`hw/dv/ahb_uart/`](../../hw/dv/ahb_uart/).

## Testbench Architecture

- `test_uart.py` — the cocotb entrypoint (`uart_cocotb.core`'s `cocotb_module`
  points at this module). `configure_uart` enables TX/RX at a fixed baud rate
  (reusing `hw/dv/ahb_uart/uart_clk_math.py`'s baud-to-`clk_div` math);
  `capture_tx_byte`/`drive_rx_byte` sample/bit-bang the 8N1, LSB-first serial
  frames on `uart_tx`/`uart_rx`.
  - `test_uart_tx_byte` — writes a byte to `TXDATA` and checks the serial
    frame driven onto `uart_tx`, then checks `STATUS.tx_empty`/`tx_active`.
  - `test_uart_rx_byte` — bit-bangs a byte onto `uart_rx` and reads it back
    through `RXDATA`.
- `../tb_utils/ahb_utils.py` — shared `ahb_write`/`ahb_read` helpers that
  drive single-beat AHB3-Lite transfers, reusable by any other `hw/tb/*`
  cocotb testbench.
- `uart_cocotb.core` — FuseSoC core for this testbench (depends on the
  RTL-only `sharc:comms_ip:ahb_uart:0.0.1` core).

## Run

Environment setup (first time only)
```bash
# run at the repo root
python3.12 -m venv .env
source .env/bin/activate            # repo venv, see top-level CLAUDE.md
pip install fusesoc cocotb
pip install -e .                    # editable-installs `hw` so hw.tb.../hw.dv... imports        
fusesoc library add grouper_soc .   # only needed once per checkout
```

Must be run from the repo root (`chipathon-2026-grouper`):

```bash
fusesoc run --target=default sharc:comms_ip:ahb_uart_directed
```

Both `test_uart_tx_byte` and `test_uart_rx_byte` run by default (cocotb
discovers every `@cocotb.test()` in the module). To run just one:

```bash
TESTCASE=test_uart_tx_byte fusesoc run --target=default sharc:comms_ip:ahb_uart_directed
```

Waveforms (`--trace-fst`) are written into the FuseSoC work root
(`build/sharc_comms_ip_uart_directed_cocotb_0.0.1/default/`).
