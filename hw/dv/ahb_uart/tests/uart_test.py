import logging
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import pyuvm
from pyuvm import ConfigDB, uvm_test

from ..tbench.ahb_uart_env import UartAhbEnv
from ..sequences.uart_ahb_sequences import UartHelloWorldSequence, UartSanitySequence

class UartTestBase(uvm_test):
    def build_phase(self):
        self.env = UartAhbEnv("env", self)

    def start_of_simulation_phase(self):
        # UVM_VERBOSITY=DEBUG|INFO|WARNING|ERROR controls every component's
        # self.logger via pyuvm's own set_logging_level_hier - no new logging
        # mechanism, just an env-var entry point into the existing one. Set
        # here (not build_phase) so the whole hierarchy - env, agents,
        # driver/monitor/sequencer - already exists to recurse into.
        verbosity = os.environ.get("UVM_VERBOSITY")
        if verbosity:
            self.set_logging_level_hier(getattr(logging, verbosity.upper()))

    async def run_phase(self):
        self.raise_objection()
        # UartAhbEnv.build_phase already registered UART_CFG/AHB_CFG - reuse
        # them rather than creating second, divergent config instances.
        self.uart_cfg = ConfigDB().get(None, "", "UART_CFG")
        self.ahb_cfg = ConfigDB().get(None, "", "AHB_CFG")

        cocotb.start_soon(Clock(cocotb.top.HCLK, self.ahb_cfg.clk_period_ns, "ns").start())
        cocotb.top.HRESETn.value = 0
       
        for _ in range(2):
            await RisingEdge(cocotb.top.HCLK)
            
        cocotb.top.HRESETn.value = 1
        await RisingEdge(cocotb.top.HCLK)
        await self.main_sequence.start()
        self.drop_objection()


@pyuvm.test()
class UartHelloWorldTest(UartTestBase):
    """Simplest possible smoke test: reset the DUT, send one byte through
    the UartAgent, and read it back over AHB. Validates that the env,
    both VIPs, and the ConfigDB wiring between them actually work."""

    def end_of_elaboration_phase(self):
        self.main_sequence = UartHelloWorldSequence("hello_world")


@pyuvm.test()
class UartSanityTest(UartTestBase):
    def end_of_elaboration_phase(self):
        self.main_sequence = UartSanitySequence("sanity")
