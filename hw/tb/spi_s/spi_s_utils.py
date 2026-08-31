"""Shared helpers for the ahb_spi_s directed testbench.

Anything DUT-protocol-shaped lives here; test-harness scaffolding stays in
test_spi_s.py. Same split as hw/tb/spi_m/spi_m_utils.py.
"""

import cocotb
from cocotb.triggers import RisingEdge

# --------------------------------------------------------------------------
# Register offsets. The decode is HADDR[4:2], so these are word-aligned.
# --------------------------------------------------------------------------

ADDR_CTRL       = 0x00
ADDR_STATUS     = 0x04
ADDR_TXDATA     = 0x08
ADDR_RXDATA     = 0x0C
ADDR_IRQ_STATUS = 0x10
ADDR_IRQ_EN     = 0x14

# CTRL
CTRL_ENABLE     = 1 << 0
CTRL_SOFT_RESET = 1 << 1
CTRL_CPHA       = 1 << 2
CTRL_CPOL       = 1 << 3
# Bit 4 is reserved (GRPR-SPIS-030, withdrawn): SPI_READ/SPI_WRITE/FAST_READ/
# FAST_WRITE never retarget to the debug port any more, so there is no
# register bit left to gate that.

# STATUS
STATUS_BUSY       = 1 << 0
STATUS_RX_VALID   = 1 << 1
STATUS_TX_READY   = 1 << 2
STATUS_DEBUG_BUSY = 1 << 3
STATUS_RX_EMPTY   = 1 << 4
STATUS_RX_FULL    = 1 << 5
STATUS_TX_EMPTY   = 1 << 6
STATUS_TX_FULL    = 1 << 7
STATUS_RX_LEVEL_SHIFT = 8
STATUS_RX_LEVEL_MASK  = 0xF << STATUS_RX_LEVEL_SHIFT

def rx_level(status):
    """Extract STATUS.RX_LEVEL."""
    return (status & STATUS_RX_LEVEL_MASK) >> STATUS_RX_LEVEL_SHIFT

# IRQ_STATUS / IRQ_EN. Bit 3 is reserved so the positions line up with the
# SPI Master's, letting a shared driver header use one set of masks.
IRQ_RX_VALID  = 1 << 0
IRQ_UNDERRUN  = 1 << 1
IRQ_OVERRUN   = 1 << 2
IRQ_UNDERFLOW = 1 << 4
IRQ_OVERFLOW  = 1 << 5

# SPI command opcodes (legacy APS6404L-compatible; FIFO path only, never the
# debug port -- GRPR-SPIS-030, withdrawn).
OP_SPI_WRITE  = 0x02
OP_SPI_READ   = 0x03
OP_FAST_WRITE = 0x0A
OP_FAST_READ  = 0x0B

# Dedicated debug opcodes (SPI Slave Specification.md § Debug Command
# Encoding). Present only under the DEBUG_PORT_EN parameter; decoded
# unconditionally there, with no CTRL bit gating them.
OP_BUS_WRITE  = 0x51
OP_BUS_READ   = 0x52
OP_BUS_STATUS = 0x53
OP_DBG_READ   = 0x54
OP_DBG_ENABLE = 0x55
# 0x56 reserved (GRPR-SPIS-048) -- refused, produces no request/response.
OP_DBG_RESUME = 0x57
OP_DBG_STEP   = 0x58
OP_BUS_LOCK   = 0x5A
OP_BUS_UNLOCK = 0xA5

FIFO_DEPTH = 4

# Debug port commands, from the Debug Unit's "Debug Port Commands" table.
DBG_CMD_NOP        = 0x0
DBG_CMD_LOCK       = 0x1
DBG_CMD_UNLOCK     = 0x2
DBG_CMD_READ       = 0x3
DBG_CMD_WRITE      = 0x4
DBG_CMD_STATUS     = 0x5
DBG_CMD_STATE_READ = 0x6
DBG_CMD_STEP       = 0x7
DBG_CMD_RESUME     = 0x8
DBG_CMD_DBG_ENABLE = 0xC

# --------------------------------------------------------------------------
# SPI framing
# --------------------------------------------------------------------------
#
# The block's command FSM is IDLE -> COMMAND -> ADDRESS -> READ/WRITE_DATA,
# and only FSM_WRITE_DATA bytes are payload. Reaching it needs SS held low
# across the whole frame, which the older per-byte spi_send_byte() helper
# cannot do -- it drops SS after every byte, so every call sends a lone
# command byte and the FSM never leaves FSM_COMMAND.


