from dataclasses import dataclass

@dataclass
class AhbConfig:
    """Top-level bus clock this testbench drives on HCLK."""
    clk_period_ns: int = 10
