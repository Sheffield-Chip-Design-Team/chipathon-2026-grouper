"""Directed tests for the SPI slave's dedicated debug opcode set.

Run with the `debug_port` target, which elaborates DEBUG_PORT_EN=1:

    fusesoc run --no-export --target=debug_port sharc:comms_ip:ahb_spi_s_directed

These exercise SPI Slave Specification.md's § Debug Command Encoding
(GRPR-SPIS-041 .. -048): the dedicated wire opcodes -- BUS_WRITE, BUS_READ,
BUS_STATUS, DBG_READ, DBG_ENABLE, DBG_RESUME, DBG_STEP, BUS_LOCK, BUS_UNLOCK,
and the reserved 0x56 -- each mapping to exactly one debug-port command.

No Debug Unit RTL is exercised here; the far end is the DebugStub in
spi_s_utils.py, a dict-backed responder implementing the dbg_* valid/ready
handshake. That proves the SPI-to-debug-port translation this block owns
(framing, one request per opcode, 32-bit addressing, fixed-length responses),
not the bus/lock/CPU behaviour behind it -- that belongs to the Debug Unit's
own testbench (hw/tb/debug/).

The withdrawn legacy SPI_READ/SPI_WRITE debug retargeting (GRPR-SPIS-030) is
not covered here: those opcodes never touch the debug port any more, in any
build, and are exercised as plain FIFO commands in test_spi_s.py instead.
"""

import functools
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, SimTimeoutError, with_timeout

from hw.tb.tb_utils.ahb_utils import HSIZE_WORD, HTRANS_IDLE, ahb_read, ahb_write
from hw.tb.spi_s.spi_s_utils import (
    ADDR_CTRL,
    ADDR_IRQ_STATUS,
    ADDR_STATUS,
    CTRL_ENABLE,
    DBG_CMD_DBG_ENABLE,
    DBG_CMD_LOCK,
    DBG_CMD_READ,
    DBG_CMD_RESUME,
    DBG_CMD_STATE_READ,
    DBG_CMD_STATUS,
    DBG_CMD_STEP,
    DBG_CMD_UNLOCK,
    DBG_CMD_WRITE,
    IRQ_OVERRUN,
    STATUS_RX_EMPTY,
    DebugStub,
    OP_BUS_LOCK,
    _shift_byte,
    dbg_bus_lock_frame,
    dbg_bus_read_frame,
    dbg_bus_status_frame,
    dbg_bus_unlock_frame,
    dbg_bus_write_frame,
    dbg_enable_frame,
    dbg_read_frame,
    dbg_resume_frame,
    dbg_step_frame,
    rx_level,
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

    dut.spi_s_ss.value = 1
    dut.spi_s_sck.value = 0
    dut.spi_s_mosi.value = 0

    dut.dbg_req_ready.value = 0
    dut.dbg_rsp_valid.value = 0
    dut.dbg_rsp_rdata.value = 0
    dut.dbg_rsp_err.value = 0

    for _ in range(5):
        await RisingEdge(dut.HCLK)
    dut.HRESETn.value = 1
    await RisingEdge(dut.HCLK)


async def enable(dut):
    hresp = await ahb_write(dut, ADDR_CTRL, CTRL_ENABLE)
    assert hresp == 0, "CTRL write reported HRESP error"


async def init_test(dut):
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)
    # CTRL.ENABLE gates MISO's output driver (spi_s_core.sv's `enable`), so a
    # response-bearing opcode still needs it set even though no dedicated
    # debug opcode's *decode* depends on any CTRL bit (GRPR-SPIS-041/-044) --
    # unlike the legacy opcodes' old CTRL.DEBUG_PORT_EN gate, which is
    # withdrawn.
    await enable(dut)


