import cocotb
from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB, uvm_analysis_port, uvm_component

from .gpio_config import resolve_pin
from .gpio_item import GpioItem


class GpioMonitor(uvm_component):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self.cfg = ConfigDB().get(None, "", "GPIO_CFG")

        self.clk = resolve_pin(self.dut, self.cfg.clk_pin)
        self.rx = resolve_pin(self.dut, self.cfg.dut_tx_pin)
        self.logger.info(f"GpioMonitor sampling DUT output pin: {self.cfg.dut_tx_pin}")

    async def run_phase(self):
        last_value = None
        while True:
            await RisingEdge(self.clk)
            value = int(self.rx.value)
            if value != last_value:
                self.logger.debug(f"Sampled GPIO pin change: {last_value} -> {value}")
                self.ap.write(GpioItem("gpio_mon_item", value=value))
                last_value = value
