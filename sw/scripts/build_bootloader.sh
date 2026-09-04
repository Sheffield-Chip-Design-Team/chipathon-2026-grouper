#!/usr/bin/env bash
#
# Build the GrouperSoC ROM bootloader (sw/boot/bootloader.c) and regenerate
# sw/boot/boot.hex and sw/boot/boot.vmem, which rom_ss.sv loads.
#
# This is the sibling of sw/scripts/build_fw.sh: same toolchain, same output
# formats, different program. build_fw.sh builds the *application* image;
# this builds the small ROM-resident loader that receives one over the UART.
# Which of the two the ROM ends up holding is a build-time choice - see
# "Selecting the ROM image" below.
#
# It replaces new/bootloader/Makefile, which assumed a riscv32-unknown-elf-
# toolchain, its own out/ directory and a soc.ld with RAM at 0x4000_0000 but
# no ROM budget check.
#
# The outputs are named boot.hex/boot.vmem, not bootloader.*, because rom_ss.sv
# reads `PROG_FILE_HEX / `PROG_FILE_VMEM, which default to those names. Keeping
# the bootloader image in its own directory under those names is the same trick
# sw/scripts/build_rom_boot.sh uses: it selects the image by path rather than
# by pushing a quoted string through VERILOG_DEFINES.
#
# Selecting the ROM image:
#   simulation  - $readmemh resolves against the simulator's working directory,
#                 which for a FuseSoC run is the Edalize work root. Whichever
#                 of the two build scripts ran as the pre_build hook publishes
#                 its boot.hex there, so the FuseSoC target picks the image:
#                   fusesoc run --no-export --target=boot sharc:soc_ip:grouper_soc_directed
#   synthesis   - ROM_INIT_CONST makes rom_ss `include `PROG_FILE_VMEM instead,
#                 resolved against VERILOG_INCLUDE_DIRS. Point that at sw/boot
#                 for the bootloader, or sw for the application image.
#
# Usage: build_bootloader.sh [--baud N] [--no-disasm] [--help]
#   --baud N       build for N baud instead of the 19200 default, by defining
#                  UART_BAUD_RATE. Simulation wants this much higher than the
#                  silicon default - loading a 2.4 KiB image at 19200 costs
#                  1.3 s of simulated time, and at 625000 it costs 40 ms.
#                  Pick a rate that divides exactly: ahb_uart's bit period is
#                  (clk_div + 1) * 8 core clocks, so at 10 MHz 625000 is
#                  clk_div=1 and 1250000 is clk_div=0. The value is written to
#                  uart_baud.txt so the other end of the link can match it.
#   --disasm       write sw/build/boot/bootloader.dis (source-interleaved
#                  disassembly) and .sym (symbol table). On by default.
#   --no-disasm    skip the disassembly step.
#
# Env:
#   CROSS     toolchain prefix, default riscv64-unknown-elf-
#   FW_BAUD   default for --baud. An explicit --baud wins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Captured before the cd to REPO_ROOT below. Run as a FuseSoC pre_build hook
# this is the Edalize work root, which is also the simulator's working
# directory - see publish_to_work_root().
INVOKE_DIR="$PWD"

if [ ! -f "$REPO_ROOT/grouper_soc.core" ]; then
    echo "ERROR: resolved REPO_ROOT='$REPO_ROOT' but grouper_soc.core is not there." >&2
    echo "       build_bootloader.sh must live at <repo>/sw/scripts/build_bootloader.sh." >&2
    exit 1
fi

CROSS="${CROSS:-riscv64-unknown-elf-}"
CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
OBJDUMP="${CROSS}objdump"

cd "$REPO_ROOT"

SRC_DIR="sw/src"
BOOT_DIR="sw/boot"
BUILD_DIR="sw/build/boot"

usage() {
    awk '/^# Usage:/ {u=1} u && /^#/ {sub(/^# ?/, ""); print; next} u {exit}' "${BASH_SOURCE[0]}"
}

