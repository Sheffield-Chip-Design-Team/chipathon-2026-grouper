"""Single source of truth for every ahb_uart register constant used by the DV
suite - addresses, field positions/widths, single-bit masks and reset values.

Everything here mirrors hw/rtl/uart/ahb_uart.sv: the ADDR_* localparams (~line
91), the CTRL/STATUS bit assignments in its header comment, and the reset
block (~line 199). uart_reg_model.py builds its uvm_reg fields out of these,
so a change here propagates to the register model, the predictor's
check-on-read, the scoreboard and the sequences at once.

Two shapes of constant, because both are genuinely needed:

  *_LSB / *_BITS   fed to uvm_reg_field.configure() by uart_reg_model.py
  bare name        pre-shifted single-bit mask (CTRL_ENABLE == 1 << 0), for
                   composing and testing raw register words in sequence
                   bodies, e.g. `if status & STATUS_RX_BREAK`
"""

# ---------------------------------------------------------------------------
# Register addresses
#
# ahb_uart.sv decodes HADDR[3:2] only (ADDR_CTRL..ADDR_RXDATA are 2-bit
# localparams), so ADDR_MASK is what turns a monitored bus address anywhere in
# the 4 KiB window into one of the four offsets below.

ADDR_CTRL = 0x0
ADDR_STATUS = 0x4
ADDR_TXDATA = 0x8
ADDR_RXDATA = 0xC

ADDR_MASK = 0xC

# uvm_reg_map keys its register dict on Python's plain hex() (lowercase, no
# zero padding), and uvm_reg.write()/read() look registers up by the raw
# string handed to configure() - so the model must pass hex(ADDR_*) verbatim,
# never a hand-written "0x00"/"0x0C". See UartRegBlock.build().

# ---------------------------------------------------------------------------
# CTRL (0x0)
#
# Read mux hardwires bits [15:5] to zero, so the two flush bits never read
# back the 1 that was written to them.

CTRL_ENABLE_LSB = 0
CTRL_TX_EN_LSB = 1
CTRL_RX_EN_LSB = 2
CTRL_RX_RESYNC_EN_LSB = 3
CTRL_TX_BREAK_LSB = 4
CTRL_FLUSH_TX_FIFO_LSB = 5
CTRL_FLUSH_RX_FIFO_LSB = 6
CTRL_CLK_DIV_LSB = 16

CTRL_CLK_DIV_BITS = 10  # ahb_uart.sv's CLK_DIV_BITS localparam

CTRL_ENABLE = 1 << CTRL_ENABLE_LSB
CTRL_TX_EN = 1 << CTRL_TX_EN_LSB
CTRL_RX_EN = 1 << CTRL_RX_EN_LSB
CTRL_RX_RESYNC_EN = 1 << CTRL_RX_RESYNC_EN_LSB
CTRL_TX_BREAK = 1 << CTRL_TX_BREAK_LSB
CTRL_FLUSH_TX_FIFO = 1 << CTRL_FLUSH_TX_FIFO_LSB
CTRL_FLUSH_RX_FIFO = 1 << CTRL_FLUSH_RX_FIFO_LSB

# clk_div right-aligned (0x3FF) and in place (0x03FF_0000) - the first for
# building a CTRL word out of a divider value, the second for masking a
# readback down to just that field.
CTRL_CLK_DIV_MASK = (1 << CTRL_CLK_DIV_BITS) - 1
CTRL_CLK_DIV_FIELD = CTRL_CLK_DIV_MASK << CTRL_CLK_DIV_LSB

# The four "steady state" enables, i.e. everything in CTRL[3:0]: what
# configure_uart() sets and then checks on readback (the flush bits are
# excluded because they cannot read back, tx_break because it is not part of
# normal configuration).
CTRL_EN_FIELDS = CTRL_ENABLE | CTRL_TX_EN | CTRL_RX_EN | CTRL_RX_RESYNC_EN

# Non-zero CTRL reset values (ahb_uart.sv resets ctrl_rx_resync_en to 1 and
# ctrl_clk_div to all-ones). Every other field resets to 0.
CTRL_RESET_RX_RESYNC_EN = 1
CTRL_RESET_CLK_DIV = CTRL_CLK_DIV_MASK

# ---------------------------------------------------------------------------
# STATUS (0x4)

STATUS_TX_EMPTY_LSB = 0
STATUS_TX_FULL_LSB = 1
STATUS_RX_EMPTY_LSB = 2
STATUS_RX_FULL_LSB = 3
STATUS_TX_ACTIVE_LSB = 4
STATUS_RX_FRAME_ERROR_LSB = 5
STATUS_RX_BREAK_LSB = 6

STATUS_TX_EMPTY = 1 << STATUS_TX_EMPTY_LSB
STATUS_TX_FULL = 1 << STATUS_TX_FULL_LSB
STATUS_RX_EMPTY = 1 << STATUS_RX_EMPTY_LSB
STATUS_RX_FULL = 1 << STATUS_RX_FULL_LSB
STATUS_TX_ACTIVE = 1 << STATUS_TX_ACTIVE_LSB
STATUS_RX_FRAME_ERROR = 1 << STATUS_RX_FRAME_ERROR_LSB
STATUS_RX_BREAK = 1 << STATUS_RX_BREAK_LSB

# Both FIFOs come out of reset empty; everything else in STATUS resets to 0.
STATUS_RESET_TX_EMPTY = 1
STATUS_RESET_RX_EMPTY = 1

# ---------------------------------------------------------------------------
# TXDATA (0x8) / RXDATA (0xC)

UART_DATA_BITS = 8  # ahb_uart.sv's UART_DATA_W localparam
DATA_MASK = (1 << UART_DATA_BITS) - 1
