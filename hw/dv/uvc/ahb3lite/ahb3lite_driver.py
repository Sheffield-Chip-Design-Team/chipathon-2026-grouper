import cocotb
from cocotb.triggers import RisingEdge, Timer
from pyuvm import uvm_analysis_port, uvm_driver, ConfigDB

HTRANS_IDLE   = 0b00
HTRANS_NONSEQ = 0b10

class AHB3LiteDriver(uvm_driver): 
    def __init__(self, name, parent, signal_map=None):
        super().__init__(name, parent)
        default_signal_map = ConfigDB.get(self, "", "signal_map") or {}
        self.signal_map = dict(default_signal_map)
        if signal_map:
            self.signal_map.update(signal_map)     

    def _sig(self, signal_name):
        return getattr(self.dut, self.signal_map[signal_name])

    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self._drive_idle()

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            await self._drive_transfer(item)
            self.ap.write(item)
            self.seq_item_port.item_done()

    def _drive_idle(self):
        self._sig("HADDR").value = 0
        self._sig("HBURST").value = 0
        self._sig("HMASTLOCK").value = 0
        self._sig("HPROT").value = 0
        self._sig("HSIZE").value = 0b010
        self._sig("HTRANS").value = HTRANS_IDLE
        self._sig("HWDATA").value = 0
        self._sig("HWRITE").value = 0
        self._sig("HREADYIN").value = 1
        self._sig("HSEL").value = 0

    async def _drive_transfer(self, item):
        await RisingEdge(self._sig("HCLK"))

        self._sig("HADDR").value = item.addr
        self._sig("HSIZE").value = item.size
        self._sig("HTRANS").value = item.trans if item.trans else HTRANS_NONSEQ
        self._sig("HWRITE").value = 1 if item.is_write else 0
        self._sig("HWDATA").value = item.wdata
        self._sig("HSEL").value = 1
        self._sig("HREADYIN").value = 1

        await RisingEdge(self._sig("HCLK"))
        await Timer(1, "ps")

        item.hreadyout = int(self._sig("HREADYOUT").value)
        item.hresp = int(self._sig("HRESP").value)

        if not item.is_write:
            item.rdata = int(self._sig("HRDATA").value) & 0xFFFF_FFFF

        self._sig("HTRANS").value = HTRANS_IDLE
        self._sig("HSEL").value = 0
        self._sig("HWRITE").value = 0
        self._sig("HWDATA").value = 0
