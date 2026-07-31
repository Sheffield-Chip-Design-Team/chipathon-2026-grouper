# Minimal AHB QSPI Controller

This directory contains directed cocotb tests for the minimal AHB-controlled QSPI controller.

## Current scope

The controller allows software to provide:

- an arbitrary 8-bit opcode;
- an arbitrary 24-bit address;
- one 8-bit write value or read result;
- a read/write direction;
- one of two chip-select targets;
- a programmable QSPI clock divider.

A transaction begins when software writes `START = 1`.

## Register map

| Offset | Register | Description |
|---|---|---|
| `0x00` | `CTRL` | Start, direction, target and clock divider |
| `0x04` | `STATUS` | Busy, done and received-data-valid status |
| `0x08` | `OPCODE` | Arbitrary 8-bit command |
| `0x0C` | `ADDRESS` | Arbitrary 24-bit address |
| `0x10` | `DATA` | One-byte transmit or receive data |

### CTRL fields

| Bits | Field | Description |
|---|---|---|
| `[0]` | `START` | Starts a transaction; not stored |
| `[1]` | `DIR` | `0` = write, `1` = read |
| `[2]` | `TARGET` | Selects one of the two chip-select outputs |
| `[15:8]` | `CLKDIV` | Controls the QSPI clock rate |

### STATUS fields

| Bits | Field | Description |
|---|---|---|
| `[0]` | `BUSY` | Transaction is active |
| `[1]` | `DONE` | Transaction has completed |
| `[2]` | `RX_VALID` | `DATA` contains a newly received byte |

`DONE` and `RX_VALID` are cleared when a new transaction starts.

## QSPI transaction format

The current implementation uses fixed four-bit transfers for every phase:

```text
8-bit opcode → 24-bit address → 8-bit data