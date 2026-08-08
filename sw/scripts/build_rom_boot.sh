#!/usr/bin/env bash
#
# Build the dry-run boot ROM and regenerate sw/dry_run/code.vmem, which
# ahb_rom.sv includes when built with ROM_INIT_CONST (the synthesisable ROM
# form - see librelane/classic/dry_run_config.yaml).
#
# The output is named code.vmem, not rom_boot.vmem, because ahb_rom.sv
# includes `PROG_FILE_VMEM which defaults to "code.vmem". Putting the dry-run
# image under its own directory and pointing VERILOG_INCLUDE_DIRS there
# selects it without having to push a quoted string through VERILOG_DEFINES.
#
# Usage: build_rom_boot.sh
#
# Env:
#   CROSS   toolchain prefix, default riscv64-unknown-elf-

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -f "$REPO_ROOT/grouper_soc.core" ]; then
    echo "ERROR: resolved REPO_ROOT='$REPO_ROOT' but grouper_soc.core is not there." >&2
    echo "       build_rom_boot.sh must live at <repo>/sw/scripts/build_rom_boot.sh." >&2
    exit 1
fi

CROSS="${CROSS:-riscv64-unknown-elf-}"
CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
OBJDUMP="${CROSS}objdump"

cd "$REPO_ROOT"

SRC_DIR="sw/dry_run"
BUILD_DIR="sw/build/dry_run"

# Matches the picorv32 configuration in hw/rtl/cpu_ss.sv
# (ENABLE_REGS_16_31=0, COMPRESSED_ISA=1, ENABLE_MUL/DIV=1).
MARCH="-march=rv32emc -mabi=ilp32e"

# 64 bytes, matching ahb_rom.sv's MEM_WIDTH=6 under `DRY_RUN. The stub pads
# itself to this size with .org; the check below catches it drifting.
ROM_BYTES=64

echo "=== build_rom_boot.sh: building the dry-run boot ROM ==="
echo "    repo root : $REPO_ROOT"
echo "    toolchain : $CC"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# -Ttext=0 puts the reset vector at PROGADDR_RESET. -nostdlib because the stub
# has no runtime and no libc: it is four instructions and a pad.
echo "Assembling $SRC_DIR/rom_boot.S -> $BUILD_DIR/rom_boot.elf"
"$CC" $MARCH -nostdlib -Wl,-Ttext=0 -Wl,--build-id=none \
    "$SRC_DIR/rom_boot.S" -o "$BUILD_DIR/rom_boot.elf"

echo "Converting to $BUILD_DIR/rom_boot.bin"
"$OBJCOPY" -O binary "$BUILD_DIR/rom_boot.elf" "$BUILD_DIR/rom_boot.bin"

actual_bytes="$(wc -c < "$BUILD_DIR/rom_boot.bin")"
if [ "$actual_bytes" != "$ROM_BYTES" ]; then
    echo "ERROR: boot ROM is $actual_bytes bytes, expected exactly $ROM_BYTES." >&2
    echo "       Either the .org pad in $SRC_DIR/rom_boot.S or ahb_rom.sv's" >&2
    echo "       DRY_RUN MEM_WIDTH has moved - they have to agree." >&2
    exit 1
fi

echo "Disassembling to $BUILD_DIR/rom_boot.dis"
"$OBJDUMP" -d -M numeric "$BUILD_DIR/rom_boot.elf" > "$BUILD_DIR/rom_boot.dis"

echo "Generating code.vmem"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/rom_boot.bin" "$BUILD_DIR/code.vmem" 4 vmem

if cmp -s "$BUILD_DIR/code.vmem" "$SRC_DIR/code.vmem"; then
    echo "$SRC_DIR/code.vmem is already up to date"
else
    echo "Updating $SRC_DIR/code.vmem"
    cp "$BUILD_DIR/code.vmem" "$SRC_DIR/code.vmem"
fi

echo "=== build_rom_boot.sh: done ($actual_bytes bytes) ==="
