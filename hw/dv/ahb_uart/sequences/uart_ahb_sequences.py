import cocotb
from cocotb.triggers import Timer

from pyuvm import ConfigDB, uvm_sequence

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem
from hw.dv.uvc.uart.uart_sequences import UartByteSequence

# FIXME - Use the pyUVM register model?

# UART MEMORY MAP ================
ADDR_CTRL   = 0x00
ADDR_STATUS = 0x04
ADDR_TXDATA = 0x08
ADDR_RXDATA = 0x0C

CTRL_ENABLE = 1 << 0
CTRL_TX_EN  = 1 << 1
CTRL_RX_EN  = 1 << 2
CTRL_RX_RESYNC_EN = 1 << 3

STATUS_TX_EMPTY = 1 << 0
STATUS_RX_EMPTY = 1 << 2
STATUS_RX_FRAME_ERROR = 1 << 5
STATUS_RX_BREAK = 1 << 6
# ================================


AHB_UART_OVERSAMPLE = 8       # matches hw/rtl/uart/uart.sv's fixed OVERSAMPLE parameter
MAX_CLK_DIV = 1023            # CTRL register's clk_div field is 10 bits wide

def _clk_div_for_baud(baud_rate: int, clk_period_ns: int) -> int:
    cycles_per_bit = (1e9 / baud_rate) / clk_period_ns
    clk_div = max(0, round(cycles_per_bit / AHB_UART_OVERSAMPLE) - 1)
    if clk_div > MAX_CLK_DIV:
        raise ValueError(
            f"baud_rate={baud_rate} needs clk_div={clk_div}, which overflows "
            f"the CTRL register's 10-bit field (max {MAX_CLK_DIV}) at "
            f"clk_period_ns={clk_period_ns}/oversample={AHB_UART_OVERSAMPLE} "
            f"- raise baud_rate, or lower AhbConfig.clk_period_ns to increase the clock frequency"
        )
    return clk_div

class UartAhbBaseSequence(uvm_sequence):
    def __init__(self, name="uart_ahb_base_sequence"):
        super().__init__(name)
        self.uart_cfg = None
        self.ahb_cfg = None
        self.dut = cocotb.top

    def get_config(self):
        self.sequencer = ConfigDB().get(None, "", "UART_AHB_SEQR")
        self.uart_cfg = ConfigDB().get(None, "", "UART_CFG")
        self.ahb_cfg = ConfigDB().get(None, "", "AHB_CFG")

    async def ahb_write(self, addr: int, data: int):
        item = AHB3LiteSeqItem(name=f"wr_{addr:02x}", addr=addr, is_write=True, wdata=data)
        await self.start_item(item)
        await self.finish_item(item)
        if item.hresp != 0:
            msg = f"AHB write to 0x{addr:02x} failed with HRESP=1"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)
        return item

    async def ahb_read(self, addr: int):
        item = AHB3LiteSeqItem(name=f"rd_{addr:02x}", addr=addr, is_write=False)
        await self.start_item(item)
        await self.finish_item(item)
        return item

    async def configure_uart(self):
        clk_div = _clk_div_for_baud(self.uart_cfg.baud_rate, self.ahb_cfg.clk_period_ns)
        self.sequencer.logger.info(
            f"Configuring UART for baud_rate={self.uart_cfg.baud_rate} "
            f"(clk_div={clk_div})"
        )

        # Configure the UART over AHB: enable, TX/RX, resync, and set the clock divider.
        # The clock divider is a 10-bit value in bits [25:16] of the CTRL register.
        ctrl = CTRL_ENABLE | CTRL_TX_EN | CTRL_RX_EN | CTRL_RX_RESYNC_EN
        ctrl |= (clk_div & 0x3FF) << 16
        await self.ahb_write(ADDR_CTRL, ctrl)

        # FIXME - frontdoor read checks in seq are a little bit naughty...
        rd = await self.ahb_read(ADDR_CTRL)
        if (rd.rdata & 0x03FF0000) != (ctrl & 0x03FF0000):
            msg = "CTRL clk_div readback mismatch"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        if (rd.rdata & 0x0F) != (ctrl & 0x0F):
            msg = "CTRL enable bits readback mismatch"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

    async def wait_for_status(self, mask: int, value: int, max_reads: int = 200):
        for _ in range(max_reads):
            rd = await self.ahb_read(ADDR_STATUS)
            if (rd.rdata & mask) == value:
                return rd.rdata
        msg = f"STATUS mask 0x{mask:08x} did not reach value 0x{value:08x}"
        self.sequencer.logger.warning(msg)
        raise AssertionError(msg)

    async def drive_uart_frame(self, byte_value: int, force_bad_stop: bool = False, break_low_bits: int = 0):
        self.dut.uart_rx.value = 1
        await self.wait_uart_bits(2)

        self.dut.uart_rx.value = 0
        await self.wait_uart_bits(1)

        for bit_index in range(8):
            self.dut.uart_rx.value = (byte_value >> bit_index) & 1
            await self.wait_uart_bits(1)

        if break_low_bits > 0:
            self.dut.uart_rx.value = 0
            await self.wait_uart_bits(break_low_bits)
        elif force_bad_stop:
            self.dut.uart_rx.value = 0
            await self.wait_uart_bits(1)
        else:
            self.dut.uart_rx.value = 1
            await self.wait_uart_bits(1)

        self.dut.uart_rx.value = 1
        await self.wait_uart_bits(2)

    async def wait_uart_bits(self, bit_count: int):
        await Timer(bit_count * self.uart_cfg.bit_period_ns, unit="ns")

