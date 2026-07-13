from dataclasses import dataclass

DEFAULT_BAUD_RATE = 1_000_000

@dataclass
class UartConfig:
    baud_rate: int = DEFAULT_BAUD_RATE
    # False = sample at a random offset within the bit period (simulating
    # asynchronous sampling jitter), like hw/dv/uvc/template/UART.py's
    # random_sample(center_mode=False).
    center_sample: bool = True

    # DUT pin paths (dotted, e.g. "u_uart.uart_rx"), resolved via
    # resolve_handle() below.
    rx_pin: str = "uart_rx"
    tx_pin: str = "uart_tx"

    @property
    def bit_period_ns(self) -> int:
        """One UART bit's duration in ns"""
        return 1_000_000_000 // self.baud_rate

    @staticmethod
    def resolve_handle(root, path: str):
        """Resolve a dotted hierarchical path (e.g. 'u_uart.uart_rx') from
        `root` to a cocotb signal handle. Raises AttributeError if the path cannot be resolved."""
        if not path:
            raise ValueError("pin path is empty")

        obj = root
        for part in path.split("."):
            if not hasattr(obj, part):
                raise AttributeError(f"Could not resolve pin path '{path}': no attribute '{part}' on {obj}")
            obj = getattr(obj, part)
        return obj
