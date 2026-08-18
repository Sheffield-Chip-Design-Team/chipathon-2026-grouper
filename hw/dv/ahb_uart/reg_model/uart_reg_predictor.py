"""Register prediction for the AHB UART register model.

pyuvm 4.0.1 ships `uvm_reg_predictor` as an empty stub (s26_uvm_predictor.py:
a constructor and nothing else - no predict(), no bus_in analysis export), but
`uvm_reg_map.set_predictor()` still isinstance-checks against it. So the
prediction body has to be supplied here.

This is auto-prediction, not explicit prediction: `uvm_reg_map` calls
`get_predictor().predict(bus_op, check)` at the end of
process_write_operation()/process_read_operation(), i.e. driven by the
register model's own issue path rather than by a bus monitor. pyuvm has no
working explicit-prediction path, so bus traffic that bypasses the register
model (the raw ahb_write()/ahb_read() helpers) is not predicted here - the
scoreboard watches the AHB monitor for that.

`check_t.CHECK` is inert everywhere else in pyuvm: forwarding it into this
predict() is the *only* place the whole package consumes the flag, so
check-on-read means what this file implements and nothing more.
"""

from pyuvm.s17_uvm_reg_enumerations import uvm_door_e, uvm_predict_e
from pyuvm.s24_uvm_reg_includes import access_e, check_t, uvm_resp_t
from pyuvm.s26_uvm_predictor import uvm_reg_predictor

from .uart_reg_model import decode_reg


class UartRegPredictor(uvm_reg_predictor):
    """Keeps the register mirrors in step with the DUT and compares read data
    against the mirror for the fields that are predictable from bus traffic.

    Mismatches are collected in self.failures rather than raised: a
    uvm_reg_predictor is a uvm_object, which has no logger and sits outside
    the component hierarchy, so UartAhbScoreboard.check_phase is what turns
    these into a test failure."""

    def __init__(self, name="uart_reg_predictor", reg_map=None, logger=None):
        super().__init__(name)
        self.reg_map = reg_map
        # Borrowed from the component that owns us - see class docstring.
        self.logger = logger
        self.failures = []
        self.checks = 0
        self.predictions = 0

    def set_logger(self, logger):
        self.logger = logger

    def _log(self, level: str, message: str):
        if self.logger is not None:
            getattr(self.logger, level)(message)

    def _reg_for(self, addr):
        # uvm_reg_bus_op.addr is annotated `int` but carries the register's raw
        # address *string* ("0x8") in practice - uvm_reg_map assigns
        # reg.get_address() straight into it. Same quirk Ahb3LiteRegAdapter
        # already handles; accept both.
        addr_int = int(addr, 16) if isinstance(addr, str) else addr
        # get_reg_by_offset keys on hex(), so hand it hex() - a zero-padded or
        # uppercase string will not match.
        return self.reg_map.get_reg_by_offset(hex(addr_int))

    def predict(self, bus_op, check):
        """Called by uvm_reg_map after every frontdoor access."""
        reg = self._reg_for(bus_op.addr)
        is_read = bus_op.kind == access_e.UVM_READ

        # The DUT rejected the access (TXDATA write into a full FIFO, RXDATA
        # read while empty) - no register state changed, and the read data is
        # meaningless, so predicting from it would corrupt the mirror.
        if bus_op.status == uvm_resp_t.ERROR_RESP:
            self._log("debug", f"PREDICT skipped (HRESP=ERROR) on {reg.get_name()}")
            return

        if is_read and check == check_t.CHECK:
            self._check_read(reg, bus_op.data)

        kind = uvm_predict_e.UVM_PREDICT_READ if is_read else uvm_predict_e.UVM_PREDICT_WRITE
        reg.predict(bus_op.data, kind=kind, path=uvm_door_e.UVM_FRONTDOOR, map=self.reg_map)
        self.predictions += 1
        self._log(
            "debug",
            f"PREDICT {'READ' if is_read else 'WRITE'} {reg.get_name()} "
            f"{decode_reg(reg, reg.get_mirrored_value())}",
        )

    def _check_read(self, reg, read_data: int):
        """Compare the read data against the mirror, field by field.

        Volatile fields (all of STATUS, RXDATA) are driven by the DUT's own
        FIFOs and FSMs, so the mirror can't anticipate them; fields whose
        set_compare() is NO_CHECK opt out explicitly. Note that get_compare()
        raises AttributeError unless set_compare() was called - pyuvm's
        configure() sets an unrelated `_compare` attribute and leaves `_check`
        undefined - so uart_reg_model.py sets it on every field."""
        for field in reg.get_fields():
            if field.is_volatile() or field.get_compare() != check_t.CHECK:
                continue

            mask = (1 << field.get_n_bits()) - 1
            actual = (read_data >> field.get_lsb_pos()) & mask
            expected = field.get_value()
            self.checks += 1

            if actual != expected:
                msg = (
                    f"{reg.get_name()}.{field.get_name()} readback mismatch: "
                    f"expected 0x{expected:x} got 0x{actual:x} "
                    f"(full read 0x{read_data:08x})"
                )
                self.failures.append(msg)
                self._log("warning", msg)