# TEST 1
@spi_s_test()
async def test_bus_write_single_byte(dut):
    """OP_BUS_WRITE with a 32-bit address issues one debug WRITE."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_bus_write_frame(dut, 0x8000_1234, [0xDE])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    cmd, addr, wdata = stub.requests[0]
    assert cmd == DBG_CMD_WRITE, f"expected WRITE (0x4), got 0x{cmd:X}"
    assert addr == 0x8000_1234, \
        f"expected the full 32-bit address, got 0x{addr:08X}"
    assert wdata & 0xFF == 0xDE, f"expected payload 0xDE, got 0x{wdata:02X}"
    assert stub.memory.get(0x8000_1234) == 0xDE, \
        "the byte did not reach the stub's memory"


# TEST 2
@spi_s_test()
async def test_bus_write_reaches_peripheral_aperture(dut):
    """The 32-bit address phase reaches bit 31, unlike the legacy 24-bit
    commands (GRPR-SPIS-031, withdrawn; GRPR-SPIS-045)."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    peripheral_addr = 0x8000_5000  # bit 31 set: unreachable over the legacy path
    await dbg_bus_write_frame(dut, peripheral_addr, [0x42])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.memory.get(peripheral_addr) == 0x42, \
        "a 32-bit debug address with bit 31 set did not reach the bus"


# TEST 3
@spi_s_test()
async def test_bus_write_burst_auto_increments(dut):
    """A multi-byte BUS_WRITE walks consecutive ascending addresses."""
    await init_test(dut)

    payload = [0x11, 0x22, 0x33, 0x44]
    stub = DebugStub(dut).start()
    await dbg_bus_write_frame(dut, 0x0000_0100, payload)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    for i, expected in enumerate(payload):
        addr = 0x0000_0100 + i
        assert stub.memory.get(addr) == expected, (
            f"address 0x{addr:08X} holds "
            f"{stub.memory.get(addr)}, expected 0x{expected:02X}"
        )


# TEST 4
@spi_s_test()
async def test_bus_read_sources_from_bus(dut):
    """OP_BUS_READ sources MISO bytes from debug READ responses, after the
    one dummy byte (GRPR-SPIS-046)."""
    await init_test(dut)

    stub = DebugStub(dut, memory={0x0000_2000: 0x5A}).start()
    got = await dbg_bus_read_frame(dut, 0x0000_2000, count=1)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    assert stub.requests[0][0] == DBG_CMD_READ, \
        f"expected READ (0x3), got 0x{stub.requests[0][0]:X}"
    assert got[0] == 0x5A, \
        f"expected MISO 0x5A from the bus, got 0x{got[0]:02X}"


# TEST 5
@spi_s_test()
async def test_bus_read_burst_auto_increments(dut):
    """A multi-byte BUS_READ walks consecutive ascending addresses,
    advancing on each accepted dbg_req handshake (GRPR-SPIS-034)."""
    await init_test(dut)

    base = 0x0000_3000
    memory = {base + i: 0x10 + i for i in range(4)}
    stub = DebugStub(dut, memory=memory).start()
    got = await dbg_bus_read_frame(dut, base, count=4)
    stub.stop()

    assert got == [0x10, 0x11, 0x12, 0x13], f"got {[hex(b) for b in got]}"


# TEST 6
@spi_s_test()
async def test_bus_status_fixed_four_bytes(dut):
    """OP_BUS_STATUS returns exactly 4 bytes MSB-first and then the frame
    self-terminates (dbg_fixed_len in spi_s_core.sv)."""
    await init_test(dut)

    stub = DebugStub(dut, status_word=0xA1B2C3D4).start()
    got = await dbg_bus_status_frame(dut)
    stub.stop()

    assert got == 0xA1B2C3D4, f"expected 0xA1B2C3D4, got 0x{got:08X}"
    assert stub.requests[0][0] == DBG_CMD_STATUS, \
        f"expected STATUS (0x5), got 0x{stub.requests[0][0]:X}"
    assert len(stub.requests) == 1, \
        f"expected exactly one debug request for BUS_STATUS, got {len(stub.requests)}"


