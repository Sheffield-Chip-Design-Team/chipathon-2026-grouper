import random

import cocotb
from cocotb.triggers import Timer

from pyuvm import ConfigDB, uvm_analysis_port, uvm_driver

UART_IDLE = 1
UART_START = 0

class UartDriver(uvm_driver):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        self.dut        = cocotb.top
        self.uart_cfg   = ConfigDB().get(self, "", "UART_CFG")
        self.bit_period = self.uart_cfg.bit_period_ns
        self.tx         = self.uart_cfg.resolve_handle(self.dut, self.uart_cfg.vip_tx)

        self.logger.info(f"Driving DUT pin: {self.uart_cfg.vip_tx}")
        self.tx.value = UART_IDLE

    async def run_phase(self):
        # Connection to the sequencer is already established by pyuvm's uvm_driver base class.
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.drive_frame(item)
            self.ap.write(item)
            self.seq_item_port.item_done()

    async def drive_frame(self, item):
        # Random delay before sending
        delay_time = random.randint(
            0, self.bit_period
        )  
        await Timer(delay_time, unit="ns")

        # Start bit
        self.tx.value = UART_START
        await Timer(self.bit_period, unit="ns")

        # Data bits
        for bit_index in range(8):
            self.tx.value = (item.data >> bit_index) & 0x1
            await Timer(self.bit_period, unit="ns")

        #  Break Condition
        if item.break_condition:
            self.logger.debug("Driving break condition instead of stop bits")
             # Random delay for break condition duration
            break_delay_time = random.randint(self.bit_period, self.bit_period*3)
            await Timer(break_delay_time, unit="ns")

        # Stop bits
        elif item.bad_stop_bit:
            self.logger.debug("Driving bad stop bit")
            self.tx.value = UART_START
        else:
            for n in range(item.stop_bits):
                self.tx.value = UART_IDLE
                await Timer(self.bit_period, unit="ns")
          
        await Timer(self.bit_period, unit="ns")

        self.logger.info(f"Driven UART frame: byte=0x{item.data:02x}")
        self.tx.value = UART_IDLE

