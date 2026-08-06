import cocotb
from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB, uvm_analysis_port, uvm_driver

from .gpio_config import resolve_pin


class GpioDriver(uvm_driver):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self.cfg = ConfigDB().get(None, "", "GPIO_CFG")

        self.clk = resolve_pin(self.dut, self.cfg.clk_pin)
        self.tx = resolve_pin(self.dut, self.cfg.dut_rx_pin)
        self.logger.info(f"GpioDriver driving DUT input pin: {self.cfg.dut_rx_pin}")

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.drive(item)
            self.ap.write(item)
            self.seq_item_port.item_done()

    async def drive(self, item):
        self.logger.debug(f"Driving GPIO pin value={item.value} for {item.hold_cycles} cycles")
        self.tx.value = item.value
        for _ in range(item.hold_cycles):
            await RisingEdge(self.clk)
