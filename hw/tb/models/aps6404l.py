"""A behavioural APS6404L-3SQR QSPI PSRAM, driven as a plain SPI slave.

Models the SPI-mode (QE=0, single-bit IO) half of the device, which is the
half `ahb_spi_m` talks to: GRPR-SPIM-004 requires the SPI master's command
encoding to be compatible with this part, and this model is what that
requirement is checked against at the top level.

Everything here is from the AP Memory datasheet (Rev 2.3, Apr 30 2020),
https://www.pjrc.com/store/APS6404L_3SQR.pdf:

  Section 8.1  64Mb, 8M x 8, byte addressable, addressed with A[22:0] - so
               the address phase is 24 bits and the top bit is ignored.
  Section 8.2  Page size is 1K (CA[9:0]). The default burst setting is Linear
               Burst, which crosses the page boundary continuously.
  Section 8.4  "The device powers up in SPI Mode.  It is required to have CE#
               high before beginning any operations."
  Section 8.5  The command truth table this model's OPCODES mirror - notably
               Read 'h03 takes 0 wait cycles and Fast Read 'h0B takes 8.
  Section 8.6  "All Reads & Writes must be completed by raising CE# high
               immediately afterwards" - checked by check_termination().

Deliberately not modelled: QPI mode ('h35 is accepted and recorded but the
model keeps decoding single-bit, because the SPI master cannot drive four
lines and would never get a sane reply anyway), the quad commands ('hEB /
'h38, whose data phases are quad even when the command is serial), Wrap 32
('hC0 toggles the recorded state only), drive strength, and every AC timing
parameter. This is a protocol model, not a timing model.

The class is transport-agnostic on purpose: it decodes a bit at a time
through feed_bit(), so the same model serves the block-level TB (wired to
the DUT's own SPI pins) and the top-level TB (wired to GPIO pads 4-7).
"""

import logging

log = logging.getLogger("cocotb.aps6404l")

# --- Command set (datasheet section 8.5) ----------------------------------
#
# SPI-mode column only. "wait" is the datasheet's Wait Cycle count, i.e. the
# dummy SCK cycles between the address phase and the first data bit.

OP_READ = 0x03        # Read              addr, 0 wait, serial data out
OP_FAST_READ = 0x0B   # Fast Read         addr, 8 wait, serial data out
OP_WRITE = 0x02       # Write             addr, 0 wait, serial data in
OP_QUAD_WRITE = 0x38  # Quad Write        addr serial, data QUAD - not modelled
OP_FAST_READ_QUAD = 0xEB  # Fast Read Quad                     - not modelled
OP_ENTER_QPI = 0x35   # Enter Quad Mode   no addr, no data
OP_EXIT_QPI = 0xF5    # Exit Quad Mode    (QPI mode only)
OP_RESET_EN = 0x66    # Reset Enable      no addr, no data
OP_RESET = 0x99       # Reset             no addr, no data
OP_WRAP_TOGGLE = 0xC0 # Wrap Boundary Toggle
OP_READ_ID = 0x9F     # Read ID           addr, 0 wait, serial data out

# Wait cycles between address and data, per the section 8.5 table.
FAST_READ_WAIT = 8

# Datasheet section 8.1: 8M x 8. Address phase is 24 bits; A[22:0] select.
DENSITY = 8 * 1024 * 1024
ADDR_BITS = 23
ADDR_PHASE_BITS = 24

# Section 8.2: page size is 1K, CA[9:0]. Wrap 32 wraps on CA[4:0].
PAGE_SIZE = 1024
WRAP32_SIZE = 32

# Read ID payload. The datasheet gives KGD in table 4 ('b0101_1101 = PASS);
# the MFID and EID bytes live in figure 12, which is an image rather than
# extractable text, so these are the conventional APS6404L values rather than
# quoted ones. Only KGD is load-bearing for a pass/fail check.
MFID = 0x0D
KGD_PASS = 0x5D
KGD_FAIL = 0x55

# What an unwritten cell reads back as. The real part is DRAM and powers up
# undefined; a fixed pattern makes an accidental read of untouched memory
# obvious in a waveform instead of looking like plausible data.
ERASED_BYTE = 0xFF


