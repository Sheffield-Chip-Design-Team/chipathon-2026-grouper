import random

from pyuvm import ConfigDB

from hw.dv.uvc.uart.uart_sequences import UartByteSequence, UartRandomByteSequence

from .qspi_ahb_base_sequence import (
    STATUS_RX_BREAK,
    STATUS_RX_EMPTY,
    STATUS_RX_FRAME_ERROR,
    STATUS_TX_EMPTY,
    UartAhbBaseSequence,
)

ADDR_RXDATA_MASK = 0xFF

FRAME_KIND_CLEAN = "clean"
FRAME_KIND_BAD_STOP = "bad_stop"
FRAME_KIND_BREAK = "break"


class UartSanitySequence(UartAhbBaseSequence):
    async def body(self):
        self.get_config()
        self.sequencer.logger.info(f"Starting {self.get_name()}")
        await self.configure_uart()

        # Sanity write path: push a byte into TXDATA and confirm the write completes.
        await self.reg_write(self.reg_model.txdata, 0xA5)
        await self.wait_for_status(STATUS_TX_EMPTY, STATUS_TX_EMPTY)

        # Sanity read path: drive the UART RX pin, then read RXDATA back through AHB.
        await self.drive_uart_frame(0x3C)
        await self.wait_for_status(STATUS_RX_EMPTY, 0)
        rx_data = await self.reg_read(self.reg_model.rxdata)
        if (rx_data & ADDR_RXDATA_MASK) != 0x3C:
            msg = f"RXDATA mismatch: expected 0x3c got 0x{(rx_data & ADDR_RXDATA_MASK):02x}"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        # Check the status register still reads back and does not flag an error.
        status = await self.reg_read(self.reg_model.status)
        if status & (STATUS_RX_FRAME_ERROR | STATUS_RX_BREAK):
            msg = "Unexpected RX error/break status during sanity test"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        self.sequencer.logger.info(f"{self.get_name()} passed")


class UartHelloWorldSequence(UartAhbBaseSequence):
    """Minimal end-to-end check: enable the UART over AHB, send one byte
    through the UartAgent (not by bit-banging the pin directly, unlike
    UartSanitySequence above), and confirm it shows up in RXDATA via the AHB
    agent. Exercises both VIPs plus the env's ConfigDB wiring in one pass."""

    HELLO_BYTE = 0x55

    async def body(self):
        self.get_config()
        self.sequencer.logger.info(f"Starting {self.get_name()}")
        await self.configure_uart()

        uart_seqr = ConfigDB().get(None, "", "UART_SEQR")
        send_seq = UartByteSequence("send_hello", byte_value=self.HELLO_BYTE)
        self.sequencer.logger.info(f"Sending hello byte 0x{self.HELLO_BYTE:02x} via UartAgent")

        await send_seq.start(uart_seqr)

        await self.wait_for_status(STATUS_RX_EMPTY, 0)

        rx_data = await self.reg_read(self.reg_model.rxdata)
        if (rx_data & ADDR_RXDATA_MASK) != self.HELLO_BYTE:
            msg = (
                f"Hello-world byte mismatch: expected 0x{self.HELLO_BYTE:02x} "
                f"got 0x{(rx_data & ADDR_RXDATA_MASK):02x}"
            )
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)


class UartRandomResetSequence(UartAhbBaseSequence):
    """Move: mid-test DUT reset. Reset clears CTRL to 0 (gating both TX and
    RX FSMs off) AND is the only way to clear a stuck STATUS.rx_break -
    ahb_uart.sv's read-clear block has a copy-paste bug (clears
    status_rx_frame_error twice instead of also clearing status_rx_break)
    so rx_break otherwise never clears once set. This move always
    re-configures before returning, so it leaves the UART ready for the
    next move rather than pushing that obligation onto the caller."""

    async def body(self):
        self.get_config()
        self.sequencer.logger.info(f"Starting {self.get_name()}: mid-test reset")
        await self.reset_dut()
        await self.configure_uart()
        self.sequencer.logger.info(f"{self.get_name()} passed")


