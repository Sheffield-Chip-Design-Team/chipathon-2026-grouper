"""Wire protocol for the GrouperSoC ROM bootloader.

The bootloader (sw/boot/bootloader.c) runs from ROM out of reset, accepts
commands on the UART, and can swap the memory banks to hand over to an image it
has just received. This module is the host half of that conversation.

It is deliberately pure - it builds and parses bytes and does no I/O, and
imports neither cocotb nor pyserial - so the same code serves both ends:

    hw/tb/top/test_soc.py   drives the simulated UART pins
    sw/scripts/load_fw.py   drives a real serial port

Protocol, as implemented by main() in sw/boot/bootloader.c:

    '\\n'                            echoed back, a liveness check
    'R' <addr:4> <len:4>            read len WORDS from addr, each echoed back
    'W' <addr:4> <len:4> <word:4>.. write len WORDS to addr
    'B'                             swap the banks and reboot into RAM

Two things about it are easy to get wrong:

  * len is a count of 32-bit words, not of bytes.
  * every 32-bit value on the wire is big-endian - rx_uint()/tx_uint() shift
    from the top of the word - while an image file is a little-endian byte
    stream. word_bytes()/image_words() are the only places that conversion
    happens.

There is no acknowledgement for a write, so a byte dropped anywhere in a 'W'
silently shifts everything after it. read_words() against what was just written
is the only way to know it arrived; both callers default that check on.
"""

import struct

# Commands. Single bytes, matching the switch in bootloader.c's main().
CMD_PING = b"\n"
CMD_READ = b"R"
CMD_WRITE = b"W"
CMD_BOOT = b"B"

# The greeting the bootloader prints once it is ready for commands.
GREETING = "hi"

# Where RAM answers while the bootloader is running, i.e. with bank_switch
# still 0. Matches RAM_BASE in sw/src/config.h and the decode on
# mem_la_addr[31:29] in hw/rtl/cpu_ss.sv. After 'B' the same memory appears at
# zero, which is what sw/boot/ram.ld links for - so an image is *written* here
# and *runs* at 0.
RAM_BASE = 0x4000_0000

# cpu_ss's RAM_ADDR_WIDTH=10 (see hw/rtl/digital_ss.sv), 1024 words.
RAM_SIZE = 4 * 1024

WORD_BYTES = 4


class BootloaderError(Exception):
    """Malformed response, or a request that cannot be sent as it stands."""


def word_bytes(value):
    """One 32-bit value as the bootloader expects it: big-endian."""
    return struct.pack(">I", value & 0xFFFF_FFFF)


def image_words(image):
    """A firmware image as a list of 32-bit words.

    `image` is a path or raw bytes. The file is the little-endian byte stream
    objcopy produced (sw/build/firmware.bin), so this is the little-endian
    decode; the big-endian re-encoding for the wire happens in frame_write.

    A trailing partial word is zero-padded. That only affects bytes past the
    end of the image, which nothing reads.
    """
    if isinstance(image, (bytes, bytearray)):
        data = bytes(image)
    else:
        with open(image, "rb") as handle:
            data = handle.read()

    if not data:
        raise BootloaderError(f"{image!r} is empty - nothing to load")

    pad = (-len(data)) % WORD_BYTES
    data += b"\x00" * pad
    return list(struct.unpack(f"<{len(data) // WORD_BYTES}I", data))


def check_image(words, addr=RAM_BASE, ram_base=RAM_BASE, ram_size=RAM_SIZE):
    """Reject an image that would not fit before any of it is sent.

    The bootloader does no bounds checking: a 'W' past the end of RAM just
    writes to the aliases of it, quietly corrupting the start of the image.
    """
    size = len(words) * WORD_BYTES
    end = ram_base + ram_size

    if addr < ram_base or addr >= end:
        raise BootloaderError(
            f"load address {addr:#010x} is outside RAM "
            f"({ram_base:#010x}-{end - 1:#010x})"
        )
    if addr + size > end:
        raise BootloaderError(
            f"image is {size} bytes at {addr:#010x}, which overruns RAM by "
            f"{addr + size - end} bytes. RAM is {ram_size} bytes "
            f"(cpu_ss RAM_ADDR_WIDTH=10) and has to hold code, data, bss and "
            f"the stack - check the ram.ld link"
        )
    if addr % WORD_BYTES:
        raise BootloaderError(f"load address {addr:#010x} is not word aligned")


