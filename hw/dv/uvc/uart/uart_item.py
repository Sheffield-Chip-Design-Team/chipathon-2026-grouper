from pyuvm import uvm_sequence_item

class UartItem(uvm_sequence_item):
    def __init__(self, name: str = "uart_item", data: int = 0):
        super().__init__(name)
        self.start_bit       = 0
        self.data            = data & 0xFF
        self.stop_bits       = 1
        self.break_condition = False
        self.bad_stop_bit    = False
 
    def __str__(self):
        return f"{self.get_name()}(data=0x{self.data:02x})"
