import cocotb
from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB, uvm_sequence

class AHBRegBlockBaseSequence(uvm_sequence):
    def __init__(self, name="ahb_base_sequence"):
        super().__init__(name)
        self.seqr = None
        self.cfg = None
        self.dut = cocotb.top

    def get_config(self):
        self.seqr = ConfigDB().get(None, "", "UART_AHB_SEQR")
        self.cfg  = ConfigDB().get(None, "", "UART_RX_CFG")

    async def ahb_write(self, addr: int, data: int):
        item = Ahb3LiteItem(name=f"wr_{addr:02x}", addr=addr, is_write=True, wdata=data)
        await self.start_item(item)
        await self.finish_item(item)
        if item.hresp != 0:
            raise AssertionError(f"AHB write to 0x{addr:02x} failed with HRESP=1")
        return item

    async def ahb_read(self, addr: int):
        item = Ahb3LiteItem(name=f"rd_{addr:02x}", addr=addr, is_write=False)
        await self.start_item(item)
        await self.finish_item(item)
        return item


class UartSanitySequence(UartAhbBaseSequence):
    async def body(self):
        self.get_config()
        await self.configure_uart(clk_div=0)

        # Sanity write path: push a byte into TXDATA and confirm the write completes.
        await self.ahb_write(ADDR_TXDATA, 0xA5)
        await self.wait_for_status(STATUS_TX_EMPTY, STATUS_TX_EMPTY)

        # Sanity read path: drive the UART RX pin, then read RXDATA back through AHB.
        await self.drive_uart_frame(0x3C)
        await self.wait_for_status(STATUS_RX_EMPTY, 0)
        rx_item = await self.ahb_read(ADDR_RXDATA)
        if (rx_item.rdata & 0xFF) != 0x3C:
            raise AssertionError(
                f"RXDATA mismatch: expected 0x3c got 0x{(rx_item.rdata & 0xFF):02x}"
            )

        # Check the status register still reads back and does not flag an error.
        status = await self.ahb_read(ADDR_STATUS)
        if status.rdata & (STATUS_RX_FRAME_ERROR | STATUS_RX_BREAK):
            raise AssertionError("Unexpected RX error/break status during sanity test")
