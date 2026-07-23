# Simple QSPI directed testbench

A plain cocotb directed testbench for the AHB-facing QSPI register shell in
`hw/rtl/qspi/ahb_qspi.sv`.

This bench belongs under `hw/tb` because it uses deterministic directed tests
rather than a metric-driven pyuvm environment.

## Current scope

The tests cover:

- reset values and inactive external outputs;
- full-word register access;
- byte-lane register access;
- reserved-bit behaviour;
- `START` read-as-zero semantics;
- PSRAM and NOR address validation;
- NOR flash write protection;
- W1C status behaviour;
- error interrupt behaviour;
- invalid offsets, alignment and transfer sizes;
- rejection of `HTRANS=BUSY` as a valid transfer.

The serial QSPI transaction engine is not implemented yet, so command shifting,
SCK timing, SIO direction and external device responses are outside the current
testbench scope.

## Run

From the repository root with the virtual environment activated:

```bash
python -m pip install -e .
fusesoc run --target=default sharc:comms_ip:ahb_qspi_directed:0.0.1