import logging
import os

import cocotb
from cocotb.clock import Clock

import pyuvm
from pyuvm import ConfigDB, uvm_test

from ..tbench.ahb_uart_env import UartAhbEnv
from ..sequences.uart_ahb_base_sequence import UartAhbBaseSequence
from ..sequences.uart_ahb_sequence_lib import (
    UartHelloWorldSequence,
    UartRandomMoveSequence,
    UartSanitySequence,
)

class UartTestBase(uvm_test):
    RANDOMIZE_BAUD = False  # subclasses opt in; existing tests untouched

    def build_phase(self):
        # cocotb already seeds Python's global `random` from RANDOM_SEED (or
        # COCOTB_RANDOM_SEED) before any pyuvm phase runs, and logs it via
        # its own logger - this just re-surfaces the value through
        # self.logger so it's visible in the pyuvm-formatted log stream.
        self.logger.info(f"cocotb RANDOM_SEED={cocotb.RANDOM_SEED}")
        self.env = UartAhbEnv("env", self, randomize_baud=self.RANDOMIZE_BAUD)

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

        # Initial reset goes through the same helper a mid-test reset move
        # uses (UartRandomResetSequence), so the two can never drift apart.
        await UartAhbBaseSequence("initial_reset").reset_dut()

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


@pyuvm.test()
class UartRandomTest(UartTestBase):
    """Constrained-random layered test: baud rate picked once at env build
    time, then a random count/order of config/reset/data moves layered
    together in a single run (UartRandomMoveSequence), instead of one fixed
    sequence per test."""

    RANDOMIZE_BAUD = True

    def end_of_elaboration_phase(self):
        self.main_sequence = UartRandomMoveSequence("random_moves")
