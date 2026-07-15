 # SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
import random
import cocotb
import logging
from vip.common.VIP import VIP_Base
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer, FallingEdge
from cocotb.utils import get_sim_time


class UartVIP(VIP_Base):

    def __init__(self, dut, is_active=False, dut_rx_pin="", dut_tx_pin=""):
        super().__init__()

        # UART parameters
        self.baud_rate = 9600  # Baud rate (Bits transferred per second)
        self.data_bits = 8  # Number of data bits
        self.has_parity = True  # Enable parity bit
        self.bit_period = (1_000_000_000) // self.baud_rate  # (bit period in ns)
        self.is_active = is_active  # Passive or active VIP

        print(f"bit period: {self.bit_period} ns")

        # Connect to DUT pins
        self.rx = self.resolve_handle(dut, dut_tx_pin)

        if self.is_active:
            self.tx = self.resolve_handle(dut, dut_rx_pin)
            self.tx.value = 1  # Idle state
            self.log.info(f"UART VIP in ACTIVE mode, driving RX pin: {dut_rx_pin}")

        # Log Setup
        self.log = logging.getLogger(f"cocotb.tb.UartVIP[{self.id}]")
        self.log.setLevel("INFO")

    async def serial_write_byte(self, data):
        """Drive the RX pin with a UART frame"""

        if self.is_active:
            delay_time = random.randint(
                0, self.bit_period
            )  # Random delay before sending
            await Timer(delay_time, unit="ns")

            # Start bit
            self.tx.value = 0
            await Timer(self.bit_period, unit="ns")

            # Data bits
            for i in range(self.data_bits):
                self.tx.value = (data >> i) & 0x1
                await Timer(self.bit_period, unit="ns")

            # Parity bit
            if self.has_parity:
                parity_bit = 0
                for i in range(self.data_bits):
                    parity_bit ^= (data >> i) & 0x1
                self.tx.value = parity_bit
                await Timer(self.bit_period, unit="ns")

            # Stop bit
            self.tx.value = 1
            await Timer(self.bit_period, unit="ns")

        else:
            self.log.warning(f"{self.id} is passive, cannot drive RX pin.")

    async def random_sample(self, center_mode=False) -> int:
        """Introduce a random delay to simulate asynchronous sampling"""
        delay = random.randint(1, self.bit_period - 1)

        if center_mode:
            delay = self.bit_period // 2
        await Timer(delay, unit="ns")

        rx = int(self.rx.value)
        self.log.debug(f"Sampled RX pin: {rx} after delay {delay} ns")

        await Timer(self.bit_period - delay, unit="ns")
        return rx

    async def serial_read_byte(self):
        """monitor the VIP RX pin pin"""

        # Wait for start bit
        while self.rx.value == 1:
            await FallingEdge(self.rx)  # Polling interval
            self.log.debug("start bit detected")

        start_bit = await self.random_sample(center_mode=True)

        # Data bits
        received_data = 0
        for i in range(self.data_bits):
            data_bit = await self.random_sample(center_mode=True)
            self.log.debug(f"sampled data bit {i} : {data_bit}")
            received_data |= data_bit << i

        # Parity bit
        parity_bit = 0
        if self.has_parity:
            parity_bit = await self.random_sample(center_mode=True)
            self.log.debug(f"sampled parity bit {i} : {parity_bit}")

        # Stop bit
        stop_bit = await self.random_sample(center_mode=True)
        self.log.debug(f"sampled stop bit {i} : {stop_bit}")

        self.log.info(f"Received start bit: 0x{start_bit:01b}")
        self.log.info(f"Received data: 0x{received_data:02X}")
        self.log.info(f"Received parity bit: 0x{parity_bit:02X}")
        self.log.info(f"Received stop bit: 0x{stop_bit:01b}")

        return Uart_Transaction(
            data=received_data, calc_parity=False, parity_bit=parity_bit
        )


class Uart_Transaction:

    def __init__(
        self,
        start_bit=0,
        data=0x00,
        has_parity=True,
        calc_parity=True,
        parity_bit=0,
        parity_type="odd",
        good_parity=True,
        stop_bit=1,
    ):

        self.start_bit = start_bit
        self.data = data
        self.has_parity = has_parity
        self.parity_type = "odd"
        self.parity_bit = parity_bit

        if calc_parity and self.has_parity:
            if self.parity_type == "odd":
                self.parity_bit = 1 if (bin(self.data).count("1") % 2 == 0) else 0
            else:
                self.parity_bit = 0 if (bin(self.data).count("1") % 2 == 0) else 1
            if not good_parity:
                self.parity_bit ^= 1  # Invert parity bit for bad parity

        self.stop_bit = stop_bit
        self.timestamp = get_sim_time(unit="ns")

    def __repr__(self):
        return f"<UART_TXN frame data =0x{self.data:02X} time={self.timestamp}>"
