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
        await self.send_items([UartItem("byte_item", data=self.byte_value)])


class UartRandomByteSequence(UartBaseSequence):
    """Constrained-random counterpart to UartByteSequence: randomizes data/
    stop_bits/break_condition/bad_stop_bit instead of always using defaults.
    Exposes the sent item as self.item so a caller (e.g. an AHB-side
    orchestrator) can read back what was actually generated."""

    def __init__(self, name="uart_random_byte_sequence", byte_value: int = None,
                 allow_break: bool = True, allow_bad_stop: bool = True):
        super().__init__(name)
        self.byte_value = byte_value
        self.allow_break = allow_break
        self.allow_bad_stop = allow_bad_stop
        self.item = None

    async def body(self):
        self.get_config()
        item = UartItem("random_byte_item").randomize(
            byte_value=self.byte_value, allow_break=self.allow_break,
            allow_bad_stop=self.allow_bad_stop,
        )
        self.item = item
        await self.send_items([item])
