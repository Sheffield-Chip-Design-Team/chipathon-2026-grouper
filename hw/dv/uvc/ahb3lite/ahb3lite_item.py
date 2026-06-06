from pyuvm import uvm_sequence_item

class AHB3LiteSeqItem(uvm_sequence_item):
    def __init__ (
        self,
        name: str = "ahb3_item",
        addr: int = 0,
        is_write: bool = False,
        wdata: int = 0,
        size: int = 0b010,
        trans: int = 0b10,
    ):
        super().__init__(name)
        self.addr = addr & 0xFFFFFFFF
        self.is_write = bool(is_write)
        self.wdata = wdata & 0xFFFFFFFF
        self.rdata = 0
        self.size = size & 0x7
        self.trans = trans & 0x3
        self.hreadyout = 1
        self.hresp = 0

    def __str__(self):
        direction = "WR" if self.is_write else "RD"
        return (
            f"{self.get_name()}({direction} addr=0x{self.addr:08x} "
            f"wdata=0x{self.wdata:08x} rdata=0x{self.rdata:08x} "
            f"hresp={self.hresp} hreadyout={self.hreadyout})"
        )
