# UART pyuvm/cocotb sanity bench

This directory contains a simple AHB-driven pyuvm sanity bench for the UART RTL.

## Layout
- `uart_ahb_sequences.py` — AHB register-access sanity sequence
- `uart_ahb_env.py` — AHB environment wiring
- `uart_test.py` — pyuvm sanity test
- `uart_rx_driver.py` — optional direct UART pin driver helpers
- `uart_rx_monitor.py` — optional direct UART pin monitor helpers
- `uart_bench.py` — cocotb entrypoint

## Python env
Use the repo venv:

```bash
source /Users/macbook/chip_dev/sharc/chipathon/2026/grouper-soc/env/bin/activate
```

## Run sketch
Set the cocotb test module to the entrypoint and run the simulator flow you already use for the UART RTL.

```bash
export COCOTB_TEST_MODULES=hw.dv.uart.uart_bench
```

The included test is:
- `UartSanityTest`
