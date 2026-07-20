import cocotb
from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB, uvm_sequence
from pyuvm.s24_uvm_reg_includes import check_t, path_t, uvm_resp_t

from hw.dv.uvc.ahb3lite import AHB3LiteSeqItem

from ..qspi_reg_model import (
    ADDR_OFFSET,
    CMD_OFFSET,
    CTRL_OFFSET,
    DATA_OFFSET,
    STATUS_OFFSET,
)
from ..tbench.ahb_qspi_env import (
    AHB_CFG_KEY,
    QSPI_AHB_SEQR_KEY,
    QSPI_REG_MODEL_KEY,
)


# -----------------------------------------------------------------------------
# AHB transfer constants
# -----------------------------------------------------------------------------

HSIZE_BYTE = 0b000
HSIZE_HALFWORD = 0b001
HSIZE_WORD = 0b010

HTRANS_IDLE = 0b00
HTRANS_BUSY = 0b01
HTRANS_NONSEQ = 0b10
HTRANS_SEQ = 0b11


# -----------------------------------------------------------------------------
# CTRL field masks
# -----------------------------------------------------------------------------

CTRL_CPHA = 1 << 0
CTRL_CPOL = 1 << 1
CTRL_QUAD_MODE = 1 << 2
CTRL_FLASH_WRITE_EN = 1 << 3
CTRL_IE_DONE = 1 << 4
CTRL_IE_ERR = 1 << 5

CTRL_CLKDIV_SHIFT = 8
CTRL_CLKDIV_MASK = 0xFF << CTRL_CLKDIV_SHIFT

CTRL_IMPLEMENTED_MASK = (
    CTRL_CPHA
    | CTRL_CPOL
    | CTRL_QUAD_MODE
    | CTRL_FLASH_WRITE_EN
    | CTRL_IE_DONE
    | CTRL_IE_ERR
    | CTRL_CLKDIV_MASK
)


# -----------------------------------------------------------------------------
# CMD field masks
# -----------------------------------------------------------------------------

CMD_START = 1 << 0
CMD_DIR = 1 << 1
CMD_ADDR_EN = 1 << 2
CMD_DATA_EN = 1 << 3
CMD_TARGET = 1 << 4
CMD_FAST_TXN_EN = 1 << 5

CMD_DUMMY_SHIFT = 8
CMD_DUMMY_MASK = 0xFF << CMD_DUMMY_SHIFT

# START is an action and always reads as zero, so it is excluded from the
# stored/readable mask.
CMD_STORED_MASK = (
    CMD_DIR
    | CMD_ADDR_EN
    | CMD_DATA_EN
    | CMD_TARGET
    | CMD_FAST_TXN_EN
    | CMD_DUMMY_MASK
)


# -----------------------------------------------------------------------------
# STATUS field masks
# -----------------------------------------------------------------------------

STATUS_BUSY = 1 << 0
STATUS_INIT_DONE = 1 << 1
STATUS_DONE = 1 << 2
STATUS_RX_VALID = 1 << 3
STATUS_CFG_ERR = 1 << 4
STATUS_WRITE_BLOCKED = 1 << 5
STATUS_ADDR_ERR = 1 << 6

STATUS_LIVE_MASK = STATUS_BUSY | STATUS_INIT_DONE

STATUS_W1C_MASK = (
    STATUS_DONE
    | STATUS_RX_VALID
    | STATUS_CFG_ERR
    | STATUS_WRITE_BLOCKED
    | STATUS_ADDR_ERR
)

STATUS_IMPLEMENTED_MASK = STATUS_LIVE_MASK | STATUS_W1C_MASK


# -----------------------------------------------------------------------------
# ADDR and DATA masks
# -----------------------------------------------------------------------------

ADDR_IMPLEMENTED_MASK = 0x00FF_FFFF
DATA_IMPLEMENTED_MASK = 0x0000_00FF


def decode_reg(reg, value: int) -> str:
    """
    Decode a raw register value using the field metadata in the pyuvm model.
    """

    parts = []

    for field in reg.get_fields():
        mask = (1 << field.get_n_bits()) - 1
        field_value = (value >> field.get_lsb_pos()) & mask

        parts.append(
            f"{field.get_name()}=0x{field_value:x}"
        )

    return " ".join(parts)


