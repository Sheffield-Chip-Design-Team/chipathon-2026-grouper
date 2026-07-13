from pyuvm import uvm_component

from .uart_driver import UartDriver
from .uart_monitor import UartMonitor
from .uart_sequencer import UartSequencer


class UartAgent(uvm_component):

    def __init__(self, name, parent, is_active: bool = True):
        super().__init__(name, parent)
        self.is_active = is_active

    def build_phase(self):
        self.monitor = UartMonitor("mon", self)

        if self.is_active:
            self.driver = UartDriver("drv", self)
            self.sequencer = UartSequencer("seqr", self)

    def connect_phase(self):
        if self.is_active:
            self.driver.seq_item_port.connect(self.sequencer.seq_item_export)
