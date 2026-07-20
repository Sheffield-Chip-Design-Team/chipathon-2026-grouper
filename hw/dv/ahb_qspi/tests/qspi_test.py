import logging
import os

import cocotb
from cocotb.clock import Clock

import pyuvm
from pyuvm import ConfigDB, uvm_test

from ..sequences.qspi_ahb_base_sequence import QspiAhbBaseSequence
from ..sequences.qspi_ahb_sequence_lib import QspiRegisterShellSequence
from ..tbench.ahb_qspi_env import AHB_CFG_KEY, QspiAhbEnv


class QspiTestBase(uvm_test):
    """
    Common pyuvm test structure for the AHB QSPI block.
    """

    def build_phase(self):
        self.logger.info(
            f"cocotb RANDOM_SEED={cocotb.RANDOM_SEED}"
        )

        self.env = QspiAhbEnv(
            "env",
            self,
        )

    def start_of_simulation_phase(self):
        verbosity = os.environ.get(
            "UVM_VERBOSITY"
        )

        if verbosity:
            self.set_logging_level_hier(
                getattr(
                    logging,
                    verbosity.upper(),
                )
            )

    async def run_phase(self):
        self.raise_objection()

        try:
            ahb_cfg = ConfigDB().get(
                None,
                "",
                AHB_CFG_KEY,
            )

            cocotb.start_soon(
                Clock(
                    cocotb.top.HCLK,
                    ahb_cfg.clk_period_ns,
                    "ns",
                ).start()
            )

            # Use the same reset primitive as all directed sequences.
            await QspiAhbBaseSequence(
                "initial_reset"
            ).reset_dut()

            await self.main_sequence.start()
        finally:
            self.drop_objection()


@pyuvm.test()
class QspiRegisterShellTest(QspiTestBase):
    """
    Directed test of the five-register AHB QSPI shell.

    External QSPI protocol behaviour is intentionally excluded until qspi.sv
    is replaced with the real transaction engine.
    """

    def end_of_elaboration_phase(self):
        self.main_sequence = QspiRegisterShellSequence(
            "register_shell"
        )