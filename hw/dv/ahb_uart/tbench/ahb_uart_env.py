from pyuvm import ConfigDB, uvm_env

from hw.dv.uvc.ahb3lite import AHB3LiteDriver, AHB3LiteMonitor, AHB3LiteSequencer
from hw.dv.uvc.uart import UartAgent, UartConfig

from .ahb_config import AhbConfig


class UartAhbEnv(uvm_env):
    def build_phase(self):
        self.ahb_seqr = AHB3LiteSequencer("ahb_seqr", self)
        self.ahb_driver = AHB3LiteDriver("ahb_driver", self)
        self.ahb_monitor = AHB3LiteMonitor("ahb_monitor", self)

        self.uart_agent = UartAgent("uart_agent", self)

        # ahb_uart.sv exposes uart_rx/uart_tx as top-level ports. UartConfig
        # is clock-independent (baud_rate drives real-time Timer waits) -
        # the DUT-specific clk_div register math lives in
        # hw/dv/ahb_uart/sequences/uart_ahb_sequences.py instead.
        #
        # baud_rate is chosen to divide AhbConfig.clk_period_ns (10ns/100MHz,
        # below) exactly: cycles_per_bit = (1e9/1_250_000)/10 = 80, and
        # 80/OVERSAMPLE(8) = 10, so _clk_div_for_baud() lands on clk_div=9
        # with no rounding. A mismatched pair (e.g. the VIP's own
        # DEFAULT_BAUD_RATE of 1_000_000 against this same clock) rounds
        # cycles_per_bit/8 from 12.5 to 12, silently running the DUT ~4%
        # slower than the driver/monitor's real-time Timer waits.
        ConfigDB().set(None, "*", "UART_CFG", UartConfig(
            baud_rate=1_250_000,
            rx_pin="uart_rx",
            tx_pin="uart_tx",
        ))

        # HCLK's own period - what drives the Clock() in UartTestBase and
        # what the clk_div register math in uart_ahb_sequences.py is derived
        # from, so both stay in sync with a single source of truth.
        ConfigDB().set(None, "*", "AHB_CFG", AhbConfig())

    def connect_phase(self):
        self.ahb_driver.seq_item_port.connect(self.ahb_seqr.seq_item_export)
        ConfigDB().set(None, "*", "UART_AHB_SEQR", self.ahb_seqr)
        ConfigDB().set(None, "*", "UART_SEQR", self.uart_agent.sequencer)
