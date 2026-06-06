from dataclasses import dataclass

DEFAULT_CLK_PERIOD_NS = 10
DEFAULT_OVERSAMPLE = 8
DEFAULT_RX_TIMEOUT_CYCLES = 4000

@dataclass
class UartRxConfig:
    clk_period_ns: int = DEFAULT_CLK_PERIOD_NS
    oversample: int = DEFAULT_OVERSAMPLE
    rx_timeout_cycles: int = DEFAULT_RX_TIMEOUT_CYCLES
