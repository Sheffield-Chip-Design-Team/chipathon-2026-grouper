import cocotb
from cocotb.triggers import RisingEdge

from pyuvm import uvm_analysis_port, uvm_component


class UartRxMonitor(uvm_component):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.dut = cocotb.top
        self.received_bytes = []
        self.frame_errors = 0
        self.break_events = 0

    async def run_phase(self):
        while True:
            await RisingEdge(self.dut.clk)
            if int(self.dut.received.value) == 1:
                value = int(self.dut.rx_data.value)
                self.received_bytes.append(value)
                self.ap.write(value)
            if int(self.dut.rx_frame_error.value) == 1:
                self.frame_errors += 1
            if int(self.dut.rx_break.value) == 1:
                self.break_events += 1
