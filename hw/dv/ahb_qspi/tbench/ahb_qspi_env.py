from pyuvm import ConfigDB, uvm_env

from hw.dv.uvc.ahb3lite import AHB3LiteAgent

from ..qspi_reg_model import Ahb3LiteRegAdapter, QspiRegBlock
from .ahb_config import AhbConfig


# ConfigDB keys shared by the environment, tests and sequences.
AHB_CFG_KEY = "AHB_CFG"
QSPI_AHB_SEQR_KEY = "QSPI_AHB_SEQR"
QSPI_REG_MODEL_KEY = "QSPI_REG_MODEL"


class QspiAhbEnv(uvm_env):
    """
    Register-shell verification environment for ahb_qspi.

    This milestone intentionally contains only the existing active AHB3-Lite
    agent and the QSPI register model. A QSPI serial-protocol agent will be
    added when the real transaction engine and external pin behaviour exist.
    """

    def build_phase(self):
        # Existing active AHB3-Lite agent used to drive and monitor register
        # accesses on the DUT.
        self.ahb_agent = AHB3LiteAgent("ahb_agent", self)

        # Single source of truth for the HCLK period used by the testbench.
        self.ahb_cfg = AhbConfig()
        ConfigDB().set(None, "*", AHB_CFG_KEY, self.ahb_cfg)

        # Frontdoor pyuvm register model for CTRL, CMD, STATUS, ADDR and DATA.
        #
        # uvm_reg_block does not automatically invoke the block-level build()
        # method in its constructor, so build() is called explicitly here.
        self.reg_model = QspiRegBlock("reg_model")
        self.reg_model.build()

    def connect_phase(self):
        # Make the AHB sequencer available to standalone QSPI sequences.
        ConfigDB().set(
            None,
            "*",
            QSPI_AHB_SEQR_KEY,
            self.ahb_agent.sequencer,
        )

        # Connect register-model frontdoor operations to the existing AHB
        # sequencer through the repository's register adapter.
        reg_map = self.reg_model.blk_get_def_map()
        reg_map.set_adapter(Ahb3LiteRegAdapter("ahb3lite_reg_adapter"))
        reg_map.set_sequencer(self.ahb_agent.sequencer)

        ConfigDB().set(
            None,
            "*",
            QSPI_REG_MODEL_KEY,
            self.reg_model,
        )
