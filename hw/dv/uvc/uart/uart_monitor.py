import random

import cocotb
from cocotb.triggers import FallingEdge, Timer

from pyuvm import ConfigDB, uvm_analysis_port, uvm_component

from .uart_item import UartItem

UART_IDLE = 1
UART_START = 0

class UartMonitor(uvm_component):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.received_bytes = []
        self.frame_errors = 0

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self.uart_cfg = ConfigDB().get(self, "", "UART_CFG")
        self.bit_period = self.uart_cfg.bit_period_ns

        self.rx = self.uart_cfg.resolve_handle(self.dut, self.uart_cfg.vip_rx)
        self.logger.info(f"Sampling DUT pin: {self.uart_cfg.vip_rx}")

    async def run_phase(self):
        # Delay to allow simulation to settle before starting to monitor the VIP RX pin
        await Timer(1, unit="ns")
        while True:
            await self.serial_read_byte()

    async def sample_bit(self, start_bit=False) -> int:
        """Sample self.rx once during this bit period - at the exact center
        if self.uart_cfg.center_sample, otherwise at a random offset (simulating
        asynchronous sampling jitter), """

        if self.uart_cfg.center_sample:
            delay = self.bit_period // 2
        else:
            delay = random.randint(1, self.bit_period - 1)

        # Async sampling
        await Timer(delay, unit="ns")

        bit_value = int(self.rx.value)

        # logging
        delay_percent = (delay / self.bit_period) * 100
        self.logger.debug(f"Sampled {self.uart_cfg.vip_rx}: {bit_value} at {delay_percent:.2f}% of a bit period.")

        # wait till the end of the bit period
        await Timer(self.bit_period - delay, unit="ns")

        return bit_value

    async def serial_read_byte(self):
        """Blackbox-decode one UART frame directly off the rx pin, matching
        uart_tx.sv's own frame shape (start bit, 8 data bits LSB-first, stop
        bit - no parity)."""

        while self.rx.value != UART_START:
            await FallingEdge(self.rx)
            self.logger.debug("START bit detected")
        
        # Sample the start bit
        start_bit = await self.sample_bit()

        # Sample the 8 data bits
        data = 0
        for bit_index in range(8):
            data_bit = await self.sample_bit()
            data |= data_bit << bit_index
        
        # Sample the stop bit
        stop_bit = await self.sample_bit()

        if start_bit != UART_START:
            self.frame_errors += 1
            self.logger.warning("UART frame error: start bit was not 0")
            return

        if stop_bit != UART_IDLE:
            self.frame_errors += 1
            self.logger.warning("UART frame error: stop bit was not 1")
            return

        self.received_bytes.append(data)
        self.logger.info(f"UART byte received: 0x{data:02x}")
        self.ap.write(UartItem("uart_mon_item", data=data))