class APS6404L:
    """An APS6404L PSRAM in SPI mode, fed one SCK cycle at a time.

    Drive it from a wire-level monitor: call feed_bit() once per sampling
    edge while CS# is low, and cs_high() when CS# deasserts. miso is the bit
    the device is presenting on SO for the *current* cycle.

    Storage is a dict rather than an 8 MiB bytearray - a test touches a
    handful of addresses and a sparse map keeps the model cheap while still
    covering the full 23-bit space.
    """

    def __init__(self, kgd_pass=True, name="aps6404l"):
        self.name = name
        self.memory = {}
        self.kgd = KGD_PASS if kgd_pass else KGD_FAIL

        # Device state that survives CS# going high.
        self.qpi_mode = False
        self.wrap32 = False
        self.reset_enabled = False

        # Observability for the testbench.
        self.transactions = []      # one dict per completed CS# window
        self.termination_errors = []

        self._reset_transaction()

    # -- transaction state --------------------------------------------------

    def _reset_transaction(self):
        self._bits = []             # bits sampled in the current phase
        self._opcode = None
        self._addr = 0
        self._wait_left = 0
        self._data_written = bytearray()
        self._data_read = bytearray()
        self._out_bits = []         # queued MISO bits, MSB first
        self._pending_read = None   # byte being shifted out, not yet complete
        self._cursor = 0            # current byte address, with wrapping
        self._phase = "cmd"
        self._terminated_cleanly = True

    # -- the wire interface -------------------------------------------------

    @property
    def miso(self):
        """The bit the device is driving on SO right now.

        High-Z reads as 0: the model has no tri-state, and a real read is
        always preceded by the master's own address phase, so the only bits
        that reach the master while the device is not driving are ones it
        ignores.
        """
        return self._out_bits[0] if self._out_bits else 0

    def feed_bit(self, mosi):
        """Consume one SCK cycle: sample MOSI, then advance the output.

        Returns the MISO bit that was valid for this cycle, so a caller that
        drives MISO combinationally and one that registers it can both get
        what they need.
        """
        presented = self.miso
        if self._out_bits:
            self._out_bits.pop(0)
            # Only count a byte as read once its last bit has left the pin -
            # _refill_output() queues the next one eagerly, and a burst that
            # ends mid-byte must not report a byte the master never clocked.
            if not self._out_bits and self._pending_read is not None:
                self._data_read.append(self._pending_read)
                self._pending_read = None

        self._sample(mosi & 1)
        self._refill_output()
        return presented

    def cs_high(self):
        """CS# deasserted: finish the transaction and go to standby."""
        if self._opcode is not None:
            self._finish()
        self._reset_transaction()

    # -- decode -------------------------------------------------------------

    def _sample(self, bit):
        if self._phase == "cmd":
            self._bits.append(bit)
            if len(self._bits) == 8:
                self._opcode = self._bits_to_int(self._bits)
                self._bits = []
                self._begin_command()

        elif self._phase == "addr":
            self._bits.append(bit)
            if len(self._bits) == ADDR_PHASE_BITS:
                # A[22:0] select; the 24th bit is a don't-care (section 8.1).
                self._addr = self._bits_to_int(self._bits) & ((1 << ADDR_BITS) - 1)
                self._cursor = self._addr
                self._bits = []
                self._after_address()

        elif self._phase == "wait":
            self._wait_left -= 1
            if self._wait_left <= 0:
                self._phase = "data_out"

        elif self._phase == "data_in":
            self._bits.append(bit)
            if len(self._bits) == 8:
                value = self._bits_to_int(self._bits)
                self._bits = []
                self._store(self._cursor, value)
                self._data_written.append(value)
                self._cursor = self._advance(self._cursor)

        # data_out and ignore consume the cycle without decoding it.

    def _begin_command(self):
        """Route on the opcode, per the section 8.5 truth table."""
        op = self._opcode

        if op in (OP_READ, OP_FAST_READ, OP_WRITE, OP_READ_ID,
                  OP_QUAD_WRITE, OP_FAST_READ_QUAD):
            self._phase = "addr"

        elif op == OP_ENTER_QPI:
            self.qpi_mode = True
            self._phase = "ignore"

        elif op == OP_EXIT_QPI:
            self.qpi_mode = False
            self._phase = "ignore"

        elif op == OP_RESET_EN:
            self.reset_enabled = True
            self._phase = "ignore"

        elif op == OP_RESET:
            # Section 10: Reset is only honoured after Reset Enable.
            if self.reset_enabled:
                self.qpi_mode = False
                self.wrap32 = False
            self.reset_enabled = False
            self._phase = "ignore"

        elif op == OP_WRAP_TOGGLE:
            self.wrap32 = not self.wrap32
            self._phase = "ignore"

        else:
            log.warning("%s: unknown opcode 0x%02x", self.name, op)
            self._phase = "ignore"

        # Any command other than Reset clears the reset-enable arming.
        if op not in (OP_RESET_EN, OP_RESET):
            self.reset_enabled = False

    def _after_address(self):
        op = self._opcode

        if op == OP_WRITE:
            self._phase = "data_in"

        elif op == OP_READ:
            self._phase = "data_out"

        elif op == OP_FAST_READ:
            self._wait_left = FAST_READ_WAIT
            self._phase = "wait"

        elif op == OP_READ_ID:
            # "similar to Fast Read, but without the wait cycles and the
            # device outputs EID value instead of data" (section 10.4).
            self._phase = "data_out"
            self._id_bytes = [MFID, self.kgd] + [0x00] * 6
            self._id_index = 0

        else:
            # Quad commands: the data phase is quad, which this model does
            # not decode. Stop after the address rather than inventing bits.
            log.warning(
                "%s: opcode 0x%02x has a quad data phase - not modelled",
                self.name, op,
            )
            self._phase = "ignore"

    def _refill_output(self):
        """Keep a byte of MISO queued while a read data phase is running."""
        if self._phase != "data_out" or self._out_bits:
            return

        if self._opcode == OP_READ_ID:
            value = (self._id_bytes[self._id_index]
                     if self._id_index < len(self._id_bytes) else 0x00)
            self._id_index += 1
        else:
            value = self._load(self._cursor)
            self._cursor = self._advance(self._cursor)

        self._out_bits = [(value >> i) & 1 for i in range(7, -1, -1)]
        self._pending_read = value

    def _finish(self):
        """Record the completed CS# window."""
        # Section 8.6: a read or a write must end on a byte boundary with CE#
        # raised immediately. Leftover bits mean the master cut a byte short.
        if self._bits:
            self._terminated_cleanly = False
            message = (
                f"{self.name}: CS# raised mid-byte after opcode "
                f"0x{self._opcode:02x} ({len(self._bits)} stray bits) - "
                "datasheet section 8.6 requires whole-byte termination"
            )
            self.termination_errors.append(message)
            log.warning(message)

        record = {
            "opcode": self._opcode,
            "address": self._addr,
            "written": bytes(self._data_written),
            "read": bytes(self._data_read),
            "clean": self._terminated_cleanly,
        }
        self.transactions.append(record)
        log.info(
            "%s: op=0x%02x addr=0x%06x wrote=%s read=%s",
            self.name, self._opcode, self._addr,
            self._data_written.hex() or "-", self._data_read.hex() or "-",
        )

    # -- memory -------------------------------------------------------------

    def _advance(self, address):
        """Step the burst cursor, honouring the current wrap setting.

        Section 8.2: Linear Burst crosses the 1K page boundary continuously;
        Wrap 32 wraps within CA[4:0] and never crosses a page.
        """
        if self.wrap32:
            base = address & ~(WRAP32_SIZE - 1)
            return base + ((address + 1) % WRAP32_SIZE)
        return (address + 1) % DENSITY

    def _store(self, address, value):
        self.memory[address % DENSITY] = value & 0xFF

    def _load(self, address):
        return self.memory.get(address % DENSITY, ERASED_BYTE)

    @staticmethod
    def _bits_to_int(bits):
        value = 0
        for bit in bits:
            value = (value << 1) | bit
        return value

    # -- test-facing helpers ------------------------------------------------

    def preload(self, address, data):
        """Seed memory so a read has something known to return."""
        for offset, value in enumerate(data):
            self._store(address + offset, value)

    def read_memory(self, address, length):
        return bytes(self._load(address + i) for i in range(length))

    def check_termination(self):
        """Raise if any transaction violated datasheet section 8.6."""
        assert not self.termination_errors, "\n".join(self.termination_errors)

    def last(self, opcode=None):
        """The most recent transaction, optionally filtered by opcode."""
        for record in reversed(self.transactions):
            if opcode is None or record["opcode"] == opcode:
                return record
        return None
