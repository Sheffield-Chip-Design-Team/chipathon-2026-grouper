from pyuvm import uvm_reg, uvm_reg_adapter, uvm_reg_block, uvm_reg_field
from pyuvm.s24_uvm_reg_includes import access_e, uvm_resp_t

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem


# -----------------------------------------------------------------------------
# QSPI register offsets
# -----------------------------------------------------------------------------

CTRL_OFFSET = 0x00
CMD_OFFSET = 0x04
STATUS_OFFSET = 0x08
ADDR_OFFSET = 0x0C
DATA_OFFSET = 0x10

CLKDIV_RESET = 0x00


# -----------------------------------------------------------------------------
# CTRL — 0x00
# -----------------------------------------------------------------------------

class CtrlReg(uvm_reg):
    def __init__(self, name="ctrl"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.cpha = uvm_reg_field("cpha")
        self.cpha.configure(
            self,
            size=1,
            lsb_pos=0,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.cpol = uvm_reg_field("cpol")
        self.cpol.configure(
            self,
            size=1,
            lsb_pos=1,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.quad_mode = uvm_reg_field("quad_mode")
        self.quad_mode.configure(
            self,
            size=1,
            lsb_pos=2,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.flash_write_en = uvm_reg_field("flash_write_en")
        self.flash_write_en.configure(
            self,
            size=1,
            lsb_pos=3,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.ie_done = uvm_reg_field("ie_done")
        self.ie_done.configure(
            self,
            size=1,
            lsb_pos=4,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.ie_err = uvm_reg_field("ie_err")
        self.ie_err.configure(
            self,
            size=1,
            lsb_pos=5,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.clkdiv = uvm_reg_field("clkdiv")
        self.clkdiv.configure(
            self,
            size=8,
            lsb_pos=8,
            access="RW",
            is_volatile=False,
            reset=CLKDIV_RESET,
        )


# -----------------------------------------------------------------------------
# CMD — 0x04
# -----------------------------------------------------------------------------

class CmdReg(uvm_reg):
    def __init__(self, name="cmd"):
        super().__init__(name, reg_width=32)

    def build(self):
        # START is a write-only action bit in the register model:
        # writing one requests a transaction, while reads always return zero.
        self.start = uvm_reg_field("start")
        self.start.configure(
            self,
            size=1,
            lsb_pos=0,
            access="WO",
            is_volatile=False,
            reset=0,
        )

        self.dir = uvm_reg_field("dir")
        self.dir.configure(
            self,
            size=1,
            lsb_pos=1,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.addr_en = uvm_reg_field("addr_en")
        self.addr_en.configure(
            self,
            size=1,
            lsb_pos=2,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.data_en = uvm_reg_field("data_en")
        self.data_en.configure(
            self,
            size=1,
            lsb_pos=3,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.target = uvm_reg_field("target")
        self.target.configure(
            self,
            size=1,
            lsb_pos=4,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.fast_txn_en = uvm_reg_field("fast_txn_en")
        self.fast_txn_en.configure(
            self,
            size=1,
            lsb_pos=5,
            access="RW",
            is_volatile=False,
            reset=0,
        )

        self.dummy = uvm_reg_field("dummy")
        self.dummy.configure(
            self,
            size=8,
            lsb_pos=8,
            access="RW",
            is_volatile=False,
            reset=0,
        )


# -----------------------------------------------------------------------------
# STATUS — 0x08
# -----------------------------------------------------------------------------

class StatusReg(uvm_reg):
    def __init__(self, name="status"):
        super().__init__(name, reg_width=32)

    def build(self):
        # Live hardware state.
        self.busy = uvm_reg_field("busy")
        self.busy.configure(
            self,
            size=1,
            lsb_pos=0,
            access="RO",
            is_volatile=True,
            reset=0,
        )

        self.init_done = uvm_reg_field("init_done")
        self.init_done.configure(
            self,
            size=1,
            lsb_pos=1,
            access="RO",
            is_volatile=True,
            reset=0,
        )

        # Sticky hardware events cleared by writing one.
        self.done = uvm_reg_field("done")
        self.done.configure(
            self,
            size=1,
            lsb_pos=2,
            access="W1C",
            is_volatile=True,
            reset=0,
        )

        self.rx_valid = uvm_reg_field("rx_valid")
        self.rx_valid.configure(
            self,
            size=1,
            lsb_pos=3,
            access="W1C",
            is_volatile=True,
            reset=0,
        )

        self.cfg_err = uvm_reg_field("cfg_err")
        self.cfg_err.configure(
            self,
            size=1,
            lsb_pos=4,
            access="W1C",
            is_volatile=True,
            reset=0,
        )

        self.write_blocked = uvm_reg_field("write_blocked")
        self.write_blocked.configure(
            self,
            size=1,
            lsb_pos=5,
            access="W1C",
            is_volatile=True,
            reset=0,
        )

        self.addr_err = uvm_reg_field("addr_err")
        self.addr_err.configure(
            self,
            size=1,
            lsb_pos=6,
            access="W1C",
            is_volatile=True,
            reset=0,
        )


# -----------------------------------------------------------------------------
# ADDR — 0x0C
# -----------------------------------------------------------------------------

class AddrReg(uvm_reg):
    def __init__(self, name="addr"):
        super().__init__(name, reg_width=32)

    def build(self):
        self.address = uvm_reg_field("address")
        self.address.configure(
            self,
            size=24,
            lsb_pos=0,
            access="RW",
            is_volatile=False,
            reset=0,
        )


# -----------------------------------------------------------------------------
# DATA — 0x10
# -----------------------------------------------------------------------------

class DataReg(uvm_reg):
    def __init__(self, name="data"):
        super().__init__(name, reg_width=32)

    def build(self):
        # Software can write transmit data, while hardware may replace it with
        # received data. It is therefore both RW and volatile.
        self.data = uvm_reg_field("data")
        self.data.configure(
            self,
            size=8,
            lsb_pos=0,
            access="RW",
            is_volatile=True,
            reset=0,
        )


# -----------------------------------------------------------------------------
# Complete QSPI register block
# -----------------------------------------------------------------------------

class QspiRegBlock(uvm_reg_block):
    """
    Frontdoor register model for the five-register AHB QSPI interface.

    Register addresses must use Python's canonical lowercase hex formatting
    without zero-padding. The current pyuvm register-map implementation stores
    and looks up these address strings directly.
    """

    def build(self):
        self.ctrl = CtrlReg()
        self.ctrl.configure(self, address="0x0", hdl_path="")

        self.cmd = CmdReg()
        self.cmd.configure(self, address="0x4", hdl_path="")

        self.status = StatusReg()
        self.status.configure(self, address="0x8", hdl_path="")

        self.addr = AddrReg()
        self.addr.configure(self, address="0xc", hdl_path="")

        self.data = DataReg()
        self.data.configure(self, address="0x10", hdl_path="")

        # blk_create_map() creates and registers the default map as a side
        # effect. Retrieve it afterward through blk_get_def_map().
        self.blk_create_map("reg_map", base_addr=0)
        reg_map = self.blk_get_def_map()

        reg_map.add_reg(self.ctrl, offset="0x0", rights="RW")
        reg_map.add_reg(self.cmd, offset="0x0", rights="RW")

        # STATUS is mixed-access: BUSY/INIT_DONE are RO, while the event fields
        # are W1C. The map must therefore permit both reads and writes.
        reg_map.add_reg(self.status, offset="0x0", rights="RW")

        reg_map.add_reg(self.addr, offset="0x0", rights="RW")
        reg_map.add_reg(self.data, offset="0x0", rights="RW")

        self.set_lock()


# -----------------------------------------------------------------------------
# AHB3-Lite register adapter
# -----------------------------------------------------------------------------

class Ahb3LiteRegAdapter(uvm_reg_adapter):
    """
    Frontdoor translation between pyuvm register operations and the repository's
    AHB3LiteSeqItem.

    Register-model accesses currently use full 32-bit AHB transfers. Directed
    byte-lane and alignment tests will use raw AHB sequence items instead.
    """

    def reg2bus(self, rw) -> AHB3LiteSeqItem:
        is_write = rw.kind == access_e.UVM_WRITE

        # pyuvm currently passes the register address as its configured hex
        # string. Convert it to an integer for AHB3LiteSeqItem.
        addr = int(rw.addr, 16) if isinstance(rw.addr, str) else rw.addr

        return AHB3LiteSeqItem(
            name="reg_bus_req",
            addr=addr,
            is_write=is_write,
            wdata=rw.data if is_write else 0,
        )

    def bus2reg(self, bus_item: AHB3LiteSeqItem, rw) -> None:
        rw.status = (
            uvm_resp_t.PASS_RESP
            if bus_item.hresp == 0
            else uvm_resp_t.ERROR_RESP
        )

        if rw.kind == access_e.UVM_READ:
            rw.data = bus_item.rdata