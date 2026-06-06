from pyuvm import uvm_component

from .uart_driver import UartDriver
from .uart_monitor import UartMonitor 
from .uart_sequencer import UartSequencer

class AHB3LiteAgent(uvm_component):

    def __init__(self, name, parent, is_active: bool = True):
        super().__init__(name, parent)
        self.is_active = is_active

    def build_phase(self):
        self.monitor = AHB3LiteMonitor("mon", self)
        
        if self.is_active:
            self.driver = AHB3LiteDriver("drv", self)
            self.sequencer = AHB3LiteSequencer("seqr", self)

    def connect_phase(self):
        if self.is_active:
            self.driver.ap.connect(self.sequencer.ap) 
            