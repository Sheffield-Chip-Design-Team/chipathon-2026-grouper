from pyuvm import uvm_component

from .gpio_driver import GpioDriver
from .gpio_monitor import GpioMonitor
from .gpio_sequencer import GpioSequencer


class GpioAgent(uvm_component):
    def __init__(self, name, parent, is_active: bool = True):
        super().__init__(name, parent)
        self.is_active = is_active

    def build_phase(self):
        self.monitor = GpioMonitor("mon", self)

        if self.is_active:
            self.driver = GpioDriver("drv", self)
            self.sequencer = GpioSequencer("seqr", self)

    def connect_phase(self):
        if self.is_active:
            self.driver.seq_item_port.connect(self.sequencer.seq_item_export)
