import os

import cocotb
from cocotb.clock import Clock

import pyuvm
from pyuvm import ConfigDB, uvm_root, uvm_test

from .uart_rx_config import UartRxConfig
from .uart_rx_env import UartRxEnv
from .uart_rx_sequences import UartRxBadStopSequence, UartRxBreakSequence, UartRxLoopbackSequence

class UartRxTestBase(uvm_test):
    def build_phase(self):
        self.env = UartRxEnv("env", self)

    def end_of_elaboration_phase(self):
        pass

    async def run_phase(self):
        self.raise_objection()
        self.cfg = UartRxConfig()
        ConfigDB().set(None, "*", "UART_RX_CFG", self.cfg)
        cocotb.start_soon(Clock(cocotb.top.clk, self.cfg.clk_period_ns, "ns").start())
        # await self.loopback.start()
        self.drop_objection()
