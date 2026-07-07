#!/bin/bash

set -euo pipefail

# https://github.com/splinedrive/gf180mcu-kianv-rv32ima-sv32/blob/main/librelane/config.yaml

PDK_NAME=gf180mcuD

#STD_CELL_LIB=gf180mcu_fd_sc_mcu7t5v0
STD_CELL_LIB=gf180mcu_fd_sc_mcu9t5v0

cd "$(dirname "$0")"

source sak-pdk-script.sh ${PDK_NAME} ${STD_CELL_LIB}

export PDK_ROOT=/foss/designs/gf180mcu_picorv32_hello

make librelane SLOT=1x1 PDK=gf180mcuD PDK_ROOT=./gf180mcu
