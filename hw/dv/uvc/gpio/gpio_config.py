from dataclasses import dataclass


@dataclass
class GpioConfig:
    """Pin configuration for a GpioAgent instance.

    Field names are from the DUT's point of view (same convention as
    hw/dv/uvc/template/UART.py's dut_rx_pin/dut_tx_pin args):
      - dut_rx_pin: net the DUT samples as an input. An active GpioAgent's
        driver drives this pin.
      - dut_tx_pin: net the DUT drives as an output. The GpioAgent's
        monitor samples this pin.
    Paths may be dotted (e.g. "io_mux.gpio_pins_3") to reach into DUT
    submodules/hierarchy, same as VIP_Base.resolve_handle.
    """

    dut_rx_pin: str = ""
    dut_tx_pin: str = ""
    clk_pin: str = "clk"


def resolve_pin(root, path: str):
    """Resolve a dotted hierarchical path (e.g. 'io_mux.gpio_pins_3') from
    `root` to a cocotb signal handle."""
    if not path:
        raise ValueError("GPIO pin path is empty - set dut_rx_pin/dut_tx_pin/clk_pin in GpioConfig")

    obj = root
    for part in path.split("."):
        if not hasattr(obj, part):
            raise AttributeError(f"Could not resolve GPIO pin path '{path}': no attribute '{part}' on {obj}")
        obj = getattr(obj, part)
    return obj