class UartSanitySequence(UartAhbBaseSequence):
    async def body(self):
        self.get_config()
        self.sequencer.logger.info(f"Starting {self.get_name()}")
        await self.configure_uart()

        # Sanity write path: push a byte into TXDATA and confirm the write completes.
        await self.ahb_write(ADDR_TXDATA, 0xA5)
        await self.wait_for_status(STATUS_TX_EMPTY, STATUS_TX_EMPTY)

        # Sanity read path: drive the UART RX pin, then read RXDATA back through AHB.
        await self.drive_uart_frame(0x3C)
        await self.wait_for_status(STATUS_RX_EMPTY, 0)
        rx_item = await self.ahb_read(ADDR_RXDATA)
        if (rx_item.rdata & 0xFF) != 0x3C:
            msg = f"RXDATA mismatch: expected 0x3c got 0x{(rx_item.rdata & 0xFF):02x}"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        # Check the status register still reads back and does not flag an error.
        status = await self.ahb_read(ADDR_STATUS)
        if status.rdata & (STATUS_RX_FRAME_ERROR | STATUS_RX_BREAK):
            msg = "Unexpected RX error/break status during sanity test"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        self.sequencer.logger.info(f"{self.get_name()} passed")

class UartHelloWorldSequence(UartAhbBaseSequence):
    """Minimal end-to-end check: enable the UART over AHB, send one byte
    through the UartAgent (not by bit-banging the pin directly, unlike
    UartSanitySequence above), and confirm it shows up in RXDATA via the AHB
    agent. Exercises both VIPs plus the env's ConfigDB wiring in one pass."""

    HELLO_BYTE = 0x55

    async def body(self):
        self.get_config()
        self.sequencer.logger.info(f"Starting {self.get_name()}")
        await self.configure_uart()

        uart_seqr = ConfigDB().get(None, "", "UART_SEQR")
        send_seq = UartByteSequence("send_hello", byte_value=self.HELLO_BYTE)
        self.sequencer.logger.info(f"Sending hello byte 0x{self.HELLO_BYTE:02x} via UartAgent")
        
        await send_seq.start(uart_seqr)

        await self.wait_for_status(STATUS_RX_EMPTY, 0)

        rx_item = await self.ahb_read(ADDR_RXDATA)
        if (rx_item.rdata & 0xFF) != self.HELLO_BYTE:
            msg = (
                f"Hello-world byte mismatch: expected 0x{self.HELLO_BYTE:02x} "
                f"got 0x{(rx_item.rdata & 0xFF):02x}"
            )
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)
