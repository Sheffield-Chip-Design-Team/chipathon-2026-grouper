import random

from pyuvm import uvm_sequence_item

class UartItem(uvm_sequence_item):
    def __init__(self, name: str = "uart_item", data: int = 0):
        super().__init__(name)
        self.start_bit       = 0
        self.data            = data & 0xFF
        self.stop_bits       = 1
        self.break_condition = False
        self.bad_stop_bit    = False

    def randomize(self, byte_value: int = None, allow_break: bool = True,
                  allow_bad_stop: bool = True, stop_bit_range: tuple = (1, 3),
                  break_probability: float = 0.1, bad_stop_probability: float = 0.1) -> "UartItem":
        """Hand-rolled constrained-random field fill - pyuvm has no built-in
        randomize()/rand/constraint, this follows its own documented
        (TinyALU example) idiom instead. break_condition and bad_stop_bit
        are mutually exclusive in UartDriver.drive_frame (break_condition is
        checked first), so keep them mutually exclusive here too."""
        roll = random.random()
        self.break_condition = allow_break and roll < break_probability
        self.bad_stop_bit = (
            not self.break_condition and allow_bad_stop
            and roll < break_probability + bad_stop_probability
        )
        self.stop_bits = random.randint(*stop_bit_range)

        if self.break_condition:
            self.data = 0x00  # required - see uart_rx.sv's break_detect logic
        else:
            self.data = (byte_value if byte_value is not None else random.randint(0, 255)) & 0xFF
        return self

    def __str__(self):
        return f"{self.get_name()}(data=0x{self.data:02x})"
