"""Directed tests for the SPI slave's debug transport.

Run with the `debug_port` target, which elaborates DEBUG_PORT_EN=1:

    fusesoc run --no-export --target=debug_port sharc:comms_ip:ahb_spi_s_directed

These exercise GRPR-SPIS-030 .. -035. No Debug Unit RTL exists, so the far end
is the DebugStub in spi_s_utils.py -- a dict-backed responder implementing the
dbg_* valid/ready handshake. That proves the SPI-to-debug translation, not the
bus behaviour behind it; a real Debug Unit will need its own integration pass.
"""

import functools
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, SimTimeoutError, with_timeout

from hw.tb.tb_utils.ahb_utils import (
    HSIZE_BYTE,
    HSIZE_WORD,
    HTRANS_IDLE,
    ahb_read,
    ahb_write,
)
from hw.tb.spi_s.spi_s_utils import (
    ADDR_CTRL,
    ADDR_IRQ_STATUS,
    ADDR_RXDATA,
    ADDR_STATUS,
    ADDR_TXDATA,
    CTRL_DEBUG_PORT_EN,
    CTRL_ENABLE,
    DebugStub,
    IRQ_OVERRUN,
    OP_SPI_READ,
    OP_SPI_WRITE,
    STATUS_RX_EMPTY,
    DBG_CMD_READ,
    DBG_CMD_WRITE,
    rx_level,
    spi_frame,
)

log = logging.getLogger("cocotb.spi_s_debug")

CLK_PERIOD_NS = 10


async def settle(dut):
    """End on a clock edge; see the note in test_spi_s.py."""
    try:
        await with_timeout(RisingEdge(dut.HCLK), 10 * CLK_PERIOD_NS, "ns")
    except SimTimeoutError:
        log.debug("settle: no clock edge")
    except Exception as exc:                       # noqa: BLE001
        log.debug("settle: %s", exc)


def spi_s_test(**kwargs):
    def wrap(fn):
        @cocotb.test(**kwargs)
        @functools.wraps(fn)
        async def inner(dut):
            try:
                await fn(dut)
            finally:
                await settle(dut)
        return inner
    return wrap


async def reset_dut(dut):
    dut.HRESETn.value = 0
    dut.HADDR.value = 0
    dut.HBURST.value = 0
    dut.HMASTLOCK.value = 0
    dut.HPROT.value = 0
    dut.HSIZE.value = HSIZE_WORD
    dut.HTRANS.value = HTRANS_IDLE
    dut.HWDATA.value = 0
    dut.HWRITE.value = 0
    dut.HSEL.value = 0
    dut.HREADYIN.value = 1

    dut.spi_ss.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0

    dut.dbg_req_ready.value = 0
    dut.dbg_rsp_valid.value = 0
    dut.dbg_rsp_rdata.value = 0
    dut.dbg_rsp_err.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)
    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)


async def init_test(dut):
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)


async def enable(dut, debug=True):
    """Enable the block, with the debug path on by default."""
    value = CTRL_ENABLE | (CTRL_DEBUG_PORT_EN if debug else 0)
    hresp = await ahb_write(dut, ADDR_CTRL, value)
    assert hresp == 0, "CTRL write reported HRESP error"


# TEST 1
@spi_s_test()
async def test_debug_port_en_elaborated(dut):
    """With DEBUG_PORT_EN=1 the CTRL bit exists and defaults set.

    Guards the whole suite: with the parameter at its default the bit reads 0
    and every test below would pass vacuously against a dead path.
    """
    await init_test(dut)

    ctrl, hresp = await ahb_read(dut, ADDR_CTRL)
    assert hresp == 0, "CTRL read reported HRESP error"
    assert ctrl & CTRL_DEBUG_PORT_EN, \
        f"DEBUG_PORT_EN not set out of reset: CTRL=0x{ctrl:08X}"


# TEST 2
@spi_s_test()
async def test_spi_write_becomes_bus_write(dut):
    """SPI_WRITE payload bytes are forwarded as debug WRITE requests."""
    await init_test(dut)
    await enable(dut)

    stub = DebugStub(dut).start()
    await spi_frame(dut, OP_SPI_WRITE, 0x001234, payload=[0xDE])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    cmd, addr, wdata = stub.requests[0]
    assert cmd == DBG_CMD_WRITE, f"expected WRITE (0x4), got 0x{cmd:X}"
    assert addr == 0x001234, \
        f"expected the 24-bit address zero-extended, got 0x{addr:08X}"
    assert wdata == 0xDE, f"expected payload 0xDE, got 0x{wdata:02X}"
    assert stub.memory.get(0x001234) == 0xDE, \
        "the byte did not reach the stub's memory"


