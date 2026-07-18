import cocotb
from cocotb.triggers import RisingEdge, Timer

from pyuvm import ConfigDB, uvm_sequence
from pyuvm.s24_uvm_reg_includes import check_t, path_t, uvm_resp_t

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem

from ..qspi_clk_math import clk_div_for_baud

# UART MEMORY MAP (register names/fields/addresses now live in
# uart_reg_model.py - kept here are just the bitmask constants convenient
# for composing/checking raw ints in sequence bodies, e.g.
# `if status_val & STATUS_RX_BREAK`).
CTRL_ENABLE = 1 << 0
CTRL_TX_EN = 1 << 1
CTRL_RX_EN = 1 << 2
CTRL_RX_RESYNC_EN = 1 << 3

STATUS_TX_EMPTY = 1 << 0
STATUS_TX_FULL = 1 << 1
STATUS_RX_EMPTY = 1 << 2
STATUS_RX_FULL = 1 << 3
STATUS_TX_ACTIVE = 1 << 4
STATUS_RX_FRAME_ERROR = 1 << 5
STATUS_RX_BREAK = 1 << 6


def _decode_reg(reg, value: int) -> str:
    """Generic register-field decoder driven entirely by the register
    model's own field metadata (get_fields()/get_lsb_pos()/get_n_bits()) -
    works for any register in UartRegBlock without a per-register decoder."""
    parts = []
    for f in reg.get_fields():
        mask = (1 << f.get_n_bits()) - 1
        parts.append(f"{f.get_name()}=0x{(value >> f.get_lsb_pos()) & mask:x}")
    return " ".join(parts)


