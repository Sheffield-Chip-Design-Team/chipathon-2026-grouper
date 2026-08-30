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
CTRL_ENABLE        = 1 << 0
CTRL_SOFT_RESET    = 1 << 1
CTRL_CPHA          = 1 << 2
CTRL_CPOL          = 1 << 3
CTRL_DEBUG_PORT_EN = 1 << 4

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

# SPI command opcodes
OP_SPI_WRITE  = 0x02
OP_SPI_READ   = 0x03
OP_FAST_WRITE = 0x0A
OP_FAST_READ  = 0x0B

FIFO_DEPTH = 4

# Debug port commands, from the Debug Unit's "Debug Port Commands" table.
DBG_CMD_NOP    = 0x0
DBG_CMD_READ   = 0x3
DBG_CMD_WRITE  = 0x4

# --------------------------------------------------------------------------
# SPI framing
# --------------------------------------------------------------------------
#
# The block's command FSM is IDLE -> COMMAND -> ADDRESS -> READ/WRITE_DATA,
# and only FSM_WRITE_DATA bytes are payload. Reaching it needs SS held low
# across the whole frame, which the older per-byte spi_send_byte() helper
# cannot do -- it drops SS after every byte, so every call sends a lone
# command byte and the FSM never leaves FSM_COMMAND.


async def _shift_byte(dut, value, capture=False):
    """Clock one byte out on MOSI, MSB first. Returns the MISO byte.

    SS is left alone: the caller owns the frame.
    """
    received = 0
    for i in range(7, -1, -1):
        dut.spi_mosi.value = (value >> i) & 1
        await RisingEdge(dut.HCLK)

        dut.spi_sck.value = 1
        await RisingEdge(dut.HCLK)
        if capture:
            received = (received << 1) | int(dut.spi_miso.value)

        dut.spi_sck.value = 0
        await RisingEdge(dut.HCLK)
    return received


async def spi_frame(dut, opcode, address=0, payload=(), read_len=0):
    """Drive one complete SPI frame with SS held low throughout.

    opcode + 24-bit address + payload bytes, matching the block's FSM. For a
    read, `read_len` bytes are clocked with MOSI idle and MISO captured.

    Returns the list of bytes seen on MISO during the data phase.
    """
    dut.spi_ss.value = 0
    await RisingEdge(dut.HCLK)

    await _shift_byte(dut, opcode)
    for shift in (16, 8, 0):
        await _shift_byte(dut, (address >> shift) & 0xFF)

    for byte in payload:
        await _shift_byte(dut, byte)

    out = []
    for _ in range(read_len):
        out.append(await _shift_byte(dut, 0x00, capture=True))

    dut.spi_ss.value = 1
    await RisingEdge(dut.HCLK)
    return out


async def spi_write_frame(dut, payload, address=0, opcode=OP_SPI_WRITE):
    """Deliver `payload` to the RX path as a SPI_WRITE frame."""
    await spi_frame(dut, opcode, address, payload=payload)


async def spi_read_frame(dut, count, address=0, opcode=OP_SPI_READ):
    """Clock `count` bytes out of the TX path as a SPI_READ frame."""
    return await spi_frame(dut, opcode, address, read_len=count)


# --------------------------------------------------------------------------
# Debug-port stub
# --------------------------------------------------------------------------


class DebugStub:
    """Minimal Debug Unit stand-in for the dbg_* port.

    No Debug Unit RTL exists, so without this the SPI-to-debug translation
    would ship untested -- which is how spi_address became dead logic in the
    first place. Backs a dict keyed by byte address and answers each request
    in one cycle.
    """

    def __init__(self, dut, memory=None, err_addrs=()):
        self.dut = dut
        self.memory = dict(memory or {})
        self.err_addrs = set(err_addrs)
        self.requests = []
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
                wdata = int(dut.dbg_req_wdata.value) & 0xFF
                self.requests.append((cmd, addr, wdata))

                err = addr in self.err_addrs
                if cmd == 0x4 and not err:        # WRITE
                    self.memory[addr] = wdata
                rdata = self.memory.get(addr, 0)

                dut.dbg_rsp_rdata.value = rdata
                dut.dbg_rsp_err.value = 1 if err else 0
                dut.dbg_rsp_valid.value = 1
                await RisingEdge(dut.HCLK)
                dut.dbg_rsp_valid.value = 0
            else:
                dut.dbg_rsp_valid.value = 0