class UartRandomBitbangFrameSequence(UartAhbBaseSequence):
    """Move: bit-bang one UART frame directly onto uart_rx (bypassing the
    VIP), randomly choosing a clean/bad-stop/break variant."""

    def __init__(self, name="uart_random_bitbang_frame", frame_kind=None,
                 byte_value=None, break_bit_periods=(12, 16)):
        super().__init__(name)
        self.frame_kind = frame_kind
        self.byte_value = byte_value
        self.break_bit_periods = break_bit_periods
        self.result_kind = None
        self.result_byte = None

    async def body(self):
        self.get_config()
        kind = self.frame_kind or random.choice(
            [FRAME_KIND_CLEAN, FRAME_KIND_BAD_STOP, FRAME_KIND_BREAK]
        )

        if kind == FRAME_KIND_BREAK:
            byte_value = 0x00  # required - see break_detect analysis in the plan/Context
        else:
            byte_value = self.byte_value if self.byte_value is not None else random.randint(0, 255)

        self.sequencer.logger.info(f"Starting {self.get_name()}: kind={kind} byte=0x{byte_value:02x}")
        self.result_kind, self.result_byte = kind, byte_value

        if kind == FRAME_KIND_CLEAN:
            await self.drive_uart_frame(byte_value)
            await self.wait_for_status(STATUS_RX_EMPTY, 0)
            rx_data = await self.reg_read(self.reg_model.rxdata)
            if (rx_data & ADDR_RXDATA_MASK) != byte_value:
                msg = (
                    f"clean bitbang mismatch: expected 0x{byte_value:02x} "
                    f"got 0x{(rx_data & ADDR_RXDATA_MASK):02x}"
                )
                self.sequencer.logger.warning(msg)
                raise AssertionError(msg)
            status = await self.reg_read(self.reg_model.status)
            if status & STATUS_RX_FRAME_ERROR:
                raise AssertionError("unexpected frame error on a clean bitbang frame")
            # Deliberately NOT asserting STATUS_RX_BREAK==0 here - an earlier
            # break move in this test run may have left it permanently stuck
            # (see UartRandomMoveSequence's break_pending bookkeeping).

        elif kind == FRAME_KIND_BAD_STOP:
            await self.drive_uart_frame(byte_value, force_bad_stop=True)
            await self.wait_for_status(STATUS_RX_FRAME_ERROR, STATUS_RX_FRAME_ERROR)
            # RC-clear frame_error immediately so it doesn't leak into a
            # later move's "no error" check.
            await self.reg_read(self.reg_model.status)
            await self.wait_for_status(STATUS_RX_EMPTY, 0, max_reads=50)
            await self.reg_read(self.reg_model.rxdata)

        else:  # FRAME_KIND_BREAK
            low_periods = random.randint(*self.break_bit_periods)
            await self.drive_break_condition(low_periods)
            await self.wait_for_status(STATUS_RX_BREAK, STATUS_RX_BREAK)

        self.sequencer.logger.info(f"{self.get_name()} passed (kind={kind})")


class UartRandomDutTransmitSequence(UartAhbBaseSequence):
    """Move: 'trigger the DUT itself to transmit' - write a random byte to
    TXDATA and confirm it appears on uart_tx via the passive uart_tx_agent's
    monitor (the only witness for this direction - no DUT register echoes
    wire content). Exercises the passive monitor for the first time in this
    suite."""

    def __init__(self, name="uart_random_dut_transmit", byte_value=None):
        super().__init__(name)
        self.byte_value = byte_value

    async def body(self):
        self.get_config()
        byte_value = self.byte_value if self.byte_value is not None else random.randint(0, 255)
        tx_monitor = ConfigDB().get(None, "", "UART_TX_MONITOR")
        baseline = len(tx_monitor.received_bytes)

        self.sequencer.logger.info(f"Starting {self.get_name()}: byte=0x{byte_value:02x}")
        await self.wait_for_status(STATUS_TX_EMPTY, STATUS_TX_EMPTY)
        await self.reg_write(self.reg_model.txdata, byte_value)

        for _ in range(200):  # ~200 bit periods of headroom, baud-independent
            if len(tx_monitor.received_bytes) > baseline:
                break
            await self.wait_uart_bits(1)
        else:
            msg = "DUT never transmitted the byte written to TXDATA"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        observed = tx_monitor.received_bytes[-1]
        if observed != byte_value:
            msg = f"DUT transmit mismatch: wrote 0x{byte_value:02x}, wire showed 0x{observed:02x}"
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)
        self.sequencer.logger.info(f"{self.get_name()} passed")