# TEST 7
@spi_s_test()
async def test_dbg_read_state_selector(dut):
    """OP_DBG_READ carries a 1-byte selector in addr[7:0] and returns the
    fixed 4-byte state word."""
    await init_test(dut)

    stub = DebugStub(dut, status_word=0x0BADCAFE).start()
    got = await dbg_read_frame(dut, selector=0x02)
    stub.stop()

    assert got == 0x0BADCAFE, f"expected 0x0BADCAFE, got 0x{got:08X}"
    cmd, addr, _ = stub.requests[0]
    assert cmd == DBG_CMD_STATE_READ, \
        f"expected STATE_READ (0x6), got 0x{cmd:X}"
    assert addr == 0x02, f"expected selector 0x02 in addr, got 0x{addr:02X}"


# TEST 8
@spi_s_test()
async def test_bus_lock_flags_byte_mapping(dut):
    """OP_BUS_LOCK's flags byte maps to LOCK's wdata[0]/wdata[8]
    (GRPR-SPIS-047): bit 0 is the mode override, bit 8 is always 1."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_bus_lock_frame(dut, mode_bit=1)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    cmd, _, wdata = stub.requests[0]
    assert cmd == DBG_CMD_LOCK, f"expected LOCK (0x1), got 0x{cmd:X}"
    assert wdata & 0x1 == 1, f"expected wdata[0]=1 (mode override), got 0x{wdata:X}"
    assert (wdata >> 8) & 0x1 == 1, \
        f"expected wdata[8]=1 (override valid, always set), got 0x{wdata:X}"


# TEST 9
@spi_s_test()
async def test_bus_lock_mode_bit_clear(dut):
    """The mode bit reflects the flags byte's bit 0 in both directions."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_bus_lock_frame(dut, mode_bit=0)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    _, _, wdata = stub.requests[0]
    assert wdata & 0x1 == 0, f"expected wdata[0]=0, got 0x{wdata:X}"


# TEST 10
@spi_s_test()
async def test_bus_unlock_no_payload(dut):
    """OP_BUS_UNLOCK carries no payload and issues one UNLOCK request."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_bus_unlock_frame(dut)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    assert stub.requests[0][0] == DBG_CMD_UNLOCK, \
        f"expected UNLOCK (0x2), got 0x{stub.requests[0][0]:X}"
    assert len(stub.requests) == 1, \
        f"expected exactly one debug request for BUS_UNLOCK, got {len(stub.requests)}"


# TEST 11
@spi_s_test()
async def test_dbg_resume_no_payload(dut):
    """OP_DBG_RESUME carries no payload and issues one RESUME request."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_resume_frame(dut)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    assert stub.requests[0][0] == DBG_CMD_RESUME, \
        f"expected RESUME (0x8), got 0x{stub.requests[0][0]:X}"


# TEST 12
@spi_s_test()
async def test_dbg_enable_no_payload_no_response(dut):
    """OP_DBG_ENABLE carries no payload and produces no MISO response
    distinguishable from idle (GRPR-SPIS-043) -- MISO stays low throughout,
    since pad 3 is not yet driving at this point in the real system."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_enable_frame(dut)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    assert stub.requests[0][0] == DBG_CMD_DBG_ENABLE, \
        f"expected DBG_ENABLE (0xC), got 0x{stub.requests[0][0]:X}"


# TEST 13
@spi_s_test()
async def test_dbg_enable_unconditional(dut):
    """DBG_ENABLE decodes regardless of CTRL.ENABLE (GRPR-SPIS-041):
    CTRL.ENABLE is left at its reset value of 0 throughout this test, and
    the request is still issued. Uses reset_dut() directly rather than
    init_test(), which sets CTRL.ENABLE for the tests that need MISO output."""
    cocotb.start_soon(Clock(dut.HCLK, CLK_PERIOD_NS, "ns").start())
    await reset_dut(dut)

    stub = DebugStub(dut).start()
    await dbg_enable_frame(dut)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, \
        "DBG_ENABLE was not decoded with CTRL.ENABLE clear"


# TEST 14
@spi_s_test()
async def test_dbg_step_count_byte(dut):
    """OP_DBG_STEP's count byte becomes wdata[7:0]."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_step_frame(dut, count=5)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert stub.requests, "no debug request was issued"
    cmd, _, wdata = stub.requests[0]
    assert cmd == DBG_CMD_STEP, f"expected STEP (0x7), got 0x{cmd:X}"
    assert wdata & 0xFF == 5, f"expected count 5, got {wdata & 0xFF}"