async def _shift_byte(dut, value, capture=False, mode=0):
    """Clock one byte out on MOSI, MSB first. Returns the MISO byte.

    SS is left alone: the caller owns the frame.

    `mode` is the SPI mode number (CPOL<<1 | CPHA). It selects the idle level
    of SCK and which of the two edges the slave samples on, so a mode-3 test
    drives a genuine mode-3 waveform rather than a mode-0 one with the CTRL
    bits set. The block samples on the leading edge for modes 0 and 3 and on
    the trailing edge for modes 1 and 2 -- the cpol^cpha selector in
    spi_s_core.sv.
    """
    cpol = (mode >> 1) & 1
    cpha = mode & 1
    idle = cpol
    active = 1 - cpol

    # MOSI is driven to the real bit only across the edge the mode says the
    # slave samples, and to its complement across the other one. A block that
    # samples the wrong edge therefore receives the inverted byte rather than
    # the right one by luck -- without this, MOSI is stable across both edges
    # of a bit and a mode test passes against a block that ignores CPOL and
    # CPHA entirely.
    received = 0
    for i in range(7, -1, -1):
        bit = (value >> i) & 1
        anti = bit ^ 1

        if cpha:
            # Leading edge launches, trailing edge samples.
            dut.spi_mosi.value = anti
            await RisingEdge(dut.HCLK)
            dut.spi_sck.value = active
            await RisingEdge(dut.HCLK)

            dut.spi_mosi.value = bit
            await RisingEdge(dut.HCLK)
            dut.spi_sck.value = idle
            await RisingEdge(dut.HCLK)
            if capture:
                received = (received << 1) | int(dut.spi_miso.value)
        else:
            # Leading edge samples, trailing edge launches.
            dut.spi_mosi.value = bit
            await RisingEdge(dut.HCLK)
            dut.spi_sck.value = active
            await RisingEdge(dut.HCLK)
            if capture:
                received = (received << 1) | int(dut.spi_miso.value)

            dut.spi_mosi.value = anti
            dut.spi_sck.value = idle
            await RisingEdge(dut.HCLK)
    return received


async def spi_frame(dut, opcode, address=0, payload=(), read_len=0, mode=0,
                    dummy=0):
    """Drive one complete SPI frame with SS held low throughout.

    opcode + 24-bit address + `dummy` wait bytes + payload bytes, matching
    the block's FSM. For a read, `read_len` bytes are clocked with MOSI idle
    and MISO captured.

    `dummy` is the APS6404L datasheet's Wait Cycle count expressed in whole
    bytes: 0 for READ/WRITE, 1 for FAST_READ (8 wait cycles, § 8.5). It is a
    caller argument rather than being derived from `opcode` here so that a
    test can deliberately send the wrong number and show that it matters.

    Returns the list of bytes seen on MISO during the data phase.
    """
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, opcode, mode=mode)
    for shift in (16, 8, 0):
        await _shift_byte(dut, (address >> shift) & 0xFF, mode=mode)

    for _ in range(dummy):
        await _shift_byte(dut, 0x00, mode=mode)

    for byte in payload:
        await _shift_byte(dut, byte, mode=mode)

    out = []
    for _ in range(read_len):
        out.append(await _shift_byte(dut, 0x00, capture=True, mode=mode))

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)
    return out


async def spi_write_frame(dut, payload, address=0, opcode=OP_SPI_WRITE):
    """Deliver `payload` to the RX path as a SPI_WRITE frame."""
    await spi_frame(dut, opcode, address, payload=payload)


async def spi_read_frame(dut, count, address=0, opcode=OP_SPI_READ, dummy=None):
    """Clock `count` bytes out of the TX path as a read frame.

    `dummy` defaults to the wait-byte count the opcode actually calls for --
    1 for FAST_READ, 0 for READ -- so callers get datasheet-correct framing
    without restating it. Pass it explicitly to frame a deliberately wrong
    number.
    """
    if dummy is None:
        dummy = 1 if opcode == OP_FAST_READ else 0
    return await spi_frame(dut, opcode, address, read_len=count, dummy=dummy)


# --------------------------------------------------------------------------
# Dedicated debug opcode framing (SPI Slave Specification.md § Debug Command
# Encoding). Each helper drives one complete frame, SS held low throughout,
# matching spi_s_core.sv's FSM exactly rather than spi_frame()'s legacy
# opcode+24-bit-address+payload shape.
# --------------------------------------------------------------------------


async def dbg_bus_write_frame(dut, address, payload, mode=0):
    """OP_BUS_WRITE: 32-bit address, then N payload bytes."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, OP_BUS_WRITE, mode=mode)
    for shift in (24, 16, 8, 0):
        await _shift_byte(dut, (address >> shift) & 0xFF, mode=mode)
    for byte in payload:
        await _shift_byte(dut, byte, mode=mode)

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)


async def dbg_bus_read_frame(dut, address, count, mode=0):
    """OP_BUS_READ: 32-bit address, one dummy byte, then `count` response
    bytes captured from MISO."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, OP_BUS_READ, mode=mode)
    for shift in (24, 16, 8, 0):
        await _shift_byte(dut, (address >> shift) & 0xFF, mode=mode)
    await _shift_byte(dut, 0x00, mode=mode)  # dummy byte (GRPR-SPIS-046)

    out = []
    for _ in range(count):
        out.append(await _shift_byte(dut, 0x00, capture=True, mode=mode))

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)
    return out


