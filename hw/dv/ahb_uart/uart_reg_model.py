from pyuvm import uvm_reg, uvm_reg_adapter, uvm_reg_block, uvm_reg_field
from pyuvm.s24_uvm_reg_includes import access_e, uvm_resp_t

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem


class CtrlReg(uvm_reg):
    def __init__(self, name="ctrl"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.enable = uvm_reg_field("enable")
        self.enable.configure(self, size=1, lsb_pos=0, access="RW", is_volatile=False, reset=0)
        self.tx_en = uvm_reg_field("tx_en")
        self.tx_en.configure(self, size=1, lsb_pos=1, access="RW", is_volatile=False, reset=0)
        self.rx_en = uvm_reg_field("rx_en")
        self.rx_en.configure(self, size=1, lsb_pos=2, access="RW", is_volatile=False, reset=0)
        self.rx_resync_en = uvm_reg_field("rx_resync_en")
        self.rx_resync_en.configure(self, size=1, lsb_pos=3, access="RW", is_volatile=False, reset=0)
        self.tx_break = uvm_reg_field("tx_break")
        self.tx_break.configure(self, size=1, lsb_pos=4, access="RW", is_volatile=False, reset=0)
        # flush_tx_fifo/flush_rx_fifo are one-shot pulses in the RTL - the
        # model has no self-clearing-bit concept, so "WO" (write-only, model
        # never mirrors a meaningful value back) is the honest fit, not "RW".
        self.flush_tx_fifo = uvm_reg_field("flush_tx_fifo")
        self.flush_tx_fifo.configure(self, size=1, lsb_pos=5, access="WO", is_volatile=False, reset=0)
        self.flush_rx_fifo = uvm_reg_field("flush_rx_fifo")
        self.flush_rx_fifo.configure(self, size=1, lsb_pos=6, access="WO", is_volatile=False, reset=0)
        self.clk_div = uvm_reg_field("clk_div")
        self.clk_div.configure(self, size=10, lsb_pos=16, access="RW", is_volatile=False, reset=0)


class StatusReg(uvm_reg):
    def __init__(self, name="status"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.tx_empty = uvm_reg_field("tx_empty")
        self.tx_empty.configure(self, size=1, lsb_pos=0, access="RO", is_volatile=True, reset=1)
        self.tx_full = uvm_reg_field("tx_full")
        self.tx_full.configure(self, size=1, lsb_pos=1, access="RO", is_volatile=True, reset=0)
        self.rx_empty = uvm_reg_field("rx_empty")
        self.rx_empty.configure(self, size=1, lsb_pos=2, access="RO", is_volatile=True, reset=1)
        self.rx_full = uvm_reg_field("rx_full")
        self.rx_full.configure(self, size=1, lsb_pos=3, access="RO", is_volatile=True, reset=0)
        self.tx_active = uvm_reg_field("tx_active")
        self.tx_active.configure(self, size=1, lsb_pos=4, access="RO", is_volatile=True, reset=0)
        self.rx_frame_error = uvm_reg_field("rx_frame_error")
        self.rx_frame_error.configure(self, size=1, lsb_pos=5, access="RC", is_volatile=True, reset=0)
        # Modeled RO, not RC: ahb_uart.sv's STATUS read-clear block has a
        # copy-paste bug and never actually clears this bit on a STATUS read
        # - only a full reset does. RC here would make the model predict a
        # clear that the real DUT doesn't perform.
        self.rx_break = uvm_reg_field("rx_break")
        self.rx_break.configure(self, size=1, lsb_pos=6, access="RO", is_volatile=True, reset=0)


class TxDataReg(uvm_reg):
    def __init__(self, name="txdata"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.data = uvm_reg_field("data")
        self.data.configure(self, size=8, lsb_pos=0, access="WO", is_volatile=False, reset=0)


class RxDataReg(uvm_reg):
    def __init__(self, name="rxdata"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.data = uvm_reg_field("data")
        self.data.configure(self, size=8, lsb_pos=0, access="RO", is_volatile=True, reset=0)


class UartRegBlock(uvm_reg_block):
    # Addresses must be pre-formatted exactly as Python's plain hex() would
    # render them (no zero-padding, lowercase) - uvm_reg_map.add_reg() keys
    # its internal dict via hex(int(address, 16) + offset), but uvm_reg.write
    # ()/read() look registers up via reg.get_address(), which returns this
    # raw string verbatim, never renormalized. A zero-padded/uppercase string
    # here (e.g. "0x00", "0x0C") won't string-match the map's canonical key
    # and write()/read() will raise KeyError.
    def build(self):
        self.ctrl = CtrlReg()
        self.ctrl.configure(self, address="0x0", hdl_path="")
        self.status = StatusReg()
        self.status.configure(self, address="0x4", hdl_path="")
        self.txdata = TxDataReg()
        self.txdata.configure(self, address="0x8", hdl_path="")
        self.rxdata = RxDataReg()
        self.rxdata.configure(self, address="0xc", hdl_path="")

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
