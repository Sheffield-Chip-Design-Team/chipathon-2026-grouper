from pyuvm import ConfigDB, uvm_env

from hw.dv.ahb3.ahb3lite_driver import Ahb3LiteDriver
from hw.dv.ahb3.ahb3lite_monitor import Ahb3LiteMonitor
from hw.dv.ahb3.ahb3lite_sequencer import Ahb3LiteSequencer

class UartAhbEnv(uvm_env):
    def build_phase(self):
        self.ahb_seqr = Ahb3LiteSequencer("ahb_seqr", self)
        self.ahb_driver = Ahb3LiteDriver("ahb_driver", self)
        self.ahb_monitor = Ahb3LiteMonitor("ahb_monitor", self)

    def connect_phase(self):
        self.ahb_driver.seq_item_port.connect(self.ahb_seqr.seq_item_export)
        ConfigDB().set(None, "*", "UART_AHB_SEQR", self.ahb_seqr)
