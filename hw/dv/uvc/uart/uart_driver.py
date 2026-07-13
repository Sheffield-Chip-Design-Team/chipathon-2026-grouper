import cocotb
from cocotb.triggers import Timer

from pyuvm import ConfigDB, uvm_analysis_port, uvm_driver

UART_IDLE = 1
UART_START = 0

class UartDriver(uvm_driver):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self.uart_cfg = ConfigDB().get(None, "", "UART_CFG")
        self.tx = self.uart_cfg.resolve_handle(self.dut, self.uart_cfg.tx_pin)
        self.logger.info(f"UartDriver driving DUT tx pin: {self.uart_cfg.tx_pin}")

    async def run_phase(self):
        await self.drive_idle(1)
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.drive_frame(item)
            self.ap.write(item)
            self.seq_item_port.item_done()

    async def drive_frame(self, item):
        await self.drive_idle(item.idle_bits)
        await self.drive_start_bit()
        for bit_index in range(8):
            await self.drive_data_bit((item.byte_value >> bit_index) & 1)
        if item.break_condition:
            self.logger.debug("Driving break condition instead of stop bits")
            await self.drive_break(item.post_bits)
        elif item.bad_stop_bit:
            self.logger.debug("Driving bad stop bit")
            await self.drive_data_bit(UART_START)
            await self.drive_idle(item.post_bits)
        else:
            await self.drive_stop_bits(item.stop_bits)
            await self.drive_idle(item.post_bits)
        self.logger.info(f"Driving UART frame: byte=0x{item.byte_value:02x}")

    async def drive_idle(self, bit_count: int):
        self.tx.value = UART_IDLE
        await self.drive_bit_time(bit_count)

    async def drive_start_bit(self):
        self.tx.value = UART_START
        await self.drive_bit_time(1)

    async def drive_data_bit(self, bit_value: int):
        self.tx.value = int(bit_value)
        await self.drive_bit_time(1)

    async def drive_stop_bits(self, bit_count: int):
        self.tx.value = UART_IDLE
        await self.drive_bit_time(bit_count)

    async def drive_break(self, bit_count: int):
        self.tx.value = UART_START
        await self.drive_bit_time(bit_count)

    async def drive_bit_time(self, bit_count: int):
        await Timer(bit_count * self.uart_cfg.bit_period_ns, unit="ns")
