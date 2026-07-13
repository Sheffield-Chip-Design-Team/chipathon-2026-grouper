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
        self.uart_cfg = ConfigDB().get(None, "", "UART_CFG")

        self.rx = self.uart_cfg.resolve_handle(self.dut, self.uart_cfg.rx_pin)

        self.logger.info(f"UartMonitor sampling DUT rx pin: {self.uart_cfg.rx_pin}")

    async def run_phase(self):
        while True:
            await self.serial_read_byte()

    async def sample_bit(self) -> int:
        """Sample self.rx once during this bit period - at the exact center
        if self.uart_cfg.center_sample, otherwise at a random offset (simulating
        asynchronous sampling jitter), matching
        hw/dv/uvc/template/UART.py's random_sample()."""
        bit_period = self.uart_cfg.bit_period_ns
        if self.uart_cfg.center_sample:
            delay = bit_period // 2
        else:
            delay = random.randint(1, bit_period - 1)
        await Timer(delay, unit="ns")
        bit_value = int(self.rx.value)
        self.logger.debug(f"Sampled rx pin: {bit_value} after delay {delay} ns")
        await Timer(bit_period - delay, unit="ns")
        return bit_value

    async def serial_read_byte(self):
        """Blackbox-decode one UART frame directly off the rx pin, matching
        uart_rx.sv's own frame shape (start bit, 8 data bits LSB-first, stop
        bit - no parity)."""
        while self.rx.value == UART_IDLE:
            await FallingEdge(self.rx)
        self.logger.debug("start bit detected")

        start_bit = await self.sample_bit()

        byte_value = 0
        for bit_index in range(8):
            data_bit = await self.sample_bit()
            self.logger.debug(f"sampled data bit {bit_index}: {data_bit}")
            byte_value |= data_bit << bit_index

        stop_bit = await self.sample_bit()

        if start_bit != UART_START:
            self.frame_errors += 1
            self.logger.warning("UART frame error: start bit was not 0")
            return
            
        if stop_bit != UART_IDLE:
            self.frame_errors += 1
            self.logger.warning("UART frame error: stop bit was not 1")
            return

        self.received_bytes.append(byte_value)
        self.logger.info(f"UART byte received: 0x{byte_value:02x}")
        self.ap.write(UartItem("uart_mon_item", byte_value=byte_value))
