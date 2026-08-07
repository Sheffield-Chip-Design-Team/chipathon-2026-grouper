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
# Usage: build_fw.sh [--debug] [--test <name>] [--no-disasm] [--list] [--help]
#   --debug        compile with -DDEBUG, enabling debug()/debug_str() output via
#                  the ahb_debug peripheral. Pair with the DEBUG_PERIPH
#                  vlogdefine (FuseSoC target tb_top_debug), otherwise the debug
#                  peripheral isn't instantiated and the accesses will fault.
#   --test <name>  build sw/tests/<name>.c as the top level instead of
#                  sw/src/main.c. <name> is matched leniently: "hello_world",
#                  "test_hello_world", "test_hello_world.c" and a path to any
#                  .c file all work. Everything else in sw/src is still linked
#                  in, so a test only supplies main().
#   --disasm       write sw/build/firmware.dis (source-interleaved
#                  disassembly) and sw/build/firmware.sym (symbol table).
#                  On by default; addresses match the PCs in the ahb_debug
#                  instruction trace.
#   --no-disasm    skip the disassembly step.
#   --list         list the tests available in sw/tests and exit.
#   --help         show this usage and exit.
#
# Env:
#   CROSS     toolchain prefix, default riscv64-unknown-elf-
#   FW_TEST   default for --test. Lets the FuseSoC pre_build hooks pick a test
#             without a per-test hook, e.g.
#               FW_TEST=fibonnaci fusesoc run --target=debug sharc:soc_ip:grouper_soc_directed
#             An explicit --test on the command line wins.
#   FW_DEBUG  set to 1 for --debug. Lets one pre_build script serve both the
#             plain and the debug targets, selected by the script's env block
#             in the .core file rather than by a second script.
#             An explicit --debug on the command line wins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Captured before the cd to REPO_ROOT below. Run as a FuseSoC pre_build hook
# this is the Edalize work root, which is also the simulator's working
# directory - see publish_to_work_root().
INVOKE_DIR="$PWD"

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
OBJDUMP="${CROSS}objdump"

cd "$REPO_ROOT"

SRC_DIR="sw/src"
TESTS_DIR="sw/tests"
BUILD_DIR="sw/build"

# Echo the "Usage:"-onwards part of this file's own header comment, so the
# help text and the header can't drift apart.
usage() {
    awk '/^# Usage:/ {u=1} u && /^#/ {sub(/^# ?/, ""); print; next} u {exit}' "${BASH_SOURCE[0]}"
}

# Tests are the .c files in sw/tests. Printed on --list and on a bad --test.
list_tests() {
    local found=0 f
    for f in "$TESTS_DIR"/*.c; do
        [ -e "$f" ] || continue
        found=1
        printf '  %-24s (%s)\n' "$(basename "${f%.c}")" "$f"
    done
    [ "$found" = 1 ] || echo "  (none - $TESTS_DIR is empty)"
}

# Resolve a --test argument to a .c file. Accepts a bare name, the test_
# prefixed name, either with or without the .c suffix, or a path to any .c
# file. Echoes the resolved path, or nothing if there is no match.
#
# Always returns 0: this runs inside a command substitution, and a non-zero
# return would trip `set -e` at the assignment before the caller gets to
# report which test was missing.
resolve_test() {
    local name="$1" stem candidate

    # A path (contains a slash) is taken at face value so tests can live
    # outside sw/tests when needed.
    if [[ "$name" == */* ]]; then
        for candidate in "$name" "$name.c"; do
            if [ -f "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        done
        return 0
    fi

    stem="${name%.c}"
    for candidate in "$TESTS_DIR/$stem.c" "$TESTS_DIR/test_$stem.c"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 0
}

# FW_DEBUG seeds --debug the same way FW_TEST seeds --test, so a single
# pre_build script can serve both the plain and the debug FuseSoC targets.
if [ "${FW_DEBUG:-0}" = "1" ]; then
    DEBUG_FLAGS="-DDEBUG"
    BUILD_KIND="debug"
else
    DEBUG_FLAGS=""
    BUILD_KIND="release"
fi

