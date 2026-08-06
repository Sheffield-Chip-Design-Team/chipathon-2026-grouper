from pyuvm import ConfigDB, uvm_sequence

from .gpio_item import GpioItem


class GpioBaseSequence(uvm_sequence):
    def get_config(self):
        self.sequencer = ConfigDB().get(None, "", "GPIO_SEQR")

    async def send_items(self, items):
        for item in items:
            await self.start_item(item)
            await self.finish_item(item)


class GpioPulseSequence(GpioBaseSequence):
    """Drive a single 0->1->0 pulse, holding each level for hold_cycles."""

    def __init__(self, name="gpio_pulse_sequence", hold_cycles=1):
        super().__init__(name)
        self.hold_cycles = hold_cycles

    async def body(self):
        self.get_config()
        items = [
            GpioItem("pulse_hi", value=1, hold_cycles=self.hold_cycles),
            GpioItem("pulse_lo", value=0, hold_cycles=self.hold_cycles),
        ]
        await self.send_items(items)