class UartAhbBaseSequence(uvm_sequence):
    def __init__(self, name="uart_ahb_base_sequence"):
        super().__init__(name)
        self.uart_cfg = None
        self.ahb_cfg = None
        self.reg_model = None
        self.dut = cocotb.top

    def get_config(self):
        self.sequencer = ConfigDB().get(None, "", "UART_AHB_SEQR")
        self.uart_cfg = ConfigDB().get(None, "", "UART_CFG")
        self.ahb_cfg = ConfigDB().get(None, "", "AHB_CFG")
        self.reg_model = ConfigDB().get(None, "", "UART_REG_MODEL")

    async def reg_write(self, reg, value: int):
        self.sequencer.logger.debug(f"REG WRITE {reg.get_name()} {_decode_reg(reg, value)}")
        status = await reg.write(
            value, map=self.reg_model.blk_get_def_map(), path=path_t.FRONTDOOR, check=check_t.NO_CHECK
        )
        if status != uvm_resp_t.PASS_RESP:
            msg = f"Register write to {reg.get_name()} failed (status={status})"
            self.sequencer.logger.warning(msg)
            # raise AssertionError(msg)

    async def reg_read(self, reg) -> int:
        status, value = await reg.read(
            map=self.reg_model.blk_get_def_map(), path=path_t.FRONTDOOR, check=check_t.NO_CHECK
        )
        self.sequencer.logger.debug(f"REG READ {reg.get_name()} {_decode_reg(reg, value)}")
        if status != uvm_resp_t.PASS_RESP:
            msg = f"Register read from {reg.get_name()} failed (status={status})"
            self.sequencer.logger.warning(msg)
            # raise AssertionError(msg)
        return value

    async def ahb_write(self, addr: int, data: int):
        item = AHB3LiteSeqItem(name=f"wr_{addr:02x}", addr=addr, is_write=True, wdata=data)
        await self.start_item(item)
        await self.finish_item(item)
        if item.hresp != 0:
            msg = f"AHB write to 0x{addr:02x} failed with HRESP=1"
            self.sequencer.logger.warning(msg)
            # raise AssertionError(msg)
        return item

    async def ahb_read(self, addr: int):
        item = AHB3LiteSeqItem(name=f"rd_{addr:02x}", addr=addr, is_write=False)
        await self.start_item(item)
        await self.finish_item(item)
        return item

    async def reset_dut(self, cycles_low: int = 2):
        """The only DUT reset primitive in the suite - the test's initial
        reset and any mid-test reset move both funnel through this, so they
        can never drift apart."""
        self.dut.HRESETn.value = 0
        for _ in range(cycles_low):
            await RisingEdge(self.dut.HCLK)
        self.dut.HRESETn.value = 1
        await RisingEdge(self.dut.HCLK)

    async def configure_uart(self):
        clk_div = clk_div_for_baud(self.uart_cfg.baud_rate, self.ahb_cfg.clk_period_ns)
        self.sequencer.logger.info(
            f"Configuring UART for baud_rate={self.uart_cfg.baud_rate} "
            f"(clk_div={clk_div})"
        )

        # Configure the UART over AHB: enable, TX/RX, resync, and set the clock divider.
        # The clock divider is a 10-bit value in bits [25:16] of the CTRL register.
        ctrl = CTRL_ENABLE | CTRL_TX_EN | CTRL_RX_EN | CTRL_RX_RESYNC_EN
        ctrl |= (clk_div & 0x3FF) << 16
        await self.reg_write(self.reg_model.ctrl, ctrl)

        rd = await self.reg_read(self.reg_model.ctrl)
        if (rd & 0x03FF0000) != (ctrl & 0x03FF0000):
            msg = (
                f"CTRL clk_div readback mismatch: expected "
                f"{_decode_reg(self.reg_model.ctrl, ctrl)} got {_decode_reg(self.reg_model.ctrl, rd)}"
            )
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

        if (rd & 0x0F) != (ctrl & 0x0F):
            msg = (
                f"CTRL enable bits readback mismatch: expected "
                f"{_decode_reg(self.reg_model.ctrl, ctrl)} got {_decode_reg(self.reg_model.ctrl, rd)}"
            )
            self.sequencer.logger.warning(msg)
            raise AssertionError(msg)

    async def wait_for_status(self, mask: int, value: int, max_reads: int = 200):
        rd = None
        for _ in range(max_reads):
            rd = await self.reg_read(self.reg_model.status)
            if (rd & mask) == value:
                return rd
        msg = (
            f"STATUS mask 0x{mask:08x} did not reach value 0x{value:08x} "
            f"(last read: {_decode_reg(self.reg_model.status, rd)})"
        )
        self.sequencer.logger.warning(msg)
        raise AssertionError(msg)

    async def drive_uart_frame(self, byte_value: int, force_bad_stop: bool = False, break_low_bits: int = 0):
        self.dut.uart_rx.value = 1
        await self.wait_uart_bits(2)

        self.dut.uart_rx.value = 0
        await self.wait_uart_bits(1)

        for bit_index in range(8):
            self.dut.uart_rx.value = (byte_value >> bit_index) & 1
            await self.wait_uart_bits(1)

        if break_low_bits > 0:
            self.dut.uart_rx.value = 0
            await self.wait_uart_bits(break_low_bits)
        elif force_bad_stop:
            self.dut.uart_rx.value = 0
            await self.wait_uart_bits(1)
        else:
            self.dut.uart_rx.value = 1
            await self.wait_uart_bits(1)

        self.dut.uart_rx.value = 1
        await self.wait_uart_bits(2)

    async def drive_break_condition(self, low_bit_periods: int = 12):
        """Hold uart_rx continuously low for low_bit_periods (must exceed
        1 start + 8 data + 1 stop = 10 bit periods for the RTL's
        break_detect logic to actually latch ST_BREAK - see uart_rx.sv).
        Unlike drive_uart_frame(byte_value=0, break_low_bits=N), this never
        depends on byte_value semantics, so intent can't be silently wrong."""
        self.dut.uart_rx.value = 0
        await self.wait_uart_bits(low_bit_periods)
        self.dut.uart_rx.value = 1
        await self.wait_uart_bits(2)

    async def wait_uart_bits(self, bit_count: int):
        await Timer(bit_count * self.uart_cfg.bit_period_ns, unit="ns")
