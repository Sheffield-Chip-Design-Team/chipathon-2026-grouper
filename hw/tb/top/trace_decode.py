"""Decode picorv32's instruction trace into a readable listing.

Does what `fusesoc_libraries/picorv32/showtrace.py` does, without its two
problems: that script hardcodes `riscv32-unknown-elf-objdump`, which does not
exist for this repo's `riscv64-unknown-elf-` toolchain, and its output carries
no symbol context, so a 100k-record trace is a wall of bare addresses.

Input is `cpu.trace`, written by ahb_debug.sv when a target sets both
DEBUG_PERIPH and CPU_TRACE (see hw/tb/top/grouper_soc_directed.core, target
`trace`). Instruction text comes from files sw/scripts/build_fw.sh already
produces on every build, so nothing here shells out to the toolchain:

    sw/build/firmware.dis   objdump -d -S -M numeric   PC -> opcode, mnemonic
    sw/build/firmware.sym   objdump -t | sort          symbol table

Output looks like:

    #00041 IRQ 0x000010b4 00084803  lbu a6,0(a6)   <memmove+0x48>  @0x000027d9
    #00042 IRQ 0x000010bc 01070023  sb  a6,0(a4)   <memmove+0x50>  @0x000027db <= 0x00000062
    #00043 IRQ 0x000010c0 fe1ff06f  j   10a0       <memmove+0x54>  > 0x000010a0
"""

import logging
import re
from pathlib import Path

log = logging.getLogger("cocotb.soc_tb.trace")

# hw/tb/top/trace_decode.py -> hw/tb/top -> hw/tb -> hw -> repo root.
# Resolved from __file__ because the simulator's cwd is the Edalize work root,
# not the repo.
REPO_ROOT = Path(__file__).resolve().parents[3]
BUILD_DIR = REPO_ROOT / "sw" / "build"

FIRMWARE_DIS = BUILD_DIR / "firmware.dis"
FIRMWARE_SYM = BUILD_DIR / "firmware.sym"

# Written by ahb_debug.sv into the simulator's working directory.
TRACE_FILE = Path("cpu.trace")
LISTING_FILE = Path("cpu_trace.dis")

# picorv32 trace_data is 36 bits, one hex value per line.
TRACE_IRQ = 1 << 35     # interrupt handler active
TRACE_ADDR = 1 << 33    # payload is a memory address
TRACE_BRANCH = 1 << 32  # payload is a branch target

# objdump disassembly line: "    1368:\t00000793 \tli\ta5,0"
_DIS_RE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]+)\s*(.*)")

# objdump -t line. The flag field is exactly 7 columns, and only a capital F
# in the last of them means "function":
#
#   00001368 g     F .text  00000024 memcpy       <- function, flags[6] == 'F'
#   00000000 l    df *ABS*  00000000 uart.c       <- file,     flags[6] == 'f'
#
# Matching [Ff] anywhere in the field would take the lowercase 'f' of 'df' and
# annotate every PC with the translation unit it came from.
_SYM_RE = re.compile(r"^([0-9a-f]+)\s(.{7})\s+(\S+)\s+([0-9a-f]+)\s+(\S+)\s*$")


class Disassembly:
    """PC -> instruction, plus a symbol table for `<name+offset>` context."""

    def __init__(self, dis_path=FIRMWARE_DIS, sym_path=FIRMWARE_SYM):
        self.insns = {}       # pc -> (opcode word, "mnemonic operands")
        self.symbols = []     # sorted [(addr, size, name)]

        self._load_dis(dis_path)
        self._load_sym(sym_path)

    def _load_dis(self, path):
        if not path.is_file():
            log.warning("no disassembly at %s - trace will show addresses only", path)
            return

        for line in path.read_text(errors="replace").splitlines():
            match = _DIS_RE.match(line)
            if match:
                pc = int(match.group(1), 16)
                self.insns[pc] = (
                    int(match.group(2), 16),
                    match.group(3).replace("\t", " ").strip(),
                )

        log.debug("loaded %d instructions from %s", len(self.insns), path.name)

    def _load_sym(self, path):
        if not path.is_file():
            return

        for line in path.read_text(errors="replace").splitlines():
            match = _SYM_RE.match(line)
            if match and match.group(2)[6] == "F":
                self.symbols.append(
                    (int(match.group(1), 16), int(match.group(4), 16), match.group(5))
                )

        self.symbols.sort()
        log.debug("loaded %d function symbols from %s", len(self.symbols), path.name)

    def symbol_for(self, pc):
        """`<name+0xoff>` for the function containing pc, or '' if unknown."""
        best = None
        for addr, size, name in self.symbols:
            if addr > pc:
                break
            # Zero-sized symbols carry no extent, so fall back to "nearest
            # preceding" for them rather than dropping them.
            if size == 0 or pc < addr + size:
                best = (addr, name)

        if best is None:
            return ""

        addr, name = best
        offset = pc - addr
        return f"<{name}>" if offset == 0 else f"<{name}+{offset:#x}>"

    def instruction(self, pc):
        return self.insns.get(pc)


