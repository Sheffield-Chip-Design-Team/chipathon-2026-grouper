from dataclasses import dataclass
from pyuvm import ConfigDB

@dataclass
class AHB3LiteConfig:
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

    ConfigDB().set(None, "*", "SIGNAL_MAP", DEFAULT_SIGNAL_MAP)
        