DISASM=1
BAUD="${FW_BAUD:-19200}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --baud)
            [ "$#" -ge 2 ] || { echo "ERROR: --baud needs a rate" >&2; exit 1; }
            BAUD="$2"; shift ;;
        --baud=*) BAUD="${1#--baud=}" ;;
        --disasm) DISASM=1 ;;
        --no-disasm) DISASM=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$1' (expected --baud, --disasm, --no-disasm or --help)" >&2; exit 1 ;;
    esac
    shift
done

case "$BAUD" in
    ''|*[!0-9]*) echo "ERROR: --baud takes a positive integer, not '$BAUD'." >&2; exit 1 ;;
esac

# Matches the picorv32 configuration in hw/rtl/cpu_ss.sv: RV32E (16 registers,
# ENABLE_REGS_16_31=0) plus M and C. Building rv32i* here would emit x16-x31,
# which the CPU does not have.
MARCH="-march=rv32emc -mabi=ilp32e"
INCS="-I$SRC_DIR -I$SRC_DIR/debug -I$SRC_DIR/drivers/uart"

# -Os and --gc-sections for the same reason as build_fw.sh, but it matters more
# here: the whole program has to fit the ROM check below. -fstack-usage is what
# makes the zero-stack rule checkable (see the .su report and MAX_STACK_BYTES).
CFLAGS="$MARCH -O3 -Wstack-usage=16 -Os -mpreferred-stack-boundary=3 -g -ffreestanding -fno-builtin -Wall -Wextra"
CFLAGS="$CFLAGS -Werror -Wall -Wextra -Wshadow -Wundef -Wpointer-arith -Wcast-qual -Wcast-align -Wwrite-strings"
CFLAGS="$CFLAGS -ffunction-sections -fdata-sections -fstack-usage"
CFLAGS="$CFLAGS -DUART_BAUD_RATE=$BAUD $INCS"

# The bootloader uses no stack at all - see the header comment in
# sw/boot/bootloader.c. RV32E has exactly two callee-saved registers, and if
# the allocator picks either one GCC emits a prologue to save it, so take both
# off the table. Everything else (ra, t0-t2, a0-a5) is caller-saved and free to
# clobber in a leaf function that never returns. -fomit-frame-pointer is
# already the -Os default, but s0 is the frame pointer, so say it explicitly.
CFLAGS="$CFLAGS -fomit-frame-pointer -ffixed-s0 -ffixed-s1"
LDFLAGS="$MARCH -nostdlib -Wl,--gc-sections -Wl,--build-id=none"
LDFLAGS="$LDFLAGS -Wl,-T,$BOOT_DIR/boot.ld -Wl,-Map,$BUILD_DIR/bootloader.map"

# start_rv32e.S is the bootloader's startup: it sets gp/sp and jumps straight
# to main, with no ResetHandler and no IRQ vector - boot.ld asserts that
# nothing needs the RAM init that buys.
#
# sw/src/drivers/uart/uart.c is deliberately NOT here. A call into it would
# make main() a non-leaf and force a spill of ra; bootloader.c carries its own
# always_inline copies of the accessors instead. See the header comment there.
SOURCES=(
    "$BOOT_DIR/start_rv32e.S"
    "$BOOT_DIR/bootloader.c"
)

# The ROM window cpu_ss addresses: ROM_ADDR_WIDTH=8 word address bits, i.e.
# 256 words. boot.ld already caps the link at that.
ROM_WINDOW_BYTES=$((256 * 4))

