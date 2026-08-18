import cocotb
from cocotb.triggers import RisingEdge, Timer

from pyuvm import ConfigDB, uvm_sequence
from pyuvm.s24_uvm_reg_includes import check_t, path_t, uvm_resp_t

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem

from ..reg_model.uart_reg_consts import (
    CTRL_CLK_DIV_FIELD,
    CTRL_CLK_DIV_LSB,
    CTRL_CLK_DIV_MASK,
    CTRL_EN_FIELDS,
)
from ..reg_model.uart_reg_model import decode_reg as _decode_reg
from ..uart_clk_math import clk_div_for_baud

# Register addresses, field positions and bitmasks all live in
# reg_model/uart_reg_consts.py - import what a sequence body needs from there
# (e.g. `if status_val & STATUS_RX_BREAK`) rather than redefining it here.


class UartAhbBaseSequence(uvm_sequence):
    def __init__(self, name="uart_ahb_base_sequence"):
        super().__init__(name)
        self.uart_cfg = None
        self.ahb_cfg = None
        self.reg_model = None
        self.dut = cocotb.top

    def get_config(self):
        # TODO - add the concept of a virtual sequencer that can send UART OR AHB items
        self.vseqr      = ConfigDB().get(None, "", "AHB_UART_VSEQR")
        self.uart_cfg  = ConfigDB().get(None, "", "UART_CFG")
        self.ahb_cfg   = ConfigDB().get(None, "", "AHB_CFG")
        self.reg_model = ConfigDB().get(None, "", "UART_REG_MODEL")

    async def reg_write(self, reg, value: int):
      
        self.vseqr.logger.debug(f"REG WRITE {reg.get_name()} {_decode_reg(reg, value)}")
        status = await reg.write(
            value, map=self.reg_model.blk_get_def_map(), path=path_t.FRONTDOOR, check=check_t.CHECK
        )

        if status != uvm_resp_t.PASS_RESP:
            msg = f"Register write to {reg.get_name()} failed (status={status})"
            self.vseqr.logger.warning(msg)
            # raise AssertionError(msg)

    async def reg_read(self, reg) -> int:
        # check_t.CHECK is what enables UartRegPredictor's readback comparison
        # against the mirror - it is the only argument pyuvm forwards to the
        # predictor, and does nothing at all on its own.
        status, value = await reg.read(
            map=self.reg_model.blk_get_def_map(), path=path_t.FRONTDOOR, check=check_t.CHECK
        )
        self.vseqr.logger.debug(f"REG READ {reg.get_name()} {_decode_reg(reg, value)}")
        if status != uvm_resp_t.PASS_RESP:
            msg = f"Register read from {reg.get_name()} failed (status={status})"
            self.vseqr.logger.warning(msg)
            # raise AssertionError(msg)
        return value

    ## FIXME - these should be inside the AHB UVC
    async def ahb_write(self, addr: int, data: int):
        item = AHB3LiteSeqItem(name=f"wr_{addr:02x}", addr=addr, is_write=True, wdata=data)
        await self.start_item(item)
        await self.finish_item(item)
        if item.hresp != 0:
            msg = f"AHB write to 0x{addr:02x} failed with HRESP=1"
            self.vseqr.logger.warning(msg)
            # raise AssertionError(msg)
        return item

    async def ahb_read(self, addr: int):
        item = AHB3LiteSeqItem(name=f"rd_{addr:02x}", addr=addr, is_write=False)
        await self.start_item(item)
        await self.finish_item(item)
        return item

    # --------------------------------------------------------------------

    async def reset_dut(self, cycles_low: int = 2):
        """The only DUT reset primitive in the suite - the test's initial
        reset and any mid-test reset move both funnel through this, so they
        can never drift apart."""
        self.dut.HRESETn.value = 0
        for _ in range(cycles_low):
            await RisingEdge(self.dut.HCLK)
        self.dut.HRESETn.value = 1
        await RisingEdge(self.dut.HCLK)

        # The RTL registers are back at their reset values, so the mirrors have
        # to follow or the next checked read compares against a value the DUT
        # no longer holds. (get_config() may not have run on this instance -
        # reset_dut() is called standalone for the initial reset in
        # UartTestBase.run_phase.)
        if self.reg_model is not None:
            self.reg_model.reset()

    async def configure_uart(self):
        clk_div = clk_div_for_baud(self.uart_cfg.baud_rate, self.ahb_cfg.clk_period_ns)
       
        self.vseqr.logger.info(
            f"Configuring UART for baud_rate={self.uart_cfg.baud_rate} "
            f"(clk_div={clk_div})"
        )

        # FIXME - use pyuvm SET functions from the register model and then write?
        # FIXME - check if there is a set_check on read (backdoor)

        # Configure the UART over AHB: enable, TX/RX, resync, and set the clock divider.
        # The clock divider is a 10-bit value in bits [25:16] of the CTRL register.
        ctrl = CTRL_EN_FIELDS
        ctrl |= (clk_div & CTRL_CLK_DIV_MASK) << CTRL_CLK_DIV_LSB

        await self.reg_write(self.reg_model.ctrl, ctrl)

        rd = await self.reg_read(self.reg_model.ctrl)
        if (rd & CTRL_CLK_DIV_FIELD) != (ctrl & CTRL_CLK_DIV_FIELD):
            msg = (
                f"CTRL clk_div readback mismatch: expected "
                f"{_decode_reg(self.reg_model.ctrl, ctrl)} got {_decode_reg(self.reg_model.ctrl, rd)}"
            )
            self.vseqr.logger.warning(msg)
            raise AssertionError(msg)

        if (rd & CTRL_EN_FIELDS) != (ctrl & CTRL_EN_FIELDS):
            msg = (
                f"CTRL enable bits readback mismatch: expected "
                f"{_decode_reg(self.reg_model.ctrl, ctrl)} got {_decode_reg(self.reg_model.ctrl, rd)}"
            )
            self.vseqr.logger.warning(msg)
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
        self.vseqr.logger.warning(msg)
        raise AssertionError(msg)

    # FIXME - this should be handled from the UART driver
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