class QspiAhbBaseSequence(uvm_sequence):
    """
    Common AHB and register-model operations for QSPI register-shell tests.
    """

    def __init__(self, name="qspi_ahb_base_sequence"):
        super().__init__(name)

        self.ahb_cfg = None
        self.reg_model = None
        self.dut = cocotb.top

    def get_config(self):
        """
        Retrieve the environment objects required by the sequence.

        Sequences are not uvm_components, so the values are retrieved from the
        global ConfigDB scope populated by QspiAhbEnv.
        """

        self.sequencer = ConfigDB().get(
            None,
            "",
            QSPI_AHB_SEQR_KEY,
        )

        self.ahb_cfg = ConfigDB().get(
            None,
            "",
            AHB_CFG_KEY,
        )

        self.reg_model = ConfigDB().get(
            None,
            "",
            QSPI_REG_MODEL_KEY,
        )

    async def reg_write(self, reg, value: int) -> None:
        """
        Perform a full-word frontdoor write through the pyuvm register model.
        """

        self.sequencer.logger.debug(
            f"REG WRITE {reg.get_name()} "
            f"value=0x{value & 0xFFFF_FFFF:08x} "
            f"{decode_reg(reg, value)}"
        )

        status = await reg.write(
            value,
            map=self.reg_model.blk_get_def_map(),
            path=path_t.FRONTDOOR,
            check=check_t.NO_CHECK,
        )

        if status != uvm_resp_t.PASS_RESP:
            raise AssertionError(
                f"Register write to {reg.get_name()} failed "
                f"with status {status}"
            )

    async def reg_read(self, reg) -> int:
        """
        Perform a full-word frontdoor read through the pyuvm register model.
        """

        status, value = await reg.read(
            map=self.reg_model.blk_get_def_map(),
            path=path_t.FRONTDOOR,
            check=check_t.NO_CHECK,
        )

        self.sequencer.logger.debug(
            f"REG READ {reg.get_name()} "
            f"value=0x{value & 0xFFFF_FFFF:08x} "
            f"{decode_reg(reg, value)}"
        )

        if status != uvm_resp_t.PASS_RESP:
            raise AssertionError(
                f"Register read from {reg.get_name()} failed "
                f"with status {status}"
            )

        return value & 0xFFFF_FFFF

    async def ahb_write(
        self,
        addr: int,
        data: int,
        *,
        size: int = HSIZE_WORD,
        trans: int = HTRANS_NONSEQ,
        expect_error: bool = False,
    ) -> AHB3LiteSeqItem:
        """
        Perform a raw AHB write.

        Raw accesses are used for byte-lane, alignment, invalid-offset and
        malformed-transfer tests that the pyuvm register model cannot express.
        """

        item = AHB3LiteSeqItem(
            name=f"wr_{addr:03x}",
            addr=addr,
            is_write=True,
            wdata=data,
            size=size,
            trans=trans,
        )

        await self.start_item(item)
        await self.finish_item(item)

        self._check_ahb_response(
            item,
            expect_error=expect_error,
        )

        return item

    async def ahb_read(
        self,
        addr: int,
        *,
        size: int = HSIZE_WORD,
        trans: int = HTRANS_NONSEQ,
        expect_error: bool = False,
    ) -> AHB3LiteSeqItem:
        """
        Perform a raw AHB read.
        """

        item = AHB3LiteSeqItem(
            name=f"rd_{addr:03x}",
            addr=addr,
            is_write=False,
            size=size,
            trans=trans,
        )

        await self.start_item(item)
        await self.finish_item(item)

        self._check_ahb_response(
            item,
            expect_error=expect_error,
        )

        return item

    async def ahb_write_byte(
        self,
        register_offset: int,
        byte_index: int,
        value: int,
        *,
        expect_error: bool = False,
    ) -> AHB3LiteSeqItem:
        """
        Write one byte to a selected register byte lane.

        HWDATA is lane-aligned because the RTL consumes, for example,
        HWDATA[15:8] when byte lane 1 is selected.
        """

        if byte_index not in range(4):
            raise ValueError(
                f"byte_index must be 0-3, got {byte_index}"
            )

        addr = register_offset + byte_index
        data = (value & 0xFF) << (8 * byte_index)

        return await self.ahb_write(
            addr,
            data,
            size=HSIZE_BYTE,
            expect_error=expect_error,
        )

    async def ahb_read_byte(
        self,
        register_offset: int,
        byte_index: int,
        *,
        expect_error: bool = False,
    ) -> int:
        """
        Read one byte lane from a register.

        The current DUT returns the complete 32-bit register on HRDATA, so the
        requested lane is extracted explicitly.
        """

        if byte_index not in range(4):
            raise ValueError(
                f"byte_index must be 0-3, got {byte_index}"
            )

        item = await self.ahb_read(
            register_offset + byte_index,
            size=HSIZE_BYTE,
            expect_error=expect_error,
        )

        return (item.rdata >> (8 * byte_index)) & 0xFF

    async def reset_dut(self, cycles_low: int = 2) -> None:
        """
        Apply the common active-low DUT reset sequence.
        """

        if cycles_low < 1:
            raise ValueError(
                f"cycles_low must be at least 1, got {cycles_low}"
            )

        # The serial input is not functionally used by the register shell, but
        # driving it removes X values from traces and later assertions.
        self.dut.qspi_sio_i.value = 0

        self.dut.HRESETn.value = 0

        for _ in range(cycles_low):
            await RisingEdge(self.dut.HCLK)

        self.dut.HRESETn.value = 1
        await RisingEdge(self.dut.HCLK)

    async def wait_clock_cycles(self, cycle_count: int) -> None:
        """
        Wait for a specified number of HCLK rising edges.
        """

        if cycle_count < 0:
            raise ValueError(
                f"cycle_count cannot be negative, got {cycle_count}"
            )

        for _ in range(cycle_count):
            await RisingEdge(self.dut.HCLK)

    async def wait_for_status(
        self,
        mask: int,
        expected: int,
        *,
        max_reads: int = 100,
    ) -> int:
        """
        Poll STATUS until the selected bits match the expected value.
        """

        last_value = 0

        for _ in range(max_reads):
            last_value = await self.reg_read(
                self.reg_model.status
            )

            if (last_value & mask) == (expected & mask):
                return last_value

        raise AssertionError(
            "STATUS did not reach expected value: "
            f"mask=0x{mask:08x}, "
            f"expected=0x{expected & mask:08x}, "
            f"last=0x{last_value:08x}"
        )

    @staticmethod
    def assert_equal(
        actual: int,
        expected: int,
        description: str,
    ) -> None:
        """
        Raise a readable assertion for exact integer comparisons.
        """

        if actual != expected:
            raise AssertionError(
                f"{description}: "
                f"expected 0x{expected:08x}, "
                f"got 0x{actual:08x}"
            )

    @staticmethod
    def assert_masked_equal(
        actual: int,
        expected: int,
        mask: int,
        description: str,
    ) -> None:
        """
        Compare only the bits selected by mask.
        """

        actual_masked = actual & mask
        expected_masked = expected & mask

        if actual_masked != expected_masked:
            raise AssertionError(
                f"{description}: "
                f"mask=0x{mask:08x}, "
                f"expected=0x{expected_masked:08x}, "
                f"got=0x{actual_masked:08x}"
            )

    @staticmethod
    def _check_ahb_response(
        item: AHB3LiteSeqItem,
        *,
        expect_error: bool,
    ) -> None:
        """
        Confirm that HRESP matches the expected result.
        """

        expected_hresp = 1 if expect_error else 0

        if item.hresp != expected_hresp:
            direction = "write" if item.is_write else "read"

            raise AssertionError(
                f"Unexpected AHB {direction} response at "
                f"0x{item.addr:08x}: expected HRESP={expected_hresp}, "
                f"got HRESP={item.hresp}"
            )
