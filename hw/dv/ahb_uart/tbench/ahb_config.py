from dataclasses import dataclass

@dataclass
class AhbConfig:
    """Top-level bus clock this testbench drives on HCLK. Separate from
    UartConfig (hw/dv/uvc/uart/uart_config.py), which is clock-independent
    and only cares about baud_rate/bit_period_ns."""
    clk_period_ns: int = 10
