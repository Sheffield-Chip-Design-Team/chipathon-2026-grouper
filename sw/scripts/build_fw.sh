#!/usr/bin/env bash
#
# Build the GrouperSoC bring-up firmware and regenerate sw/code.hex and
# sw/code.vmem, which the ROM model (hw/rtl/rom/ahb_rom.sv) loads.
#
# Invoked directly, or via the FuseSoC pre_build hooks declared in
# grouper_soc.core (targets tb_top and tb_top_debug). Those hooks run with
# the FuseSoC *work root* as cwd, not the repo root, so every path used here
# is anchored to REPO_ROOT (resolved from this script's own location) rather
# than to cwd.
#
# Usage: build_fw.sh [--debug]
#   --debug   compile with -DDEBUG, enabling debug()/debug_str() output via
#             the ahb_debug peripheral. Pair with the DEBUG_PERIPH vlogdefine
#             (FuseSoC target tb_top_debug), otherwise the debug peripheral
#             isn't instantiated and the accesses will fault.
#
# Env:
#   CROSS   toolchain prefix, default riscv64-unknown-elf-

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Fail loudly if REPO_ROOT didn't resolve to the actual repo - a silently
# wrong root would write code.hex/code.vmem somewhere harmless-looking and
# leave a stale image in place for the simulation.
if [ ! -f "$REPO_ROOT/grouper_soc.core" ]; then
    echo "ERROR: resolved REPO_ROOT='$REPO_ROOT' but grouper_soc.core is not there." >&2
    echo "       build_fw.sh must live at <repo>/sw/scripts/build_fw.sh." >&2
    exit 1
fi

CROSS="${CROSS:-riscv64-unknown-elf-}"
CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"

DEBUG_FLAGS=""
BUILD_KIND="release"
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG_FLAGS="-DDEBUG"; BUILD_KIND="debug" ;;
        *) echo "ERROR: unknown argument '$arg' (expected --debug)" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"

SRC_DIR="sw/src"
BUILD_DIR="sw/build"

MARCH="-march=rv32im -mabi=ilp32"
INCS="-I$SRC_DIR -I$SRC_DIR/uart -I$SRC_DIR/debug -I$SRC_DIR/spi_m"
CFLAGS="$MARCH -Os -g -ffreestanding -fno-builtin -Wall -Wextra $DEBUG_FLAGS $INCS"
LDFLAGS="$MARCH -nostdlib -Wl,-T,sw/soc.ld -Wl,-Map,$BUILD_DIR/firmware.map"

# custom_ops.S, irq_vec.S and the headers are pulled in by textual #include,
# so they are not compiled as separate translation units.
SOURCES=(
    "$SRC_DIR/start.S"
    "$SRC_DIR/reset_handler.c"
    "$SRC_DIR/main.c"
    "$SRC_DIR/irq.c"
    "$SRC_DIR/debug/debug.c"
    "$SRC_DIR/uart/uart.c"
    "$SRC_DIR/spi_m/spi_m.c"
)

echo "=== build_fw.sh: building GrouperSoC firmware ($BUILD_KIND) ==="
echo "    repo root : $REPO_ROOT"
echo "    toolchain : $CC"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

OBJECTS=()
for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/$(echo "${src#$SRC_DIR/}" | tr '/' '_')"
    obj="${obj%.*}.o"
    echo "Compiling $src -> $obj"
    "$CC" $CFLAGS -c "$src" -o "$obj"
    OBJECTS+=("$obj")
done

echo "Linking $BUILD_DIR/firmware.elf"
"$CC" $LDFLAGS "${OBJECTS[@]}" -o "$BUILD_DIR/firmware.elf"

echo "Converting to $BUILD_DIR/firmware.bin"
"$OBJCOPY" -O binary "$BUILD_DIR/firmware.elf" "$BUILD_DIR/firmware.bin"

echo "Generating sw/code.hex"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/firmware.bin" sw/code.hex 4 hex

echo "Generating sw/code.vmem"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/firmware.bin" sw/code.vmem 4 vmem

echo "=== build_fw.sh: done ($BUILD_KIND, $(wc -c < "$BUILD_DIR/firmware.bin") bytes) ==="
