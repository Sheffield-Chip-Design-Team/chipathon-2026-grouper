from dataclasses import dataclass, field

DEFAULT_SIGNAL_MAP = {
    "HCLK":      "HCLK",
    "HADDR":     "HADDR",
    "HBURST":    "HBURST",
    "HMASTLOCK": "HMASTLOCK",
    "HPROT":     "HPROT",
    "HSIZE":     "HSIZE",
    "HTRANS":    "HTRANS",
    "HWDATA":    "HWDATA",
    "HWRITE":    "HWRITE",
    "HREADYIN":  "HREADYIN",
    "HSEL":      "HSEL",
    "HREADYOUT": "HREADYOUT",
    "HRESP":     "HRESP",
    "HRDATA":    "HRDATA",
}

@dataclass
class AHB3LiteConfig:
    signal_map: dict = field(default_factory=lambda: dict(DEFAULT_SIGNAL_MAP))
