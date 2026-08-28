"""Wire-level scoreboard for the AHB UART.

Division of labour with UartRegPredictor: the predictor owns the register
mirrors (and the check-on-read against them), this owns UART wire traffic. The
scoreboard never calls reg.predict() - auto-prediction already fires for every
register-model access, and predicting the same access twice would clear
STATUS's RC bits twice and re-apply CTRL's WO flush bits. It only *reads* the
register model, for field metadata.

Two independent directions:

  TX   monitored AHB write to TXDATA  ->  byte expected on uart_tx
  RX   byte monitored on uart_rx      ->  value expected from an RXDATA read

Neither direction may assume the two streams arrive in causal order.
UartMonitor.sample_bit() waits out the rest of the stop-bit period before
emitting its item, while the DUT samples mid-stop-bit and can report
rx_empty=0 straight away - so a sequence's RXDATA read can reach this
scoreboard *before* the monitored byte that explains it. Hence expected and
observed are separate deques per direction, matched in pairs only when both
sides have an entry, rather than popping an expectation at observe time.
"""

from collections import deque

import cocotb
from cocotb.triggers import FallingEdge

from pyuvm import ConfigDB, uvm_component, uvm_tlm_analysis_fifo

from ..reg_model.uart_reg_consts import ADDR_CTRL, ADDR_MASK, ADDR_RXDATA, ADDR_TXDATA, DATA_MASK
from ..reg_model.uart_reg_model import field_value

FIFO_DEPTH = 4

HSIZE_BYTE = 0b000
HSIZE_HALFWORD = 0b001

