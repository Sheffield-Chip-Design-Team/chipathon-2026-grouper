from pyuvm import uvm_reg, uvm_reg_adapter, uvm_reg_block, uvm_reg_field
from pyuvm.s24_uvm_reg_includes import access_e, check_t, uvm_resp_t

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem

from .uart_reg_consts import (
    ADDR_CTRL,
    ADDR_RXDATA,
    ADDR_STATUS,
    ADDR_TXDATA,
    CTRL_CLK_DIV_BITS,
    CTRL_CLK_DIV_LSB,
    CTRL_ENABLE_LSB,
    CTRL_FLUSH_RX_FIFO_LSB,
    CTRL_FLUSH_TX_FIFO_LSB,
    CTRL_RESET_CLK_DIV,
    CTRL_RESET_RX_RESYNC_EN,
    CTRL_RX_EN_LSB,
    CTRL_RX_RESYNC_EN_LSB,
    CTRL_TX_BREAK_LSB,
    CTRL_TX_EN_LSB,
    STATUS_RESET_RX_EMPTY,
    STATUS_RESET_TX_EMPTY,
    STATUS_RX_BREAK_LSB,
    STATUS_RX_EMPTY_LSB,
    STATUS_RX_FRAME_ERROR_LSB,
    STATUS_RX_FULL_LSB,
    STATUS_TX_ACTIVE_LSB,
    STATUS_TX_EMPTY_LSB,
    STATUS_TX_FULL_LSB,
    UART_DATA_BITS,
)


def field_value(reg, field_name: str, value: int) -> int:
    """Slice one named field out of a raw register value using the register
    model's own metadata - so bit positions live in exactly one place (here)
    rather than being re-hardcoded by every consumer."""
    for f in reg.get_fields():
        if f.get_name() == field_name:
            return (value >> f.get_lsb_pos()) & ((1 << f.get_n_bits()) - 1)
    raise KeyError(f"{reg.get_name()} has no field '{field_name}'")


def decode_reg(reg, value: int) -> str:
    """Generic register-field decoder driven entirely by the register
    model's own field metadata (get_fields()/get_lsb_pos()/get_n_bits()) -
    works for any register in UartRegBlock without a per-register decoder."""
    parts = []
    for f in reg.get_fields():
        mask = (1 << f.get_n_bits()) - 1
        parts.append(f"{f.get_name()}=0x{(value >> f.get_lsb_pos()) & mask:x}")
    return " ".join(parts)


class CtrlReg(uvm_reg):
    def __init__(self, name="ctrl"):
        super().__init__(name, reg_width=32)

    def build(self):
        # Bit positions and reset values come from uart_reg_consts.py, which
        # mirrors ahb_uart.sv's own reset block (~line 199) - not all of them
        # are zero, and with check-on-read enabled a wrong reset value here
        # becomes a false failure on the first read after a reset.
        self.enable = uvm_reg_field("enable")
        self.enable.configure(self, size=1, lsb_pos=CTRL_ENABLE_LSB, access="RW",
                              is_volatile=False, reset=0)
        self.tx_en = uvm_reg_field("tx_en")
        self.tx_en.configure(self, size=1, lsb_pos=CTRL_TX_EN_LSB, access="RW",
                             is_volatile=False, reset=0)
        self.rx_en = uvm_reg_field("rx_en")
        self.rx_en.configure(self, size=1, lsb_pos=CTRL_RX_EN_LSB, access="RW",
                             is_volatile=False, reset=0)
        self.rx_resync_en = uvm_reg_field("rx_resync_en")
        self.rx_resync_en.configure(self, size=1, lsb_pos=CTRL_RX_RESYNC_EN_LSB, access="RW",
                                    is_volatile=False, reset=CTRL_RESET_RX_RESYNC_EN)
        self.tx_break = uvm_reg_field("tx_break")
        self.tx_break.configure(self, size=1, lsb_pos=CTRL_TX_BREAK_LSB, access="RW",
                                is_volatile=False, reset=0)
        # flush_tx_fifo/flush_rx_fifo are one-shot pulses in the RTL - the
        # model has no self-clearing-bit concept, so "WO" (write-only, model
        # never mirrors a meaningful value back) is the honest fit, not "RW".
        self.flush_tx_fifo = uvm_reg_field("flush_tx_fifo")
        self.flush_tx_fifo.configure(self, size=1, lsb_pos=CTRL_FLUSH_TX_FIFO_LSB, access="WO",
                                     is_volatile=False, reset=0)
        self.flush_rx_fifo = uvm_reg_field("flush_rx_fifo")
        self.flush_rx_fifo.configure(self, size=1, lsb_pos=CTRL_FLUSH_RX_FIFO_LSB, access="WO",
                                     is_volatile=False, reset=0)
        self.clk_div = uvm_reg_field("clk_div")
        self.clk_div.configure(self, size=CTRL_CLK_DIV_BITS, lsb_pos=CTRL_CLK_DIV_LSB, access="RW",
                               is_volatile=False, reset=CTRL_RESET_CLK_DIV)

        # Which fields participate in UartRegPredictor's check-on-read. The
        # flush bits are excluded because predict_write() leaves the written 1
        # in the mirror while the RTL's read mux hardwires bits [15:5] to zero
        # - checking them would fail on every CTRL read after a flush.
        for f in (self.enable, self.tx_en, self.rx_en, self.rx_resync_en,
                  self.tx_break, self.clk_div):
            f.set_compare(check_t.CHECK)
        for f in (self.flush_tx_fifo, self.flush_rx_fifo):
            f.set_compare(check_t.NO_CHECK)


