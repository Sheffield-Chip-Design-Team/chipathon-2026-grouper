#!/usr/bin/env bash
# CAPI2 `hooks: post_run:` cannot do this: edalize's cocotb-aware Sim flow
# (edalize/flows/sim.py, confirmed against 0.6.8 - the latest release)
# invokes the simulator directly and never runs the Makefile pre_run/post_run
# hook chain. This wrapper is the reliable substitute - run the sim, then
# report coverage from the same work root, in one command.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work_root="$repo_root/build/sharc_comms_ip_ahb_uart_pyuvm_0.0.1/default"

cd "$repo_root"
fusesoc run --target=default sharc:comms_ip:ahb_uart_pyuvm "$@"

cd "$work_root"
bash "$repo_root/hw/dv/ahb_uart/scripts/report_coverage.sh"