def _record_width(opcode):
    """RISC-V instruction length from its low bits: 2 bytes unless 0b11."""
    return 4 if (opcode & 3) == 3 else 2


def decode(trace_path=TRACE_FILE, disasm=None):
    """Decode a trace file into a list of formatted lines.

    The PC state machine follows showtrace.py: a branch record sets the PC, an
    address record annotates the current instruction without advancing it, and
    anything else is a register write-back that advances the PC by the
    instruction width. Entering an interrupt forces the PC to PROGADDR_IRQ.
    """
    trace_path = Path(trace_path)
    if not trace_path.is_file():
        return []

    if disasm is None:
        disasm = Disassembly()

    lines = []
    pc = -1
    last_irq = False
    index = 0

    for raw in trace_path.read_text(errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue

        try:
            # ahb_debug writes 'x' for undriven bits during reset.
            data = int(raw.replace("x", "0"), 16)
        except ValueError:
            continue

        index += 1
        payload = data & 0xFFFF_FFFF
        irq = bool(data & TRACE_IRQ)
        is_addr = bool(data & TRACE_ADDR)
        is_branch = bool(data & TRACE_BRANCH)

        # PROGADDR_IRQ in cpu_ss.sv - the handler entry point.
        if irq and not last_irq:
            pc = 0x10

        if is_branch:
            payload_str = f"> {payload:#010x}"
        elif is_addr:
            payload_str = f"@{payload:#010x}"
        else:
            payload_str = f"= {payload:#010x}"

        insn = disasm.instruction(pc) if pc >= 0 else None
        if insn is not None:
            opcode, text = insn
            lines.append(
                "#%05d %-3s %#010x %08x  %-28s %-24s %s"
                % (index, "IRQ" if irq or last_irq else "", pc, opcode, text,
                   disasm.symbol_for(pc), payload_str)
            )
            if not is_addr:
                pc += _record_width(opcode)
        else:
            lines.append(
                "#%05d %-3s %s %s"
                % (index, "IRQ" if irq or last_irq else "",
                   f"{pc:#010x}" if pc >= 0 else "  (no pc)  ", payload_str)
            )
            # No disassembly for this PC means the state machine has lost the
            # thread; wait for the next branch to resynchronise.
            if pc >= 0:
                pc = -1

        if is_branch:
            pc = payload

        last_irq = irq

    return lines


def write_listing(path=LISTING_FILE, trace_path=TRACE_FILE):
    """Decode the trace to `path`. No-op when there is no trace to decode."""
    lines = decode(trace_path)
    if not lines:
        return None

    Path(path).write_text("\n".join(lines) + "\n")
    log.info("wrote %d decoded trace records to %s", len(lines), path)
    return Path(path)


def log_tail(count=64, trace_path=TRACE_FILE, level=logging.ERROR):
    """Log the last `count` decoded instructions.

    Called when a test fails: the tail of the trace is where a hung or
    misbehaving firmware actually is, and it is otherwise buried in a file
    with a hundred thousand lines.
    """
    lines = decode(trace_path)
    if not lines:
        return

    tail = lines[-count:]
    log.log(level, "last %d of %d decoded trace records:", len(tail), len(lines))
    for line in tail:
        log.log(level, "  %s", line)