class UartAhbScoreboard(uvm_component):
    def build_phase(self):
        # One analysis fifo per stream, each drained by its own task: a
        # uvm_subscriber would only give this component a single
        # analysis_export, and blocking get() is what lets the three streams
        # advance independently.
        self.ahb_fifo = uvm_tlm_analysis_fifo("ahb_fifo", self)
        self.uart_tx_fifo = uvm_tlm_analysis_fifo("uart_tx_fifo", self)
        self.uart_rx_fifo = uvm_tlm_analysis_fifo("uart_rx_fifo", self)

        self.exp_tx = deque()  # bytes the AHB side says should reach uart_tx
        self.obs_tx = deque()  # bytes the passive uart_tx monitor actually saw
        self.exp_rx = deque()  # bytes the uart_rx monitor saw going into the DUT
        self.obs_rx = deque()  # RXDATA values the AHB side actually read back

        self.stats = {
            "tx_match": 0, "tx_mismatch": 0,
            "rx_match": 0, "rx_mismatch": 0,
            "tx_rejected": 0, "rx_underflow": 0,
            "rx_overflow": 0, "tx_break_drops": 0,
            "resets": 0,
        }
        self.failures = []

        # Set by CTRL writes; while high the DUT holds uart_tx low, which the
        # passive monitor decodes as a garbage frame rather than a byte.
        self.tx_break = False

        # Handed over by the env in connect_phase - its check-on-read
        # failures are reported through this component's check_phase.
        self.predictor = None

    def start_of_simulation_phase(self):
        self.dut = cocotb.top
        self.reg_model = ConfigDB().get(self, "", "UART_REG_MODEL")

    async def run_phase(self):
        cocotb.start_soon(self._ahb_loop())
        cocotb.start_soon(self._uart_tx_loop())
        cocotb.start_soon(self._uart_rx_loop())
        await self._reset_loop()

    # ------------------------------------------------------------------
    # Stream consumers

    async def _ahb_loop(self):
        while True:
            item = await self.ahb_fifo.get_export.get()
            self._handle_ahb(item)

    async def _uart_tx_loop(self):
        while True:
            item = await self.uart_tx_fifo.get_export.get()
            self._handle_uart_tx(item)

    async def _uart_rx_loop(self):
        while True:
            item = await self.uart_rx_fifo.get_export.get()
            self._handle_uart_rx(item)

    def _handle_uart_tx(self, item):
        if self.tx_break:
            # A break drives uart_tx low for longer than a frame; whatever
            # the monitor decoded out of that is not a transmitted byte.
            self.stats["tx_break_drops"] += 1
            self.logger.warning(
                f"Discarding uart_tx byte 0x{item.data:02x} decoded while tx_break is set"
            )
            return
        self.obs_tx.append(item.data)
        self._match(self.exp_tx, self.obs_tx, "tx")

    def _handle_uart_rx(self, item):
        self.exp_rx.append(item.data)
        if len(self.exp_rx) > FIFO_DEPTH:
            # Not modelled, deliberately. small_sync_fifo executes
            # `memory[wptr] <= wdata` even when full, and when full
            # wptr == rptr - so an overflowing byte overwrites the *oldest
            # unread* entry instead of being dropped. Modelling that needs
            # a trustworthy occupancy count, which the ordering hazard in
            # the module docstring denies us. No test in the suite
            # overflows the RX FIFO today; whoever writes one starts here.
            self.stats["rx_overflow"] += 1
            self.logger.warning(
                f"{len(self.exp_rx)} unmatched RX bytes exceeds FIFO_DEPTH={FIFO_DEPTH} "
                "- RX overflow is not modelled, comparisons past this point may be bogus"
            )
        self._match(self.exp_rx, self.obs_rx, "rx")

    async def _reset_loop(self):
        # No monitor reports reset today, so watch HRESETn directly. The
        # eventual home for this is the (currently empty) clockandreset UVC.
        while True:
            await FallingEdge(self.dut.HRESETn)
            self.stats["resets"] += 1
            pending = len(self.exp_tx) + len(self.obs_tx) + len(self.exp_rx) + len(self.obs_rx)
            if pending:
                self.logger.info(f"Reset: discarding {pending} in-flight scoreboard entries")
            for q in (self.exp_tx, self.obs_tx, self.exp_rx, self.obs_rx):
                q.clear()
            self.tx_break = False

    # ------------------------------------------------------------------
    # Prediction

    @staticmethod
    def _lane0_selected(item) -> bool:
        """Whether byte lane 0 is driven, mirroring generate_byte_select_32
        (ahb3lite_pkg.sv). ahb_uart.sv gates its CTRL and TXDATA writes on it."""
        if item.size == HSIZE_BYTE:
            return (item.addr & 0x3) == 0
        if item.size == HSIZE_HALFWORD:
            return (item.addr & 0x2) == 0
        return True  # word (or wider); the RTL treats anything else as X

    def _handle_ahb(self, item):
        offset = item.addr & ADDR_MASK

        if item.is_write and offset == ADDR_CTRL:
            self._apply_ctrl_write(item)
        elif item.is_write and offset == ADDR_TXDATA:
            self._predict_tx_byte(item)
        elif not item.is_write and offset == ADDR_RXDATA:
            self._observe_rx_read(item)

    def _apply_ctrl_write(self, item):
        if not self._lane0_selected(item):
            return

        ctrl = self.reg_model.ctrl
        self.tx_break = bool(field_value(ctrl, "tx_break", item.wdata))

        if field_value(ctrl, "flush_tx_fifo", item.wdata):
            if self.exp_tx:
                # A byte already loaded into the shift register is past the
                # FIFO and still goes out, so the observed side can legitimately
                # run one ahead of the expected side here.
                self.logger.warning(
                    f"flush_tx_fifo dropped {len(self.exp_tx)} pending TX expectation(s)"
                )
            self.exp_tx.clear()

        if field_value(ctrl, "flush_rx_fifo", item.wdata):
            if self.exp_rx:
                self.logger.warning(
                    f"flush_rx_fifo dropped {len(self.exp_rx)} pending RX expectation(s)"
                )
            self.exp_rx.clear()

    def _predict_tx_byte(self, item):
        if not self._lane0_selected(item):
            return

        # ahb_uart.sv gates tx_write on !status_tx_full and raises the error
        # response off that same signal, so HRESP==1 means the byte was
        # rejected and never entered the FIFO.
        if item.hresp:
            self.stats["tx_rejected"] += 1
            self.logger.debug(f"TXDATA write 0x{item.wdata & DATA_MASK:02x} rejected (FIFO full)")
            return

        self.exp_tx.append(item.wdata & DATA_MASK)
        self._match(self.exp_tx, self.obs_tx, "tx")

    def _observe_rx_read(self, item):
        # rx_read is gated on !status_rx_empty, and the same condition drives
        # the error response - so HRESP==1 means nothing was popped.
        if item.hresp:
            self.stats["rx_underflow"] += 1
            self.logger.debug("RXDATA read while empty - no byte popped")
            return

        self.obs_rx.append(item.rdata & DATA_MASK)
        self._match(self.exp_rx, self.obs_rx, "rx")

    # ------------------------------------------------------------------
    # Matching

    def _match(self, expected, observed, label: str):
        while expected and observed:
            exp = expected.popleft()
            obs = observed.popleft()
            if exp == obs:
                self.stats[f"{label}_match"] += 1
                self.logger.debug(f"{label.upper()} match: 0x{exp:02x}")
            else:
                self.stats[f"{label}_mismatch"] += 1
                msg = f"{label.upper()} mismatch: expected 0x{exp:02x} got 0x{obs:02x}"
                self.failures.append(msg)
                self.logger.warning(msg)

    # ------------------------------------------------------------------
    # End of test

    def _drain(self, fifo, handler, label: str):
        """Push anything still sitting in an analysis fifo through its normal
        handler. The consumer loops die with the objection, so an item written
        in the last few cycles of the test is otherwise stranded in the queue -
        and the last bus access of a test is very often the RXDATA read that
        completes an RX comparison."""
        drained = 0
        while True:
            got, item = fifo.nonblocking_get_export.try_get()
            if not got:
                break
            handler(item)
            drained += 1
        if drained:
            self.logger.debug(f"Drained {drained} late {label} item(s) at end of test")

    def check_phase(self):
        self._drain(self.ahb_fifo, self._handle_ahb, "AHB")
        self._drain(self.uart_tx_fifo, self._handle_uart_tx, "uart_tx")
        self._drain(self.uart_rx_fifo, self._handle_uart_rx, "uart_rx")

        errors = list(self.failures)

        # A byte on the wire, or an RXDATA pop, with no expectation behind it
        # is a real bug. Leftover *expectations* only warn - a byte written to
        # TXDATA just before the objection dropped may still be shifting out.
        if self.obs_tx:
            errors.append(f"{len(self.obs_tx)} unexpected byte(s) on uart_tx: "
                          f"{[f'0x{b:02x}' for b in self.obs_tx]}")
        if self.obs_rx:
            errors.append(f"{len(self.obs_rx)} RXDATA read(s) with no byte received: "
                          f"{[f'0x{b:02x}' for b in self.obs_rx]}")
        if self.exp_tx:
            self.logger.warning(
                f"{len(self.exp_tx)} TX byte(s) still pending at end of test: "
                f"{[f'0x{b:02x}' for b in self.exp_tx]}"
            )
        if self.exp_rx:
            self.logger.warning(
                f"{len(self.exp_rx)} received byte(s) never read from RXDATA: "
                f"{[f'0x{b:02x}' for b in self.exp_rx]}"
            )

        if self.predictor is not None:
            errors.extend(self.predictor.failures)

        if errors:
            raise AssertionError(
                f"{self.get_name()} found {len(errors)} failure(s):\n  " + "\n  ".join(errors)
            )

    def report_phase(self):
        self.logger.info(
            f"Scoreboard: TX {self.stats['tx_match']} matched / "
            f"{self.stats['tx_mismatch']} mismatched, "
            f"RX {self.stats['rx_match']} matched / {self.stats['rx_mismatch']} mismatched"
        )
        self.logger.info(
            f"Scoreboard: {self.stats['tx_rejected']} TXDATA write(s) rejected, "
            f"{self.stats['rx_underflow']} RXDATA read(s) while empty, "
            f"{self.stats['resets']} reset(s)"
        )
        if self.predictor is not None:
            self.logger.info(
                f"Register predictor: {self.predictor.predictions} prediction(s), "
                f"{self.predictor.checks} field check(s) on read, "
                f"{len(self.predictor.failures)} mismatch(es)"
            )
