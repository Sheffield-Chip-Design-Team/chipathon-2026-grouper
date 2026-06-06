from pyuvm import uvm_sequence_item


class UartRxItem(uvm_sequence_item):
    def __init__(self, name: str = "uart_rx_item", byte_value: int = 0):
        super().__init__(name)
        self.byte_value = byte_value & 0xFF
        self.idle_bits = 2
        self.stop_bits = 1
        self.post_bits = 2
        self.break_condition = False
        self.bad_stop_bit = False

    def __str__(self):
        return f"{self.get_name()}(byte=0x{self.byte_value:02x})"