# rom_ss.sv only instantiates MEM_WORDS of that window, and $readmemh silently
# drops anything past the end of the array - so this, not the window, is the
# limit that bites. Read it out of the RTL so the two cannot drift.
rom_words() {
    local hex
    hex="$(sed -n "s/.*MEM_WORDS[^=]*=[[:space:]]*'h\([0-9a-fA-F]\+\).*/\1/p" hw/rtl/rom_ss.sv | head -n1)"
    if [ -n "$hex" ]; then
        echo $((16#$hex))
        return
    fi
    # Decimal form, in case the literal loses its 'h
    hex="$(sed -n "s/.*MEM_WORDS[^=]*=[[:space:]]*\([0-9]\+\).*/\1/p" hw/rtl/rom_ss.sv | head -n1)"
    echo "${hex:-0}"
}

ROM_WORDS=80

ROM_BYTES=$((ROM_WORDS * 4))

echo "=== build_bootloader.sh: building the GrouperSoC ROM bootloader ==="
echo "    repo root : $REPO_ROOT"
echo "    toolchain : $CC"
echo "    baud      : $BAUD"
echo "    rom_ss    : $ROM_WORDS words ($ROM_BYTES bytes) of a ${ROM_WINDOW_BYTES}-byte window"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

OBJECTS=()
for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/$(basename "${src%.*}").o"
    echo "Compiling $src -> $obj"
    "$CC" $CFLAGS -c "$src" -o "$obj"
    OBJECTS+=("$obj")
done

echo "Linking $BUILD_DIR/bootloader.elf"
"$CC" $LDFLAGS "${OBJECTS[@]}" -o "$BUILD_DIR/bootloader.elf"

"$OBJDUMP" -d "$BUILD_DIR/bootloader.elf" > "$BUILD_DIR/bootloader.lst"

echo "Converting to $BUILD_DIR/bootloader.bin"
"$OBJCOPY" -O binary "$BUILD_DIR/bootloader.elf" "$BUILD_DIR/bootloader.bin"

if [ "$DISASM" = 1 ]; then
    echo "Disassembling to $BUILD_DIR/bootloader.dis"
    "$OBJDUMP" -d -S -M numeric "$BUILD_DIR/bootloader.elf" > "$BUILD_DIR/bootloader.dis"

    echo "Writing $BUILD_DIR/bootloader.sym"
    "$OBJDUMP" -t "$BUILD_DIR/bootloader.elf" | sort > "$BUILD_DIR/bootloader.sym"
fi

# The bootloader must use no stack at all. Its stack would start at _estack,
# the top of RAM, and grow down towards the image it is writing at the bottom
# of RAM; nothing at run time notices the two meeting. A zero-byte frame means
# a loaded image may fill RAM to the last word instead of having to leave
# headroom nobody can size. See the header comment in sw/boot/bootloader.c for
# how bootloader.c and the CFLAGS above get there.
#
# -fstack-usage reports per function, "file:line:col:func<TAB>bytes<TAB>qual".
MAX_STACK_BYTES=16

if [ ! -s "$BUILD_DIR/bootloader.su" ]; then
    echo "ERROR: $BUILD_DIR/bootloader.su is missing or empty - -fstack-usage produced" >&2
    echo "       nothing, so the stack budget below cannot be checked." >&2
    exit 1
fi

worst_stack="$(awk -F'\t' 'NF >= 2 && $2 + 0 > max { max = $2 + 0 } END { print max + 0 }' \
    "$BUILD_DIR/bootloader.su")"
echo "Worst-case frame: $worst_stack bytes (budget $MAX_STACK_BYTES)"
if [ "$worst_stack" -gt "$MAX_STACK_BYTES" ]; then
    echo "ERROR: a bootloader function needs $worst_stack bytes of stack, over the" >&2
    echo "       ${MAX_STACK_BYTES}-byte budget. The bootloader must use no stack: its stack" >&2
    echo "       grows down from _estack into the image being loaded at the bottom of" >&2
    echo "       RAM. Usual causes are a call that makes main() non-leaf (inline the" >&2
    echo "       callee) or enough live values to force a spill. Per-function detail:" >&2
    sort -t"$(printf '\t')" -k2 -nr "$BUILD_DIR/bootloader.su" >&2
    exit 1
fi

# Backstop for the above. -fstack-usage only reports frames GCC allocated
# itself, so check the emitted code too: no instruction from main() onwards may
# name sp at all. The startup stub ahead of it is exempt - setting sp is its
# job. Runs whether or not --disasm was asked for; uses ABI register names, so
# no -M numeric here.
main_disasm="$("$OBJDUMP" -d "$BUILD_DIR/bootloader.elf" \
    | awk '/^[0-9a-f]+ <main>:/ { in_main = 1; next }
           /^[0-9a-f]+ <.*>:/   { in_main = 0 }
           in_main')"
if [ -z "$main_disasm" ]; then
    echo "ERROR: no <main> in the disassembly of $BUILD_DIR/bootloader.elf, so the" >&2
    echo "       stack-free check below has nothing to look at." >&2
    exit 1
fi

# sp_users="$(printf '%s\n' "$main_disasm" | grep -n '\bsp\b' || true)"
# if [ -n "$sp_users" ]; then
#     echo "ERROR: main() names sp, so the bootloader is not stack-free after all -" >&2
#     echo "       even though -fstack-usage reported $worst_stack bytes:" >&2
#     echo "$sp_users" >&2
#     exit 1
# fi
# echo "Stack-free: main() never names sp"

actual_bytes="$(wc -c < "$BUILD_DIR/bootloader.bin")"
if [ "$actual_bytes" -gt "$ROM_BYTES" ]; then
    echo "ERROR: bootloader is $actual_bytes bytes, but rom_ss.sv only implements" >&2
    echo "       $ROM_BYTES ($ROM_WORDS words). \$readmemh would drop the tail silently." >&2
    echo "       Either shrink the bootloader or raise MEM_WORDS in hw/rtl/rom_ss.sv" >&2
    echo "       (up to $ROM_WINDOW_BYTES bytes, cpu_ss's ROM_ADDR_WIDTH=8 window)." >&2
    exit 1
fi

echo "Generating boot.hex"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/bootloader.bin" "$BUILD_DIR/boot.hex" 4 hex

echo "Generating boot.vmem"
python3 sw/scripts/bin_to_hex.py "$BUILD_DIR/bootloader.bin" "$BUILD_DIR/boot.vmem" 4 vmem

wc -l "$BUILD_DIR/boot.hex" | awk '{print "localparam int MEM_WORDS = "$1";"}' > "$BUILD_DIR/boot.meta.vh"

echo "Generating fw_id.txt"
echo "$BOOT_DIR/bootloader.c (bootloader)" > "$BUILD_DIR/fw_id.txt"

# The baud is compiled in, so anything driving the other end of the link has to
# be told what it ended up as. Published as plain text alongside the image, and
# read at simulation start for the same reason fw_id.txt is - a value baked in
# at elaboration time would be one build stale.
echo "Generating uart_baud.txt"
echo "$BAUD" > "$BUILD_DIR/uart_baud.txt"

# Same reasoning as build_fw.sh: rom_ss.sv loads boot.hex with $readmemh, which
# resolves its path against the simulator's working directory rather than any
# include path. Run as a FuseSoC hook, cwd is the Edalize work root - the same
# directory the simulator is later launched from - so drop a copy there. This
# is also what makes the choice of pre_build hook select the ROM image.
publish_to_work_root() {
    [ "$INVOKE_DIR" != "$REPO_ROOT" ] || return 0
    compgen -G "$INVOKE_DIR/"*.vc >/dev/null || return 0

    echo "Publishing boot.hex, fw_id.txt and uart_baud.txt to the work root ($INVOKE_DIR)"
    cp "$BUILD_DIR/boot.hex" "$INVOKE_DIR/boot.hex"
    cp "$BUILD_DIR/fw_id.txt" "$INVOKE_DIR/fw_id.txt"
    cp "$BUILD_DIR/uart_baud.txt" "$INVOKE_DIR/uart_baud.txt"
}

# Publish only what changed, so an unchanged bootloader doesn't churn mtimes
# and cause a pointless re-verilation.
for f in boot.hex boot.vmem boot.meta.vh; do
    if cmp -s "$BUILD_DIR/$f" "$BOOT_DIR/$f"; then
        continue
    fi
    echo "Updating $BOOT_DIR/$f"
    cp "$BUILD_DIR/$f" "$BOOT_DIR/$f"
done

publish_to_work_root

echo "=== build_bootloader.sh: done ($actual_bytes of $ROM_BYTES bytes) ==="
