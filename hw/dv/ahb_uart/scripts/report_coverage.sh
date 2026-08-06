#!/usr/bin/env bash
# CAPI2 script hook (see ahb_uart_cocotb.core's `scripts`/`hooks` sections).
# Scripts run from the work root, where the simulation writes coverage.dat.
set -euo pipefail
verilator_coverage coverage.dat