async def dbg_bus_status_frame(dut, mode=0):
    """OP_BUS_STATUS: one dummy byte, then the fixed 4-byte STATUS word,
    MSB-first. Returns the 32-bit value."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, OP_BUS_STATUS, mode=mode)
    await _shift_byte(dut, 0x00, mode=mode)  # dummy byte

    value = 0
    for _ in range(4):
        value = (value << 8) | await _shift_byte(dut, 0x00, capture=True, mode=mode)

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)
    return value


async def dbg_read_frame(dut, selector, mode=0):
    """OP_DBG_READ (STATE_READ): 1 selector byte, 1 dummy byte, then the
    fixed 4-byte response word, MSB-first. Returns the 32-bit value."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, OP_DBG_READ, mode=mode)
    await _shift_byte(dut, selector & 0xFF, mode=mode)
    await _shift_byte(dut, 0x00, mode=mode)  # dummy byte

    value = 0
    for _ in range(4):
        value = (value << 8) | await _shift_byte(dut, 0x00, capture=True, mode=mode)

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)
    return value


async def dbg_bus_lock_frame(dut, mode_bit=0, mode=0):
    """OP_BUS_LOCK: 1 flags byte. Bit 0 is the LOCK_MODE override; this
    transport always presents wdata[8]=1 (GRPR-SPIS-047), so the flags byte
    itself only ever carries the mode bit."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, OP_BUS_LOCK, mode=mode)
    await _shift_byte(dut, mode_bit & 0x01, mode=mode)

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)


async def dbg_bus_unlock_frame(dut, mode=0):
    """OP_BUS_UNLOCK: opcode only, no payload."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)
    await _shift_byte(dut, OP_BUS_UNLOCK, mode=mode)
    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)


async def dbg_resume_frame(dut, mode=0):
    """OP_DBG_RESUME: opcode only, no payload."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)
    await _shift_byte(dut, OP_DBG_RESUME, mode=mode)
    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)


async def dbg_enable_frame(dut, mode=0):
    """OP_DBG_ENABLE: opcode only, no payload, no response (GRPR-SPIS-043)."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)
    await _shift_byte(dut, OP_DBG_ENABLE, mode=mode)
    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)


async def dbg_step_frame(dut, count, mode=0):
    """OP_DBG_STEP: 1 count byte."""
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)
    await _shift_byte(dut, OP_DBG_STEP, mode=mode)
    await _shift_byte(dut, count & 0xFF, mode=mode)
    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)


# --------------------------------------------------------------------------
# Debug-port stub
# --------------------------------------------------------------------------


class DebugStub:
    """Minimal Debug Unit stand-in for the dbg_* port.

    Backs a dict keyed by byte address and answers each request in one
    cycle. WRITE (byte-sized, from OP_BUS_WRITE) stores the low byte of
    wdata; every other command's wdata/rdata is treated as a full 32-bit
    value, since STATUS/STATE_READ/REG_READ-shaped responses and
    LOCK/STEP's wdata are not byte-sized. `status_word` lets a test control
    what a STATUS/STATE_READ-mapped request reads back, independent of the
    `memory` dict.
    """

    def __init__(self, dut, memory=None, err_addrs=(), status_word=0):
        self.dut = dut
        self.memory = dict(memory or {})
        self.err_addrs = set(err_addrs)
        self.requests = []
        self.status_word = status_word
        self._task = None

    def start(self):
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self):
        if self._task is not None:
            self._task.cancel()

    async def _run(self):
        dut = self.dut
        dut.dbg_req_ready.value = 1
        dut.dbg_rsp_valid.value = 0
        dut.dbg_rsp_rdata.value = 0
        dut.dbg_rsp_err.value = 0

        while True:
            await RisingEdge(dut.HCLK)
            if int(dut.dbg_req_valid.value):
                cmd = int(dut.dbg_req_cmd.value)
                addr = int(dut.dbg_req_addr.value)
                wdata = int(dut.dbg_req_wdata.value)
                self.requests.append((cmd, addr, wdata))

                err = addr in self.err_addrs
                if cmd == DBG_CMD_WRITE and not err:
                    self.memory[addr] = wdata & 0xFF

                if cmd in (DBG_CMD_STATUS, DBG_CMD_STATE_READ):
                    rdata = self.status_word
                else:
                    rdata = self.memory.get(addr, 0)

                dut.dbg_rsp_rdata.value = rdata
                dut.dbg_rsp_err.value = 1 if err else 0
                dut.dbg_rsp_valid.value = 1
                await RisingEdge(dut.HCLK)
                dut.dbg_rsp_valid.value = 0
            else:
                dut.dbg_rsp_valid.value = 0
