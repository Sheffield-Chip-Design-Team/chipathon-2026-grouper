#!/usr/bin/env python3
"""Load a firmware image into GrouperSoC's RAM over a serial port and boot it.

The host half of the ROM bootloader (sw/boot/bootloader.c). The SoC's ROM is
1 KiB and holds only the bootloader, so this is how anything larger actually
runs: the image is written into RAM, verified, and then the bank switch is
thrown so the CPU re-fetches its reset vector from it.

    python sw/scripts/load_fw.py --port /dev/ttyUSB0 sw/build/firmware.bin

Build the image for RAM, not ROM - the two are linked for different addresses:

    FW_TEST=fibonnaci sw/scripts/build_fw.sh --link ram

The wire format lives in hw/tb/tb_utils/bootloader.py, shared with the cocotb
testbench (hw/tb/top/test_soc.py) so the simulated and the real load cannot
drift apart. Importing it needs the repo installed, which `pip install -e .`
in the project README already does.

Baud must match what the bootloader in the ROM was built with - 19200 unless
it was built with --baud. build_bootloader.sh records the value it used in
sw/build/boot/uart_baud.txt.
"""

import argparse
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from hw.tb.tb_utils import bootloader  # noqa: E402

# Words per command. The protocol has no per-word acknowledgement, so this is
# what turns "the image is wrong" into "the image is wrong in this block", and
# it is what progress is reported against.
CHUNK_WORDS = 64

DEFAULT_BAUD = 19200

def open_port(port, baud, timeout):
    """Open the serial port. pyserial is imported here so that -h works without it."""
    try:
        import serial
    except ImportError:
        raise SystemExit(
            "pyserial is not installed - `pip install -e .` in the repo root, "
            "or `pip install pyserial`"
        )

    try:
        return serial.Serial(port, baud, timeout=timeout)
    except serial.SerialException as exc:
        raise SystemExit(f"could not open {port}: {exc}")


def wait_for_greeting(link, timeout):
    """Block until the bootloader says it is ready, or time out.

    It prints the greeting once, immediately after reset. If the board has been
    sitting at the prompt since before this script started, that has already
    gone past - so a newline is sent first, which the bootloader echoes, and
    either answer means it is listening.
    """
    link.reset_input_buffer()
    link.write(bootloader.frame_ping())
    link.flush()

    deadline = time.monotonic() + timeout
    seen = b""
    while time.monotonic() < deadline:
        chunk = link.read(64)
        if chunk:
            seen += chunk
            if b"\n" in seen or bootloader.GREETING.encode() in seen:
                return seen.decode(errors="replace").strip()

    raise SystemExit(
        f"no response from the bootloader within {timeout}s. Check the port, "
        f"check the baud matches what the ROM was built with, and reset the board"
    )


def read_back(link, addr, count):
    """Read `count` words from `addr`. Returns the decoded words."""
    # Nothing is sent in reply to a 'W', so anything still buffered is left
    # over from the greeting or from earlier output. Drop it, or the response
    # comes back shifted by however much was there.
    link.reset_input_buffer()
    link.write(bootloader.frame_read(addr, count))
    link.flush()

    expected = bootloader.read_response_len(count)
    raw = link.read(expected)
    if len(raw) != expected:
        raise SystemExit(
            f"short readback at {addr:#010x}: asked for {expected} bytes, got "
            f"{len(raw)}. The link dropped something and the bootloader is "
            f"probably still waiting for the rest of a command"
        )
    return bootloader.parse_words(raw, count)


def load(link, words, addr, verify, quiet, dump):
    """Write `words` to `addr`, a chunk at a time, optionally reading each back."""
    total = len(words)

    for start, chunk in bootloader.chunks(words, CHUNK_WORDS):
        chunk_addr = addr + start * bootloader.WORD_BYTES

        link.write(bootloader.frame_write(chunk_addr, chunk))
        link.flush()

        if verify or dump:
            got = read_back(link, chunk_addr, len(chunk))

            if dump:
                # Overwrite the progress line before dumping onto it.
                if not quiet:
                    print()
                print(bootloader.format_words(got, chunk_addr))

            if verify:
                complaint = bootloader.compare_words(chunk, got, chunk_addr)
                if complaint:
                    print(f"\nverify failed: {complaint}", file=sys.stderr)
                    print(bootloader.format_diff(chunk, got, chunk_addr),
                          file=sys.stderr)
                    raise SystemExit(1)

        if not quiet and not dump:
            done = start + len(chunk)
            print(f"\r  {done * bootloader.WORD_BYTES:6d} / "
                  f"{total * bootloader.WORD_BYTES} bytes", end="", flush=True)

    if not quiet and not dump:
        print()


def tail(link):
    """Echo whatever the booted image prints, until interrupted.

    Text here, unlike a read response: past the bank switch the port carries
    whatever the loaded image chooses to print. Non-printable bytes are shown
    as \\xNN rather than sent to the terminal raw, so a wrong baud or a crashed
    image cannot leave the terminal in a strange state.
    """
    print("--- output (ctrl-c to stop) ---")
    printable = set(range(0x20, 0x7F)) | {0x09, 0x0A, 0x0D}
    try:
        while True:
            chunk = link.read(64)
            for value in chunk:
                sys.stdout.write(
                    chr(value) if value in printable else f"\\x{value:02x}"
                )
            if chunk:
                sys.stdout.flush()
    except KeyboardInterrupt:
        print()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Build the image with sw/scripts/build_fw.sh --link ram.",
    )
    parser.add_argument("image", help="RAM-linked firmware .bin (sw/build/firmware.bin)")
    parser.add_argument("--port", required=True, help="serial port, e.g. /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                        help=f"must match the ROM's UART_BAUD_RATE (default {DEFAULT_BAUD})")
    parser.add_argument("--addr", type=lambda s: int(s, 0), default=bootloader.RAM_BASE,
                        help="load address, default %(default)#010x (RAM_BASE)")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip the readback. Faster, and worth exactly what it costs")
    parser.add_argument("--no-boot", action="store_true",
                        help="load but do not send the bank switch, leaving the "
                             "bootloader at its prompt")
    parser.add_argument("--dump", action="store_true",
                        help="print what reads back as hex, "
                             f"{bootloader.HEX_PER_LINE} hex characters a line, "
                             "instead of a progress counter. Comparable line for "
                             "line against sw/build/firmware.dis")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="seconds to wait for a response, default %(default)s")
    parser.add_argument("--quiet", action="store_true", help="no progress output")
    args = parser.parse_args(argv)

    words = bootloader.image_words(args.image)
    bootloader.check_image(words, args.addr)

    link = open_port(args.port, args.baud, args.timeout)

    reply = wait_for_greeting(link, args.timeout)
    if not args.quiet:
        print(f"bootloader on {args.port} at {args.baud} baud: {reply!r}")
        print(f"loading {args.image}: {len(words) * bootloader.WORD_BYTES} bytes "
              f"to {args.addr:#010x}")

    load(link, words, args.addr, verify=not args.no_verify, quiet=args.quiet,
         dump=args.dump)

    if args.no_boot:
        if not args.quiet:
            print("loaded; not booting (--no-boot)")
        return 0

    if not args.quiet:
        print("bank switch: rebooting into RAM")
    link.write(bootloader.frame_boot())
    link.flush()

    tail(link)
    return 0


if __name__ == "__main__":
    sys.exit(main())