class StatusReg(uvm_reg):
    def __init__(self, name="status"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.tx_empty = uvm_reg_field("tx_empty")
        self.tx_empty.configure(self, size=1, lsb_pos=STATUS_TX_EMPTY_LSB, access="RO",
                                is_volatile=True, reset=STATUS_RESET_TX_EMPTY)
        self.tx_full = uvm_reg_field("tx_full")
        self.tx_full.configure(self, size=1, lsb_pos=STATUS_TX_FULL_LSB, access="RO",
                               is_volatile=True, reset=0)
        self.rx_empty = uvm_reg_field("rx_empty")
        self.rx_empty.configure(self, size=1, lsb_pos=STATUS_RX_EMPTY_LSB, access="RO",
                                is_volatile=True, reset=STATUS_RESET_RX_EMPTY)
        self.rx_full = uvm_reg_field("rx_full")
        self.rx_full.configure(self, size=1, lsb_pos=STATUS_RX_FULL_LSB, access="RO",
                               is_volatile=True, reset=0)
        self.tx_active = uvm_reg_field("tx_active")
        self.tx_active.configure(self, size=1, lsb_pos=STATUS_TX_ACTIVE_LSB, access="RO",
                                 is_volatile=True, reset=0)
        self.rx_frame_error = uvm_reg_field("rx_frame_error")
        self.rx_frame_error.configure(self, size=1, lsb_pos=STATUS_RX_FRAME_ERROR_LSB, access="RC",
                                      is_volatile=True, reset=0)
        # Modeled RO, not RC: ahb_uart.sv's STATUS read-clear block has a
        # copy-paste bug and never actually clears this bit on a STATUS read
        # - only a full reset does. RC here would make the model predict a
        # clear that the real DUT doesn't perform.
        self.rx_break = uvm_reg_field("rx_break")
        self.rx_break.configure(self, size=1, lsb_pos=STATUS_RX_BREAK_LSB, access="RO",
                                is_volatile=True, reset=0)

        # Every STATUS bit is driven by the DUT's own FIFOs/FSMs, so none of
        # them can be predicted from bus traffic alone - nothing here is
        # compared on read.
        for f in self.get_fields():
            f.set_compare(check_t.NO_CHECK)


class TxDataReg(uvm_reg):
    def __init__(self, name="txdata"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.data = uvm_reg_field("data")
        self.data.configure(self, size=UART_DATA_BITS, lsb_pos=0, access="WO",
                            is_volatile=False, reset=0)
        # Write-only: a read raises HRESP, so there is nothing to compare.
        self.data.set_compare(check_t.NO_CHECK)


class RxDataReg(uvm_reg):
    def __init__(self, name="rxdata"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.data = uvm_reg_field("data")
        self.data.configure(self, size=UART_DATA_BITS, lsb_pos=0, access="RO",
                            is_volatile=True, reset=0)
        # The RX FIFO's contents come off the wire, not off the bus - the
        # scoreboard checks this one against the monitored UART bytes.
        self.data.set_compare(check_t.NO_CHECK)


class UartRegBlock(uvm_reg_block):
    # Addresses must be pre-formatted exactly as Python's plain hex() would
    # render them (no zero-padding, lowercase) - uvm_reg_map.add_reg() keys
    # its internal dict via hex(int(address, 16) + offset), but uvm_reg.write
    # ()/read() look registers up via reg.get_address(), which returns this
    # raw string verbatim, never renormalized. A zero-padded/uppercase string
    # here (e.g. "0x00", "0x0C") won't string-match the map's canonical key
    # and write()/read() will raise KeyError. Hence hex() over the
    # uart_reg_consts.py ints rather than hand-written strings - it is the
    # canonical form by construction.
    def build(self):
        self.ctrl = CtrlReg()
        self.ctrl.configure(self, address=hex(ADDR_CTRL), hdl_path="")
        self.status = StatusReg()
        self.status.configure(self, address=hex(ADDR_STATUS), hdl_path="")
        self.txdata = TxDataReg()
        self.txdata.configure(self, address=hex(ADDR_TXDATA), hdl_path="")
        self.rxdata = RxDataReg()
        self.rxdata.configure(self, address=hex(ADDR_RXDATA), hdl_path="")

        # blk_create_map() returns None (see s18_uvm_reg_block.py) - it adds
        # the map as a side effect via blk_add_map(), which is where
        # self.def_map actually gets set (since it's the first/only map).
        self.blk_create_map("reg_map", base_addr=0)
        reg_map = self.blk_get_def_map()
        reg_map.add_reg(self.ctrl, offset="0x0", rights="RW")
        reg_map.add_reg(self.status, offset="0x0", rights="RO")
        reg_map.add_reg(self.txdata, offset="0x0", rights="WO")
        reg_map.add_reg(self.rxdata, offset="0x0", rights="RO")
        self.set_lock()

    def reset(self):
        """Return every mirror to its reset value. Must be called whenever the
        DUT is reset (UartAhbBaseSequence.reset_dut) - the RTL registers go
        back to their reset values, and a mirror that doesn't follow makes the
        next checked read fail against a value the DUT no longer holds."""
        for reg in self.blk_get_def_map().get_registers():
            reg.reset()


class Ahb3LiteRegAdapter(uvm_reg_adapter):
    """Frontdoor-only translation between a generic uvm_reg_bus_op and this
    repo's AHB3LiteSeqItem. Ignores byte enables entirely (get_byte_en()'s
    default True is never consulted) - AHB3LiteSeqItem always does full-word
    transfers already, matching how every existing sequence in this repo
    already talks to this bus (no byte-lane modeling anywhere today)."""

    def reg2bus(self, rw) -> AHB3LiteSeqItem:
        is_write = rw.kind == access_e.UVM_WRITE
        # uvm_reg_bus_op.addr is annotated `int` (s24_uvm_reg_includes.py),
        # but uvm_reg_map.process_write_operation/process_read_operation
        # actually assign the register's raw address *string* (e.g. "0x0",
        # from reg.get_address()) into it, never converting to int - so this
        # is a hex string in practice, not an int. Handle both defensively
        # in case a future pyuvm version fixes this.
        addr = int(rw.addr, 16) if isinstance(rw.addr, str) else rw.addr
        return AHB3LiteSeqItem(
            name="reg_bus_req", addr=addr, is_write=is_write,
            wdata=rw.data if is_write else 0,
        )

    def bus2reg(self, bus_item: AHB3LiteSeqItem, rw) -> None:
        rw.status = uvm_resp_t.PASS_RESP if bus_item.hresp == 0 else uvm_resp_t.ERROR_RESP
        if rw.kind == access_e.UVM_READ:
            rw.data = bus_item.rdata
