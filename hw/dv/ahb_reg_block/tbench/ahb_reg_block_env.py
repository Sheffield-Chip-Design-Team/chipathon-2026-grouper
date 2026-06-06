from pyuvm import ConfigDB, uvm_env
from uvc.ahb3lite.ahb3lite_agent import AHB3LiteAgent

class AHBRegBlockEnv(uvm_env):
    def build_phase(self):
        self.agent = AHB3LiteAgent("ahb_agent", self)

    def connect_phase(self):
        self.agent.connect_phase()