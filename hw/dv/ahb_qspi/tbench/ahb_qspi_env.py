from pyuvm import ConfigDB, uvm_env

from hw.dv.uvc.ahb3lite import AHB3LiteAgent
from hw.dv.uvc.uart import UartAgent, UartConfig

from ..qspi_clk_math import pick_random_baud_rate
from ..qspi_reg_model import Ahb3LiteRegAdapter, UartRegBlock
from .ahb_config import AhbConfig


class UartAhbEnv(uvm_env):
    def __init__(self, name, parent, randomize_baud: bool = False):
        super().__init__(name, parent)
        self.randomize_baud = randomize_baud

    def build_phase(self):
        # AHB3LiteAgent to drive and monitor the AHB bus.
        self.ahb_agent = AHB3LiteAgent("ahb_agent", self)

        # Active agent to drive the UART rx pin and self-observe it.
        self.uart_rx_agent = UartAgent("uart_rx_agent", self, is_active=True)
        # Passive agent to monitor the UART tx pin.
        self.uart_tx_agent = UartAgent("uart_tx_agent", self, is_active=False)

        ahb_cfg = AhbConfig()
        # Computed once and reused across all three UartConfig registrations
        # below - computing it more than once risks the global fallback and
        # the two agent-scoped configs disagreeing with each other.
        if self.randomize_baud:
            baud_rate = pick_random_baud_rate(ahb_cfg.clk_period_ns)
        else:
            baud_rate = 1_250_000
        self.logger.info(f"UartAhbEnv: baud_rate={baud_rate} (randomize_baud={self.randomize_baud})")

        # Global fallback: UartAhbBaseSequence.get_config() (a uvm_sequence,
        # not a uvm_component) can't pass itself as ConfigDB context to reach
        # the two scoped configs below - it only ever needs
        # baud_rate/bit_period_ns (for clk_div math and bit-banging timing),
        # not a specific pin, so this generic "*" entry covers it.
        #
        # baud_rate is chosen (or, if randomized, validated) to divide
        # AhbConfig.clk_period_ns (10ns/100MHz) exactly at the default value:
        # cycles_per_bit = (1e9/1_250_000)/10 = 80, and 80/OVERSAMPLE(8) = 10,
        # so clk_div_for_baud() lands on clk_div=9 with no rounding. A
        # mismatched pair (e.g. the VIP's own DEFAULT_BAUD_RATE of 1_000_000
        # against this same clock) rounds cycles_per_bit/8 from 12.5 to 12,
        # silently running the DUT ~4% slower than the driver/monitor's
        # real-time Timer waits.
        ConfigDB().set(None, "*", "UART_CFG", UartConfig(baud_rate=baud_rate))

        # Scoped to each agent's own hierarchy (driver/monitor fetch UART_CFG
        # with context=self, so the more specific path wins over the "*"
        # fallback above - see pyuvm's ConfigDB.get()).
        ConfigDB().set(self.uart_rx_agent, "*", "UART_CFG", UartConfig(
            baud_rate=baud_rate,
            vip_tx="uart_rx",
            vip_rx="uart_rx",
        ))
        ConfigDB().set(self.uart_tx_agent, "*", "UART_CFG", UartConfig(
            baud_rate=baud_rate,
            vip_rx="uart_tx",
        ))

        # HCLK's own period - what drives the Clock() in UartTestBase and
        # what the clk_div register math in uart_clk_math.py is derived
        # from, so both stay in sync with a single source of truth.
        ConfigDB().set(None, "*", "AHB_CFG", ahb_cfg)

        # pyuvm register model (frontdoor only) for CTRL/STATUS/TXDATA/RXDATA
        # - see uart_reg_model.py. uvm_reg_block doesn't auto-call build() in
        # __init__, so it must be called explicitly here.
        self.reg_model = UartRegBlock("reg_model")
        self.reg_model.build()

    def connect_phase(self):
        ConfigDB().set(None, "*", "UART_AHB_SEQR", self.ahb_agent.sequencer)
        ConfigDB().set(None, "*", "UART_SEQR", self.uart_rx_agent.sequencer)

        # The register model's map needs the adapter (translates
        # uvm_reg_bus_op <-> AHB3LiteSeqItem) and the real sequencer wired up
        # before any reg.write()/read() can be issued.
        reg_map = self.reg_model.blk_get_def_map()
        reg_map.set_adapter(Ahb3LiteRegAdapter("ahb3lite_reg_adapter"))
        reg_map.set_sequencer(self.ahb_agent.sequencer)
        ConfigDB().set(None, "*", "UART_REG_MODEL", self.reg_model)

        # The passive uart_tx_agent's monitor is the only witness for "did
        # the DUT actually transmit what was written to TXDATA" - nothing
        # else exposes a handle to it for a sequence to poll.
        ConfigDB().set(None, "*", "UART_TX_MONITOR", self.uart_tx_agent.monitor)