def frame_ping():
    """Liveness check. The bootloader echoes a newline back."""
    return CMD_PING


def frame_write(addr, words):
    """'W' - write `words` to `addr`."""
    out = bytearray(CMD_WRITE)
    out += word_bytes(addr)
    out += word_bytes(len(words))
    for word in words:
        out += word_bytes(word)
    return bytes(out)


def frame_read(addr, count):
    """'R' - request `count` words from `addr`. Response is 4*count bytes."""
    out = bytearray(CMD_READ)
    out += word_bytes(addr)
    out += word_bytes(count)
    return bytes(out)


def frame_boot():
    """'B' - swap the banks and reboot into RAM. Nothing is sent back."""
    return CMD_BOOT


def read_response_len(count):
    """How many bytes a `frame_read(_, count)` will produce."""
    return count * WORD_BYTES


def parse_words(data, count):
    """Decode a read response into words."""
    expected = read_response_len(count)
    if len(data) != expected:
        raise BootloaderError(
            f"expected {expected} bytes for {count} words, got {len(data)}. "
            f"A short read usually means the link dropped a byte and the "
            f"bootloader is still waiting for the rest of a command"
        )
    return list(struct.unpack(f">{count}I", data))


def compare_words(sent, got, addr=RAM_BASE):
    """First mismatch between what was written and what read back, or None.

    Returns a ready-made message rather than raising, so a caller can decide
    whether a mismatch is fatal (it usually is) and log it in its own style.
    """
    if len(sent) != len(got):
        return f"read back {len(got)} words, wrote {len(sent)}"

    for index, (want, have) in enumerate(zip(sent, got)):
        if want != have:
            return (
                f"mismatch at {addr + index * WORD_BYTES:#010x} "
                f"(word {index}): wrote {want:#010x}, read {have:#010x}"
            )
    return None


def chunks(words, size):
    """Split `words` into runs of at most `size`, for progress and verify."""
    for start in range(0, len(words), size):
        yield start, words[start:start + size]


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
#
# A read response is machine code. Decoded as text it is line noise - and
# worse, it contains 0x0a bytes, so anything assembling lines will chop it into
# nonsense at arbitrary points. Everything that reports memory contents should
# go through the formatters here.

# Hex characters per output line. 256 is 128 bytes, or 32 words. The group
# separators below are on top of this - it counts hex digits, not columns.
HEX_PER_LINE = 256


def format_words(words, addr=RAM_BASE, hex_per_line=HEX_PER_LINE):
    """Render words as address-prefixed hex lines.

    Words are printed as values, most significant digit first, which is how a
    disassembler shows them - so a line here can be compared directly against
    sw/build/firmware.dis. That is deliberately *not* the byte order they
    travel in; use format_bytes for a raw wire capture.
    """
    per_line = max(1, hex_per_line // (WORD_BYTES * 2))

    lines = []
    for start in range(0, len(words), per_line):
        row = words[start:start + per_line]
        body = " ".join(f"{word:08x}" for word in row)
        lines.append(f"{addr + start * WORD_BYTES:08x}  {body}")
    return "\n".join(lines)


def format_bytes(data, addr=RAM_BASE, hex_per_line=HEX_PER_LINE, group=WORD_BYTES):
    """Render raw bytes as address-prefixed hex lines, in the order received."""
    per_line = max(1, hex_per_line // 2)

    lines = []
    for start in range(0, len(data), per_line):
        row = data[start:start + per_line]
        if group:
            body = " ".join(
                row[i:i + group].hex() for i in range(0, len(row), group)
            )
        else:
            body = row.hex()
        lines.append(f"{addr + start:08x}  {body}")
    return "\n".join(lines)


def format_diff(sent, got, addr=RAM_BASE, context=4):
    """Expected against actual, around the first word that differs.

    Dumping several hundred words on a mismatch buries the one that matters,
    so this shows a window: whichever line the first bad word falls on, plus
    `context` words either side.
    """
    limit = min(len(sent), len(got))
    first = next((i for i in range(limit) if sent[i] != got[i]), limit)

    start = max(0, first - context)
    end = min(max(len(sent), len(got)), first + context + 1)

    window_addr = addr + start * WORD_BYTES
    return (
        f"first difference at word {first} ({addr + first * WORD_BYTES:#010x})\n"
        f"  wrote  {format_words(sent[start:end], window_addr)}\n"
        f"  read   {format_words(got[start:end], window_addr)}"
    )