# TEST 15
@spi_s_test()
async def test_reserved_opcode_produces_nothing(dut):
    """Opcode 0x56 is reserved (GRPR-SPIS-048): refused, with no debug
    request and no distinguishable MISO response."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    dut.spi_s_ss.value = 0
    await RisingEdge(dut.HCLK)
    await _shift_byte(dut, 0x56)
    # Follow with some clocked bytes the way a host might if it mistakenly
    # thought this opened a framed command; nothing should be interpreted.
    await _shift_byte(dut, 0xFF)
    await _shift_byte(dut, 0xFF)
    dut.spi_s_ss.value = 1
    await RisingEdge(dut.HCLK)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert not stub.requests, \
        "the reserved opcode 0x56 produced a debug request"


# TEST 16
@spi_s_test()
async def test_bytes_bypass_rx_fifo(dut):
    """On any dedicated debug opcode's data phase, payload bytes go to the
    bus, not the RX FIFO (GRPR-SPIS-032)."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_bus_write_frame(dut, 0x0000_0200, [0xAB, 0xCD])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    status, _ = await ahb_read(dut, ADDR_STATUS)
    assert status & STATUS_RX_EMPTY, \
        "RX FIFO took a byte that should have gone to the bus"
    assert rx_level(status) == 0, \
        f"RX_LEVEL is {rx_level(status)}, expected 0 on the debug path"


# TEST 17
@spi_s_test()
async def test_bus_error_is_reported_not_hung(dut):
    """A refused access is flagged and the frame still completes.

    The host is clocking SCK and cannot be held off, so an error must be
    reported through IRQ_STATUS rather than stalling the wire (GRPR-SPIS-033).
    """
    await init_test(dut)

    stub = DebugStub(dut, err_addrs=[0x0000_0300]).start()
    await dbg_bus_write_frame(dut, 0x0000_0300, [0x99])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    irq, _ = await ahb_read(dut, ADDR_IRQ_STATUS)
    assert irq & IRQ_OVERRUN, \
        "a refused debug access was not reported in IRQ_STATUS"
    assert stub.memory.get(0x0000_0300) is None, \
        "an errored write must not reach memory"


# TEST 18
@spi_s_test()
async def test_request_is_byte_sized(dut):
    """Every dedicated debug opcode presents dbg_req_size=0 (byte), since
    the SPI frame is a byte stream (GRPR-SPIS-030's byte-sized note, still
    true for the dedicated opcode set)."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    await dbg_bus_write_frame(dut, 0x0000_0500, [0x01])
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert int(dut.dbg_req_size.value) == 0, \
        f"dbg_req_size is {int(dut.dbg_req_size.value)}, expected 0 (byte)"


# TEST 19
@spi_s_test()
async def test_ss_deassertion_aborts_without_disturbing_lock(dut):
    """Raising SS mid-frame returns the decoder to idle (GRPR-SPIS-022) and
    does not itself issue a request for an incomplete frame."""
    await init_test(dut)

    stub = DebugStub(dut).start()
    dut.spi_s_ss.value = 0
    await RisingEdge(dut.HCLK)
    await _shift_byte(dut, OP_BUS_LOCK)
    # Abort before the flags byte completes.
    dut.spi_s_ss.value = 1
    await RisingEdge(dut.HCLK)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub.stop()

    assert not stub.requests, \
        "an aborted BUS_LOCK frame issued a debug request anyway"

    # A fresh, complete frame afterwards still works -- the decoder actually
    # resynchronised rather than wedging.
    stub2 = DebugStub(dut).start()
    await dbg_bus_unlock_frame(dut)
    for _ in range(4):
        await RisingEdge(dut.HCLK)
    stub2.stop()
    assert stub2.requests, \
        "decoder did not resynchronise after SS aborted the prior frame"
