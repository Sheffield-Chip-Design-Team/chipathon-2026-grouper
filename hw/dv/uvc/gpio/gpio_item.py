from pyuvm import uvm_sequence_item


class GpioItem(uvm_sequence_item):
    def __init__(self, name: str = "gpio_item", value: int = 0, hold_cycles: int = 1):
        super().__init__(name)
        self.value = value & 0x1
        self.hold_cycles = hold_cycles

    def __str__(self):
        return f"{self.get_name()}(value={self.value}, hold_cycles={self.hold_cycles})"
