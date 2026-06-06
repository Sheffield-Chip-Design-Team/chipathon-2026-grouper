from dataclasses import dataclass

@dataclass
class RegBlockConfig:
    num_regs: int = 16
    data_width: int = 32
    