import cocotb
from cocotb.triggers import RisingEdge, Timer

from pyuvm import uvm_analysis_port, uvm_component

from .ahb3lite_item import AHB3LiteSeqItem
from .ahb3lite_driver import DEFAULT_SIGNAL_MAP

class AHB3LiteMonitor(uvm_component):
    def __init__(self, name, parent, signal_map=None):
        super().__init__(name, parent)
        self.signal_map = dict(DEFAULT_SIGNAL_MAP)
        if signal_map:
            self.signal_map.update(signal_map)

    def _sig(self, signal_name):
        return getattr(self.dut, self.signal_map[signal_name])

    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.dut = cocotb.top

    async def run_phase(self):
        pending = None
        
        while True:
            await RisingEdge(self._sig("HCLK"))

            if pending is not None:
                await Timer(1, "ps")
                item = AHB3LiteSeqItem(
                    "ahb3_mon_item",
                    addr=pending["addr"],
                    is_write=pending["is_write"],
                    size=pending["size"],
                    trans=pending["trans"],
                )
                item.hreadyout = int(self._sig("HREADYOUT").value)
                item.hresp = int(self._sig("HRESP").value)
                if pending["is_write"]:
                    item.wdata = int(self._sig("HWDATA").value) & 0xFFFFFFFF
                else:
                    item.rdata = int(self._sig("HRDATA").value) & 0xFFFFFFFF
                self.ap.write(item)
                pending = None

            is_access = (
                int(self._sig("HREADYIN").value)
                and int(self._sig("HSEL").value)
                and (int(self._sig("HTRANS").value) != 0)
            )
            if is_access:
                pending = {
                    "addr": int(self._sig("HADDR").value) & 0xFFFFFFFF,
                    "is_write": bool(int(self._sig("HWRITE").value)),
                    "size": int(self._sig("HSIZE").value) & 0x7,
                    "trans": int(self._sig("HTRANS").value) & 0x3,
                }
