from pyuvm import uvm_component

from .ahb3lite_driver import AHB3LiteDriver
from .ahb3lite_monitor import AHB3LiteMonitor 
from .ahb3lite_sequencer import AHB3LiteSequencer

class AHB3LiteAgent(uvm_component):
    def __init__(self, name, parent, is_active: bool = True, signal_map=None):
        super().__init__(name, parent)
        self.is_active  = is_active
        self.signal_map = signal_map or {}

    def build_phase(self):
        self.monitor = AHB3LiteMonitor("mon", self, signal_map=self.signal_map)
        
        if self.is_active:
            self.driver    = AHB3LiteDriver("drv", self, signal_map=self.signal_map)
            self.sequencer = AHB3LiteSequencer("seqr", self)

    def connect_phase(self):
        if self.is_active:
            self.driver.seq_item_port.connect(self.sequencer.seq_item_export)
