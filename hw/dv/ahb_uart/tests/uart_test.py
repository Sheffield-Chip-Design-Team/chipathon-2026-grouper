import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import pyuvm
from pyuvm import ConfigDB, uvm_test

from .uart_ahb_env import UartAhbEnv
from .uart_ahb_sequences import UartSanitySequence
from .uart_rx_config import UartRxConfig

LANGUAGE = os.getenv("TOPLEVEL_LANG", "verilog")


class UartTestBase(uvm_test):
    def build_phase(self):
        self.env = UartAhbEnv("env", self)

    def end_of_elaboration_phase(self):
        self.sanity = UartSanitySequence("sanity")

    async def run_phase(self):
        self.raise_objection()
        self.cfg = UartRxConfig()
        ConfigDB().set(None, "*", "UART_RX_CFG", self.cfg)
        if LANGUAGE == "verilog":
            cocotb.start_soon(Clock(cocotb.top.HCLK, self.cfg.clk_period_ns, "ns").start())
        cocotb.top.HRESETn.value = 0
        for _ in range(2):
            await RisingEdge(cocotb.top.HCLK)
        cocotb.top.HRESETn.value = 1
        await RisingEdge(cocotb.top.HCLK)
        await self.sanity.start()
        self.drop_objection()


@pyuvm.test()
class UartSanityTest(UartTestBase):
    pass