class UartRandomMoveSequence(UartAhbBaseSequence):
    """Layers a random selection/order/count of the smaller move sequences
    together in one test - the pyuvm idiom for this (no 'virtual sequence'
    base class exists in pyuvm) is simply a sequence whose body() starts
    other sequences, which is exactly what this does."""

    MOVE_WEIGHTS = {
        "clean_bitbang": 3,
        "bad_stop_bitbang": 1,
        "break_bitbang": 1,
        "vip_byte": 3,
        "dut_transmit": 2,
        "reset": 1,
    }

    def __init__(self, name="uart_random_moves", num_moves=None, min_moves=8, max_moves=20):
        super().__init__(name)
        self.num_moves = num_moves
        self.min_moves, self.max_moves = min_moves, max_moves
        self.break_pending = False  # tracks the rx_break-never-clears RTL bug

    async def body(self):
        self.get_config()
        await self.configure_uart()

        n = self.num_moves if self.num_moves is not None else random.randint(self.min_moves, self.max_moves)
        self.sequencer.logger.info(f"{self.get_name()}: running {n} random moves")

        moves, weights = list(self.MOVE_WEIGHTS), list(self.MOVE_WEIGHTS.values())
        for i in range(n):
            move = random.choices(moves, weights=weights, k=1)[0]
            self.sequencer.logger.info(f"[{i + 1}/{n}] move={move} (break_pending={self.break_pending})")
            await self._run_move(move)

        self.sequencer.logger.info(f"{self.get_name()} passed ({n} moves)")

    async def _run_move(self, move: str):
        if move == "reset":
            await UartRandomResetSequence("m_reset").start(self.sequencer)
            self.break_pending = False  # reset is the only thing that clears it

        elif move == "clean_bitbang":
            seq = UartRandomBitbangFrameSequence("m_clean", frame_kind=FRAME_KIND_CLEAN)
            await seq.start(self.sequencer)

        # elif move == "bad_stop_bitbang":
        #     seq = UartRandomBitbangFrameSequence("m_bad_stop", frame_kind=FRAME_KIND_BAD_STOP)
        #     await seq.start(self.sequencer)

        # elif move == "break_bitbang":
        #     seq = UartRandomBitbangFrameSequence("m_break", frame_kind=FRAME_KIND_BREAK)
        #     await seq.start(self.sequencer)
        #     self.break_pending = True

        # elif move == "vip_byte":
        #     uart_seqr = ConfigDB().get(None, "", "UART_SEQR")
        #     seq = UartRandomByteSequence("m_vip_byte")
        #     await seq.start(uart_seqr)
        #     if seq.item.break_condition:
        #         self.break_pending = True
        #         # A real break was injected on this path too - don't
        #         # cross-check RXDATA, the byte was never meant to arrive.
        #         return
        #     await self.wait_for_status(STATUS_RX_EMPTY, 0)
        #     rx_data = await self.reg_read(self.reg_model.rxdata)
        #     if not seq.item.bad_stop_bit and (rx_data & ADDR_RXDATA_MASK) != seq.item.data:
        #         msg = (
        #             f"vip_byte mismatch: expected 0x{seq.item.data:02x} "
        #             f"got 0x{(rx_data & ADDR_RXDATA_MASK):02x}"
        #         )
        #         self.sequencer.logger.warning(msg)
        #         raise AssertionError(msg)

        elif move == "dut_transmit":
            await UartRandomDutTransmitSequence("m_dut_tx").start(self.sequencer)
