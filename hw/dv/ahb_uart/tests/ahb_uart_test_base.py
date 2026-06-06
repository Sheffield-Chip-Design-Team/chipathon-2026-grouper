import os

import cocotb
from cocotb.clock import Clock

import pyuvm
from pyuvm import ConfigDB, uvm_root, uvm_test

from .uart_rx_config import UartRxConfig
from .uart_rx_env import UartRxEnv
from .uart_rx_sequences import UartRxBadStopSequence, UartRxBreakSequence, UartRxLoopbackSequence

LANGUAGE = os.getenv("TOPLEVEL_LANG", "verilog")

class UartRxTestBase(uvm_test):
    def build_phase(self):
        self.env = UartRxEnv("env", self)

    def end_of_elaboration_phase(self):
        self.loopback = UartRxLoopbackSequence("loopback")
        self.break_test = UartRxBreakSequence("break_test")
        self.bad_stop_test = UartRxBadStopSequence("bad_stop_test")

    async def run_phase(self):
        self.raise_objection()
        self.cfg = UartRxConfig()
        ConfigDB().set(None, "*", "UART_RX_CFG", self.cfg)
        if LANGUAGE == "verilog":
            cocotb.start_soon(Clock(cocotb.top.clk, self.cfg.clk_period_ns, "ns").start())
        await self.loopback.start()
        self.drop_objection()


@pyuvm.test()
class UartRxLoopbackTest(UartRxTestBase):
    pass


@pyuvm.test()
class UartRxBreakTest(UartRxTestBase):
    def end_of_elaboration_phase(self):
        super().end_of_elaboration_phase()
        self.loopback = self.break_test


@pyuvm.test()
class UartRxBadStopTest(UartRxTestBase):
    def end_of_elaboration_phase(self):
        super().end_of_elaboration_phase()
        self.loopback = self.bad_stop_test
