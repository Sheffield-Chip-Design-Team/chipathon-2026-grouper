import random

# ahb_uart.sv-specific: how the CTRL register's clk_div field maps to an
# actual baud rate. UartConfig/UartDriver/UartMonitor don't know about this -
# they use baud_rate directly via real-time Timer waits (see
# hw/dv/uvc/uart/uart_config.py) - this is purely what needs to be written to
# this particular DUT's register to make it run at the same baud rate.
AHB_UART_OVERSAMPLE = 8       # matches hw/rtl/uart/uart.sv's fixed OVERSAMPLE parameter
MAX_CLK_DIV = 1023            # CTRL register's clk_div field is 10 bits wide


def clk_div_for_baud(baud_rate: int, clk_period_ns: int) -> int:
    cycles_per_bit = (1e9 / baud_rate) / clk_period_ns
    clk_div = max(0, round(cycles_per_bit / AHB_UART_OVERSAMPLE) - 1)
    if clk_div > MAX_CLK_DIV:
        raise ValueError(
            f"baud_rate={baud_rate} needs clk_div={clk_div}, which overflows "
            f"the CTRL register's 10-bit field (max {MAX_CLK_DIV}) at "
            f"clk_period_ns={clk_period_ns}/oversample={AHB_UART_OVERSAMPLE} "
            f"- raise baud_rate, or lower AhbConfig.clk_period_ns to increase the clock frequency"
        )
    return clk_div


# Standard baud rates to pick from when randomizing. Not every one of these
# is actually reachable at every clk_period_ns - valid_baud_rates() below
# filters this list through clk_div_for_baud() itself rather than a
# hand-derived range, so it can't silently drift out of sync with the real
# rounding/overflow math above.
CANDIDATE_BAUD_RATES = [
    14400, 19200, 28800, 38400, 57600, 115200, 230400, 250000,
    460800, 500000, 921600, 1_000_000, 1_250_000, 1_500_000,
    2_000_000, 2_500_000, 3_000_000, 4_000_000, 6_000_000, 8_000_000,
]


def valid_baud_rates(clk_period_ns: int) -> list:
    out = []
    for baud_rate in CANDIDATE_BAUD_RATES:
        try:
            clk_div_for_baud(baud_rate, clk_period_ns)
            out.append(baud_rate)
        except ValueError:
            pass
    return out


def pick_random_baud_rate(clk_period_ns: int, rng: random.Random = None) -> int:
    rng = rng or random
    choices = valid_baud_rates(clk_period_ns)
    if not choices:
        raise ValueError(f"no candidate baud rate is valid at clk_period_ns={clk_period_ns}")
    return rng.choice(choices)
