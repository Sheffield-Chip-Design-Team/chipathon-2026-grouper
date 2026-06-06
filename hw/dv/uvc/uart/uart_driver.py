import cocotb
from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB, uvm_analysis_port, uvm_driver

UART_IDLE = 1
UART_START = 0

class UartRxDriver(uvm_driver):
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self.cfg = ConfigDB().get(None, "", "UART_RX_CFG")

    async def run_phase(self):
        await self.reset_dut()
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.drive_frame(item)
            self.ap.write(item)
            self.seq_item_port.item_done()

    async def reset_dut(self):
        self.dut.rst_n.value = 0
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rst_n.value = 1
        await RisingEdge(self.dut.clk)

    async def drive_frame(self, item):
        await self.drive_idle(item.idle_bits)
        await self.drive_start_bit()
        for bit_index in range(8):
            await self.drive_data_bit((item.byte_value >> bit_index) & 1)
        if item.break_condition:
            await self.drive_break(item.post_bits)
        elif item.bad_stop_bit:
            await self.drive_data_bit(UART_START)
            await self.drive_idle(item.post_bits)
        else:
            await self.drive_stop_bits(item.stop_bits)
            await self.drive_idle(item.post_bits)

    async def drive_idle(self, bit_count: int):
        self.dut.uart_rx.value = UART_IDLE
        await self.drive_bit_time(bit_count)

    async def drive_start_bit(self):
        self.dut.uart_rx.value = UART_START
        await self.drive_bit_time(1)

    async def drive_data_bit(self, bit_value: int):
        self.dut.uart_rx.value = int(bit_value)
        await self.drive_bit_time(1)

    async def drive_stop_bits(self, bit_count: int):
        self.dut.uart_rx.value = UART_IDLE
        await self.drive_bit_time(bit_count)

    async def drive_break(self, bit_count: int):
        self.dut.uart_rx.value = UART_START
        await self.drive_bit_time(bit_count)

    async def drive_bit_time(self, bit_count: int):
        for _ in range(bit_count * self.cfg.oversample):
            await RisingEdge(self.dut.clk)