TEST_NAME="${FW_TEST:-}"
DISASM=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug) DEBUG_FLAGS="-DDEBUG"; BUILD_KIND="debug" ;;
        --test)
            [ "$#" -ge 2 ] || { echo "ERROR: --test needs a test name" >&2; exit 1; }
            TEST_NAME="$2"; shift ;;
        --test=*) TEST_NAME="${1#--test=}" ;;
        --disasm) DISASM=1 ;;
        --no-disasm) DISASM=0 ;;
        --list) echo "Tests available in $TESTS_DIR:"; list_tests; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$1' (expected --debug, --test, --disasm, --no-disasm, --list or --help)" >&2; exit 1 ;;
    esac
    shift
done

# Pick the translation unit that supplies main(). Default is sw/src/main.c.
if [ -n "$TEST_NAME" ]; then
    TOP_SRC="$(resolve_test "$TEST_NAME")"
    if [ -z "$TOP_SRC" ]; then
        echo "ERROR: no test matching '$TEST_NAME'." >&2
        if [[ "$TEST_NAME" == */* ]]; then
            echo "       Looked for '$TEST_NAME' and '$TEST_NAME.c'." >&2
        else
            stem="${TEST_NAME%.c}"
            echo "       Looked for $TESTS_DIR/$stem.c and $TESTS_DIR/test_$stem.c." >&2
            echo "Tests available in $TESTS_DIR:" >&2
            list_tests >&2
        fi
        exit 1
    fi
    # An empty test would fail much later with a bare "undefined reference to
    # main" out of the linker - say what actually went wrong.
    if [ ! -s "$TOP_SRC" ]; then
        echo "ERROR: test '$TOP_SRC' is empty - it needs to define main()." >&2
        exit 1
    fi
    TOP_KIND="$TEST_NAME -> $TOP_SRC"
else
    TOP_SRC="$SRC_DIR/main.c"
    TOP_KIND="$TOP_SRC (default)"
fi

# Matches the picorv32 configuration in hw/rtl/cpu_ss.sv: RV32E (16 registers,
# ENABLE_REGS_16_31=0) plus M and C. Building rv32i* here would emit x16-x31,
# which the CPU does not have.
MARCH="-march=rv32emc -mabi=ilp32e"
INCS="-I$SRC_DIR -I$SRC_DIR/lib -I$SRC_DIR/uart -I$SRC_DIR/debug -I$SRC_DIR/spi_m -I$SRC_DIR/gpio -I$TESTS_DIR"

# -fno-builtin is load-bearing, not decorative: sw/src/lib defines printf,
# memcpy and other libc-reserved names, and without it GCC would rewrite calls
# to them (printf("x\n") -> puts, and so on) against its own assumptions.
#
# -fno-tree-loop-distribute-patterns is the companion to that: at -Os the loop
# distribution pass recognises the byte-copy loop *inside* our own memcpy and
# rewrites it into a call to memcpy - i.e. infinite recursion. -fno-builtin
# alone does not reliably suppress it.
#
# -ffunction-sections/-fdata-sections plus --gc-sections below let the linker
# drop library functions the image never calls. That is what keeps a general
# purpose library affordable against the 8 KiB ROM window in sw/soc.ld.
CFLAGS="$MARCH -Os -g -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns"
CFLAGS="$CFLAGS -ffunction-sections -fdata-sections -Wall -Wextra $DEBUG_FLAGS $INCS"
LDFLAGS="$MARCH -nostdlib -Wl,--gc-sections -Wl,-T,sw/soc.ld -Wl,-Map,$BUILD_DIR/firmware.map"

# custom_ops.S, irq_vec.S and the headers are pulled in by textual #include,
# so they are not compiled as separate translation units. $TOP_SRC supplies
# main() and is the only entry that changes with --test.
SOURCES=(
    "$SRC_DIR/start.S"
    "$SRC_DIR/reset_handler.c"
    "$TOP_SRC"
    "$SRC_DIR/irq.c"
    "$SRC_DIR/debug/debug.c"
    "$SRC_DIR/uart/uart.c"
    "$SRC_DIR/spi_m/spi_m.c"
    "$SRC_DIR/lib/gio.c"
    "$SRC_DIR/lib/gstr.c"
    "$SRC_DIR/lib/gtest.c"
)

echo "=== build_fw.sh: building GrouperSoC firmware ($BUILD_KIND) ==="
echo "    repo root : $REPO_ROOT"
echo "    toolchain : $CC"
echo "    top level : $TOP_KIND"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

OBJECTS=()
for src in "${SOURCES[@]}"; do
    # Flatten the path under sw/src into the object name; anything from
    # outside it (a --test top level) just uses its basename.
    if [[ "$src" == "$SRC_DIR/"* ]]; then
        obj="$BUILD_DIR/$(echo "${src#$SRC_DIR/}" | tr '/' '_')"
    else
        obj="$BUILD_DIR/$(basename "$src")"
    fi
    obj="${obj%.*}.o"
    echo "Compiling $src -> $obj"
    "$CC" $CFLAGS -c "$src" -o "$obj"
    OBJECTS+=("$obj")
done

echo "Linking $BUILD_DIR/firmware.elf"
"$CC" $LDFLAGS "${OBJECTS[@]}" -o "$BUILD_DIR/firmware.elf"

echo "Converting to $BUILD_DIR/firmware.bin"
"$OBJCOPY" -O binary "$BUILD_DIR/firmware.elf" "$BUILD_DIR/firmware.bin"

# Disassembly, on by default. The addresses line up with the PCs in the
# ahb_debug instruction trace (CPU_TRACE target), which is the main reason to
# always have it around - chasing a trace without it is guesswork.
if [ "$DISASM" = 1 ]; then
    echo "Disassembling to $BUILD_DIR/firmware.dis"
    # -d disassembles the loaded sections, -S interleaves the source that -g
    # recorded, and -M numeric keeps the register names matching the trace.
    "$OBJDUMP" -d -S -M numeric "$BUILD_DIR/firmware.elf" > "$BUILD_DIR/firmware.dis"

    echo "Writing $BUILD_DIR/firmware.sym"
    "$OBJDUMP" -t "$BUILD_DIR/firmware.elf" | sort > "$BUILD_DIR/firmware.sym"
fi

echo "Generating code.hex"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/firmware.bin" "$BUILD_DIR/code.hex" 4 hex

echo "Generating code.vmem"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/firmware.bin" "$BUILD_DIR/code.vmem" 4 vmem

# Stamp what was built alongside the image. The testbench reads this at time 0
# - as plain text, not a `define, so that it is loaded when the simulation
# starts exactly like code.hex is and cannot report a different firmware from
# the one actually in the ROM.
echo "Generating fw_id.txt"
echo "$TOP_SRC ($BUILD_KIND)" > "$BUILD_DIR/fw_id.txt"

# ahb_rom.sv loads code.hex with $readmemh, which resolves its path against the
# simulator's working directory rather than any include path. Run as a FuseSoC
# hook, cwd is the Edalize work root - the same directory the simulator is
# later launched from - so drop a copy of the image there.
#
# This is what decouples the firmware from verilation. Edalize makes the hook
# an *order-only* prerequisite:
#
#   Vtop.mk: ... ../../../sw/code.vmem ... | pre_build
#
# so make stats the image and decides whether to re-verilate before this script
# ever runs. Anything baked in at verilation time is therefore always one build
# stale; anything read at simulation start is not.
publish_to_work_root() {
    # Only act on something that really looks like an Edalize work root.
    [ "$INVOKE_DIR" != "$REPO_ROOT" ] || return 0
    compgen -G "$INVOKE_DIR/"*.vc >/dev/null || return 0

    echo "Publishing code.hex and fw_id.txt to the work root ($INVOKE_DIR)"
    cp "$BUILD_DIR/code.hex" "$INVOKE_DIR/code.hex"
    cp "$BUILD_DIR/fw_id.txt" "$INVOKE_DIR/fw_id.txt"
}

# Publish only what changed, so an unchanged firmware doesn't churn mtimes and
# cause a pointless re-verilation.
for f in code.hex code.vmem; do
    if cmp -s "$BUILD_DIR/$f" "sw/$f"; then
        continue
    fi
    echo "Updating sw/$f"
    cp "$BUILD_DIR/$f" "sw/$f"
done

publish_to_work_root

echo "=== build_fw.sh: done ($BUILD_KIND, $(wc -c < "$BUILD_DIR/firmware.bin") bytes) ==="