# TEST 3
@spi_s_test()
async def test_spi_read_sources_from_bus(dut):
    """SPI_READ sources MISO bytes from debug READ responses."""
    await init_test(dut)
    await enable(dut)

    stub = DebugStub(dut, memory={0x002000: 0x5A}).start()
    got = await spi_frame(dut, OP_SPI_READ, 0x002000, read_len=1)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    assert stub.requests[0][0] == DBG_CMD_READ, \
        f"expected READ (0x3), got 0x{stub.requests[0][0]:X}"
    assert got[0] == 0x5A, \
        f"expected MISO 0x5A from the bus, got 0x{got[0]:02X}"


# TEST 4
@spi_s_test()
async def test_write_burst_auto_increments(dut):
    """A multi-byte write walks consecutive ascending addresses."""
    await init_test(dut)
    await enable(dut)

    payload = [0x11, 0x22, 0x33, 0x44]
    stub = DebugStub(dut).start()
    await spi_frame(dut, OP_SPI_WRITE, 0x000100, payload=payload)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    for i, expected in enumerate(payload):
        addr = 0x000100 + i
        assert stub.memory.get(addr) == expected, (
            f"address 0x{addr:06X} holds "
            f"{stub.memory.get(addr)}, expected 0x{expected:02X}"
        )


# TEST 5
@spi_s_test()
async def test_bytes_bypass_rx_fifo(dut):
    """On the debug path payload bytes go to the bus, not the RX FIFO."""
    await init_test(dut)
    await enable(dut)

    stub = DebugStub(dut).start()
    await spi_frame(dut, OP_SPI_WRITE, 0x000200, payload=[0xAB, 0xCD])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert status & STATUS_RX_EMPTY, \
        "RX FIFO took a byte that should have gone to the bus"
    assert rx_level(status) == 0, \
        f"RX_LEVEL is {rx_level(status)}, expected 0 on the debug path"


# TEST 6
@spi_s_test()
async def test_bus_error_is_reported_not_hung(dut):
    """A refused access is flagged and the frame still completes.

    The host is clocking SCK and cannot be held off, so an error must be
    reported through IRQ_STATUS rather than stalling the wire (GRPR-SPIS-033).
    """
    await init_test(dut)
    await enable(dut)

    stub = DebugStub(dut, err_addrs=[0x000300]).start()
    await spi_frame(dut, OP_SPI_WRITE, 0x000300, payload=[0x99])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_OVERRUN, \
        "a refused debug access was not reported in IRQ_STATUS"
    assert stub.memory.get(0x000300) is None, \
        "an errored write must not reach memory"


# TEST 7
@spi_s_test()
async def test_debug_disabled_uses_fifo_path(dut):
    """With CTRL.DEBUG_PORT_EN clear, behaviour is the plain FIFO path.

    The run-time gate has to be able to turn the transport off even in a build
    that has it (GRPR-SPIS-035), so an existing FIFO driver is unaffected.
    """
    await init_test(dut)
    await enable(dut, debug=False)

    stub = DebugStub(dut).start()
    await spi_frame(dut, OP_SPI_WRITE, 0x000400, payload=[0x77])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert not stub.requests, \
        "a debug request was issued with CTRL.DEBUG_PORT_EN clear"

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert rx_level(status) == 1, \
        f"byte did not reach the RX FIFO: RX_LEVEL={rx_level(status)}"

    got, _ = await ahb_read(dut, ADDR_RXDATA, size=HSIZE_BYTE)
    assert got == 0x77, f"expected 0x77 from the FIFO, got 0x{got:02X}"


# TEST 8
@spi_s_test()
async def test_request_is_byte_sized(dut):
    """Requests are byte-sized: the SPI frame is a byte stream."""
    await init_test(dut)
    await enable(dut)

    stub = DebugStub(dut).start()
    await spi_frame(dut, OP_SPI_WRITE, 0x000500, payload=[0x01])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert int(dut.dbg_req_size.value) == 0, \
        f"dbg_req_size is {int(dut.dbg_req_size.value)}, expected 0 (byte)"
