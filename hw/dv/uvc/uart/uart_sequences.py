from pyuvm import ConfigDB, uvm_sequence

from .uart_item import UartItem


class UartBaseSequence(uvm_sequence):
    def get_config(self):
        self.sequencer = ConfigDB().get(None, "", "UART_SEQR")

    async def send_items(self, items):
        for item in items:
            await self.start_item(item)
            await self.finish_item(item)


class UartByteSequence(UartBaseSequence):
    """Send a single byte through the UART driver (drives the DUT's rx pin)."""

    def __init__(self, name="uart_byte_sequence", byte_value: int = 0x00):
        super().__init__(name)
        self.byte_value = byte_value

    async def body(self):
        self.get_config()
        await self.send_items([UartItem("byte_item", byte_value=self.byte_value)])
