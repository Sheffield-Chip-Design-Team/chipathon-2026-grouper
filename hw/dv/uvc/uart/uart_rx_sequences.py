from pyuvm import ConfigDB, uvm_sequence

from .uart_rx_item import UartRxItem


class UartRxBaseSequence(uvm_sequence):
    def __init__(self, name="uart_rx_base_sequence"):
        super().__init__(name)
        self.seqr = None

    def get_config(self):
        self.seqr = ConfigDB().get(None, "", "UART_RX_SEQR")

    async def send_items(self, items):
        for item in items:
            await self.start_item(item)
            await self.finish_item(item)


class UartRxLoopbackSequence(UartRxBaseSequence):
    async def body(self):
        self.get_config()
        pattern = [0x55, 0xA5, 0x00, 0xFF, 0x3C]
        items = [UartRxItem(f"item_{index}", value) for index, value in enumerate(pattern)]
        ConfigDB().set(None, "*", "UART_RX_EXPECTED_BYTES", pattern)
        await self.send_items(items)


class UartRxBreakSequence(UartRxBaseSequence):
    async def body(self):
        self.get_config()
        item = UartRxItem("break_item", 0x00)
        item.break_condition = True
        item.idle_bits = 3
        item.post_bits = 6
        ConfigDB().set(None, "*", "UART_RX_EXPECTED_BYTES", [])
        await self.send_items([item])


class UartRxBadStopSequence(UartRxBaseSequence):
    async def body(self):
        self.get_config()
        item = UartRxItem("bad_stop_item", 0xA5)
        item.bad_stop_bit = True
        ConfigDB().set(None, "*", "UART_RX_EXPECTED_BYTES", [])
        await self.send_items([item])
