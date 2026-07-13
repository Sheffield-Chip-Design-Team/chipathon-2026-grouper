from pyuvm import ConfigDB, uvm_env

from hw.dv.uvc.ahb3lite import AHB3LiteAgent
from hw.dv.uvc.uart import UartAgent, UartConfig

from .ahb_config import AhbConfig


class UartAhbEnv(uvm_env):
    def build_phase(self):
        # AHB3LiteAgent to drive and monitor the AHB bus.
        self.ahb_agent = AHB3LiteAgent("ahb_agent", self)

        # Passive agent to monitor the UART tx pin.
        self.uart_rx_agent = UartAgent("uart_rx_agent", self, is_active=True)
        # Active agent to drive the UART rx pin and self-observe it.
        self.uart_tx_agent = UartAgent("uart_tx_agent", self, is_active=False)

        # Universal UART Config
        ConfigDB().set(None, "*", "UART_CFG", UartConfig(baud_rate=1_250_000))

        ConfigDB().set(self.uart_rx_agent, "*", "UART_CFG", UartConfig(
            baud_rate=1_250_000,
            vip_tx="uart_rx",
            vip_rx="uart_rx",
        ))

        ConfigDB().set(self.uart_tx_agent, "*", "UART_CFG", UartConfig(
            baud_rate=1_250_000,
            vip_rx="uart_tx",
        ))

        # HCLK's own period - what drives the Clock() in UartTestBase and
        # what the clk_div register math in uart_ahb_sequences.py is derived
        # from, so both stay in sync with a single source of truth.
        ConfigDB().set(None, "*", "AHB_CFG", AhbConfig())

    def connect_phase(self):
        ConfigDB().set(None, "*", "UART_AHB_SEQR", self.ahb_agent.sequencer)
        ConfigDB().set(None, "*", "UART_SEQR", self.uart_rx_agent.sequencer)
