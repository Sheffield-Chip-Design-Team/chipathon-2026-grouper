from ..qspi_reg_model import (
    ADDR_OFFSET,
    CMD_OFFSET,
    CTRL_OFFSET,
    DATA_OFFSET,
    STATUS_OFFSET,
)
from .qspi_ahb_base_sequence import (
    ADDR_IMPLEMENTED_MASK,
    CMD_ADDR_EN,
    CMD_DATA_EN,
    CMD_DIR,
    CMD_DUMMY_SHIFT,
    CMD_FAST_TXN_EN,
    CMD_START,
    CMD_STORED_MASK,
    CMD_TARGET,
    CTRL_CPHA,
    CTRL_FLASH_WRITE_EN,
    CTRL_IE_ERR,
    CTRL_IMPLEMENTED_MASK,
    DATA_IMPLEMENTED_MASK,
    HSIZE_HALFWORD,
    HSIZE_WORD,
    HTRANS_BUSY,
    QspiAhbBaseSequence,
    STATUS_ADDR_ERR,
    STATUS_IMPLEMENTED_MASK,
    STATUS_W1C_MASK,
    STATUS_WRITE_BLOCKED,
)


class QspiRegisterShellSequence(QspiAhbBaseSequence):
    """
    Directed verification of the AHB-facing QSPI register shell.

    The serial transaction engine is not implemented yet, so this sequence
    verifies only behaviour that the current milestone can genuinely produce:

    - reset state;
    - full-word and byte-lane register writes;
    - reserved-bit behaviour;
    - START action/readback semantics;
    - PSRAM and NOR address validation;
    - NOR write protection;
    - W1C status handling;
    - error interrupt generation;
    - invalid AHB accesses;
    - safe inactive external QSPI outputs.
    """

    async def body(self):
        self.get_config()

        self.sequencer.logger.info(
            f"Starting {self.get_name()}"
        )

        await self._check_reset_state()
        await self._check_full_word_accesses()
        await self._check_byte_lane_accesses()
        await self._check_start_and_error_behaviour()
        await self._check_invalid_ahb_accesses()

        self.sequencer.logger.info(
            f"{self.get_name()} passed"
        )

    async def _check_reset_state(self):
        self.sequencer.logger.info(
            "Checking register and external-interface reset state"
        )

        await self.reset_dut()

        ctrl = await self.reg_read(self.reg_model.ctrl)
        cmd = await self.reg_read(self.reg_model.cmd)
        status = await self.reg_read(self.reg_model.status)
        addr = await self.reg_read(self.reg_model.addr)
        data = await self.reg_read(self.reg_model.data)

        self.assert_equal(ctrl, 0, "CTRL reset value")
        self.assert_equal(cmd, 0, "CMD reset value")
        self.assert_equal(status, 0, "STATUS reset value")
        self.assert_equal(addr, 0, "ADDR reset value")
        self.assert_equal(data, 0, "DATA reset value")

        self.assert_equal(
            int(self.dut.qspi_sck_o.value),
            0,
            "QSPI SCK reset level",
        )
        self.assert_equal(
            int(self.dut.qspi_ce_n_o.value),
            0b11,
            "QSPI chip-enable reset state",
        )
        self.assert_equal(
            int(self.dut.qspi_sio_o.value),
            0,
            "QSPI output-data reset state",
        )
        self.assert_equal(
            int(self.dut.qspi_sio_oe.value),
            0,
            "QSPI output-enable reset state",
        )
        self.assert_equal(
            int(self.dut.irq.value),
            0,
            "IRQ reset state",
        )

    async def _check_full_word_accesses(self):
        self.sequencer.logger.info(
            "Checking full-word register writes and reserved bits"
        )

        await self.reset_dut()

        # Exercise the pyuvm register-model frontdoor path first.
        ctrl_value = (
            CTRL_CPHA
            | (1 << 2)
            | (0x3C << 8)
        )

        await self.reg_write(
            self.reg_model.ctrl,
            ctrl_value,
        )

        ctrl = await self.reg_read(
            self.reg_model.ctrl
        )

        self.assert_equal(
            ctrl,
            ctrl_value,
            "CTRL register-model write/readback",
        )

        # Write every bit through raw AHB. Only implemented fields may persist.
        await self.ahb_write(
            CTRL_OFFSET,
            0xFFFF_FFFF,
        )

        ctrl = await self.reg_read(
            self.reg_model.ctrl
        )

        self.assert_equal(
            ctrl,
            CTRL_IMPLEMENTED_MASK,
            "CTRL implemented-bit mask",
        )

        # CPOL is now one, so the safely inactive SCK output must idle high.
        self.assert_equal(
            int(self.dut.qspi_sck_o.value),
            1,
            "SCK follows CTRL.CPOL while idle",
        )
        self.assert_equal(
            int(self.dut.qspi_ce_n_o.value),
            0b11,
            "Chip enables remain inactive",
        )
        self.assert_equal(
            int(self.dut.qspi_sio_oe.value),
            0,
            "SIO outputs remain disabled",
        )

        # START is deliberately kept zero here. All other CMD and reserved
        # bits are written high.
        await self.ahb_write(
            CMD_OFFSET,
            0xFFFF_FF3E,
        )

        cmd = await self.reg_read(
            self.reg_model.cmd
        )

        self.assert_equal(
            cmd,
            CMD_STORED_MASK,
            "CMD implemented-bit mask",
        )

        await self.ahb_write(
            ADDR_OFFSET,
            0xFFFF_FFFF,
        )

        addr = await self.reg_read(
            self.reg_model.addr
        )

        self.assert_equal(
            addr,
            ADDR_IMPLEMENTED_MASK,
            "ADDR 24-bit storage",
        )

        await self.ahb_write(
            DATA_OFFSET,
            0xFFFF_FFA5,
        )

        data = await self.reg_read(
            self.reg_model.data
        )

        self.assert_equal(
            data,
            0xA5,
            "DATA 8-bit storage",
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_equal(
            status & ~STATUS_IMPLEMENTED_MASK,
            0,
            "STATUS reserved bits",
        )

    async def _check_byte_lane_accesses(self):
        self.sequencer.logger.info(
            "Checking byte-aligned register fields and reserved lanes"
        )

        await self.reset_dut()

        # CTRL byte zero contains mode/control fields.
        await self.ahb_write_byte(
            CTRL_OFFSET,
            0,
            0x2D,
        )

        # CTRL byte one contains the complete CLKDIV field.
        await self.ahb_write_byte(
            CTRL_OFFSET,
            1,
            0xA6,
        )

        # Upper bytes are reserved and must not change the register.
        await self.ahb_write_byte(
            CTRL_OFFSET,
            2,
            0xFF,
        )
        await self.ahb_write_byte(
            CTRL_OFFSET,
            3,
            0xFF,
        )

        ctrl = await self.reg_read(
            self.reg_model.ctrl
        )

        self.assert_equal(
            ctrl,
            0x0000_A62D,
            "CTRL byte-lane composition",
        )

        self.assert_equal(
            await self.ahb_read_byte(CTRL_OFFSET, 0),
            0x2D,
            "CTRL byte zero readback",
        )
        self.assert_equal(
            await self.ahb_read_byte(CTRL_OFFSET, 1),
            0xA6,
            "CTRL byte one readback",
        )
        self.assert_equal(
            await self.ahb_read_byte(CTRL_OFFSET, 2),
            0,
            "CTRL reserved byte two",
        )
        self.assert_equal(
            await self.ahb_read_byte(CTRL_OFFSET, 3),
            0,
            "CTRL reserved byte three",
        )

        # CMD byte zero contains the transaction descriptor. START remains zero.
        await self.ahb_write_byte(
            CMD_OFFSET,
            0,
            0x3E,
        )

        # DUMMY occupies the complete byte [15:8].
        await self.ahb_write_byte(
            CMD_OFFSET,
            1,
            0x5A,
        )

        await self.ahb_write_byte(
            CMD_OFFSET,
            2,
            0xFF,
        )
        await self.ahb_write_byte(
            CMD_OFFSET,
            3,
            0xFF,
        )

        cmd = await self.reg_read(
            self.reg_model.cmd
        )

        self.assert_equal(
            cmd,
            0x0000_5A3E,
            "CMD byte-lane composition",
        )

        # ADDR stores exactly three bytes. Lane three is reserved.
        await self.ahb_write_byte(
            ADDR_OFFSET,
            0,
            0x11,
        )
        await self.ahb_write_byte(
            ADDR_OFFSET,
            1,
            0x22,
        )
        await self.ahb_write_byte(
            ADDR_OFFSET,
            2,
            0x33,
        )
        await self.ahb_write_byte(
            ADDR_OFFSET,
            3,
            0xFF,
        )

        addr = await self.reg_read(
            self.reg_model.addr
        )

        self.assert_equal(
            addr,
            0x0033_2211,
            "ADDR byte-lane composition",
        )

        # Only DATA byte zero is implemented.
        await self.ahb_write_byte(
            DATA_OFFSET,
            0,
            0xC7,
        )
        await self.ahb_write_byte(
            DATA_OFFSET,
            1,
            0xFF,
        )

        data = await self.reg_read(
            self.reg_model.data
        )

        self.assert_equal(
            data,
            DATA_IMPLEMENTED_MASK & 0xC7,
            "DATA byte-lane behaviour",
        )

    async def _check_start_and_error_behaviour(self):
        self.sequencer.logger.info(
            "Checking START, protection errors, address errors, W1C and IRQ"
        )

        await self.reset_dut()

        # ------------------------------------------------------------------
        # Valid PSRAM read request
        # ------------------------------------------------------------------

        await self.ahb_write(
            ADDR_OFFSET,
            0x0012_3456,
        )

        valid_psram_read = (
            CMD_START
            | CMD_DIR
            | CMD_ADDR_EN
            | CMD_DATA_EN
            | CMD_FAST_TXN_EN
            | (0x04 << CMD_DUMMY_SHIFT)
        )

        await self.ahb_write(
            CMD_OFFSET,
            valid_psram_read,
        )

        cmd = await self.reg_read(
            self.reg_model.cmd
        )

        self.assert_equal(
            cmd,
            valid_psram_read & CMD_STORED_MASK,
            "START reads zero while descriptor persists",
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_equal(
            status,
            0,
            "Valid PSRAM request creates no wrapper error",
        )

        # ------------------------------------------------------------------
        # Simultaneous protected-write and address-range errors
        # ------------------------------------------------------------------

        await self.reset_dut()

        # Enable error IRQs, but leave FLASH_WRITE_EN clear.
        await self.reg_write(
            self.reg_model.ctrl,
            CTRL_IE_ERR,
        )

        # 0x400000 is one byte beyond the 4 MB NOR range.
        await self.ahb_write(
            ADDR_OFFSET,
            0x0040_0000,
        )

        invalid_nor_write = (
            CMD_START
            | CMD_ADDR_EN
            | CMD_DATA_EN
            | CMD_TARGET
        )

        await self.ahb_write(
            CMD_OFFSET,
            invalid_nor_write,
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        expected_errors = (
            STATUS_WRITE_BLOCKED
            | STATUS_ADDR_ERR
        )

        self.assert_masked_equal(
            status,
            expected_errors,
            STATUS_W1C_MASK,
            "Combined NOR write/address errors",
        )

        self.assert_equal(
            int(self.dut.irq.value),
            1,
            "Error interrupt assertion",
        )

        # Selectively clear WRITE_BLOCKED. ADDR_ERR must remain asserted.
        await self.ahb_write(
            STATUS_OFFSET,
            STATUS_WRITE_BLOCKED,
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_masked_equal(
            status,
            STATUS_ADDR_ERR,
            STATUS_W1C_MASK,
            "Selective W1C clear",
        )

        self.assert_equal(
            int(self.dut.irq.value),
            1,
            "IRQ remains asserted while ADDR_ERR remains",
        )

        await self.ahb_write(
            STATUS_OFFSET,
            STATUS_ADDR_ERR,
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_equal(
            status & STATUS_W1C_MASK,
            0,
            "All error status cleared",
        )

        self.assert_equal(
            int(self.dut.irq.value),
            0,
            "IRQ deasserts after all enabled errors clear",
        )

        # ------------------------------------------------------------------
        # Enabled, in-range NOR write
        # ------------------------------------------------------------------

        await self.reg_write(
            self.reg_model.ctrl,
            CTRL_IE_ERR | CTRL_FLASH_WRITE_EN,
        )

        await self.ahb_write(
            ADDR_OFFSET,
            0x003F_FFFF,
        )

        await self.ahb_write(
            CMD_OFFSET,
            invalid_nor_write,
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_equal(
            status & STATUS_W1C_MASK,
            0,
            "Enabled in-range NOR write creates no wrapper error",
        )

        self.assert_equal(
            int(self.dut.irq.value),
            0,
            "No IRQ for enabled in-range NOR write",
        )

        # ------------------------------------------------------------------
        # PSRAM boundary checking
        # ------------------------------------------------------------------

        await self.reg_write(
            self.reg_model.ctrl,
            CTRL_IE_ERR,
        )

        # Bit 23 set is outside the 8 MB PSRAM range.
        await self.ahb_write(
            ADDR_OFFSET,
            0x0080_0000,
        )

        psram_read = (
            CMD_START
            | CMD_DIR
            | CMD_ADDR_EN
        )

        await self.ahb_write(
            CMD_OFFSET,
            psram_read,
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_masked_equal(
            status,
            STATUS_ADDR_ERR,
            STATUS_ADDR_ERR,
            "Out-of-range PSRAM address",
        )

        self.assert_equal(
            int(self.dut.irq.value),
            1,
            "PSRAM address-error IRQ",
        )

        await self.ahb_write(
            STATUS_OFFSET,
            STATUS_ADDR_ERR,
        )

        # Highest valid PSRAM byte address.
        await self.ahb_write(
            ADDR_OFFSET,
            0x007F_FFFF,
        )

        await self.ahb_write(
            CMD_OFFSET,
            psram_read,
        )

        status = await self.reg_read(
            self.reg_model.status
        )

        self.assert_equal(
            status & STATUS_ADDR_ERR,
            0,
            "Highest valid PSRAM address",
        )

        self.assert_equal(
            int(self.dut.irq.value),
            0,
            "No IRQ for valid PSRAM boundary address",
        )

    async def _check_invalid_ahb_accesses(self):
        self.sequencer.logger.info(
            "Checking invalid offsets, alignment, sizes and HTRANS=BUSY"
        )

        await self.reset_dut()

        await self.reg_write(
            self.reg_model.ctrl,
            CTRL_CPHA,
        )

        # First word after DATA is unimplemented.
        await self.ahb_write(
            0x14,
            0xFFFF_FFFF,
            expect_error=True,
        )

        ctrl = await self.reg_read(
            self.reg_model.ctrl
        )

        self.assert_equal(
            ctrl,
            CTRL_CPHA,
            "Invalid-offset write must not modify CTRL",
        )

        # A higher offset with the same low word-address bits must not alias.
        invalid_read = await self.ahb_read(
            0x20,
            expect_error=True,
        )

        self.assert_equal(
            invalid_read.rdata,
            0,
            "Invalid-offset read data",
        )

        # Misaligned halfword.
        await self.ahb_read(
            CTRL_OFFSET + 1,
            size=HSIZE_HALFWORD,
            expect_error=True,
        )

        # Misaligned word.
        await self.ahb_write(
            CTRL_OFFSET + 2,
            0,
            size=HSIZE_WORD,
            expect_error=True,
        )

        # Unsupported transfer width.
        await self.ahb_read(
            CTRL_OFFSET,
            size=0b011,
            expect_error=True,
        )

        # BUSY is not a real transfer and must neither error nor write.
        await self.ahb_write(
            CTRL_OFFSET,
            0,
            trans=HTRANS_BUSY,
        )

        ctrl = await self.reg_read(
            self.reg_model.ctrl
        )

        self.assert_equal(
            ctrl,
            CTRL_CPHA,
            "HTRANS=BUSY must not modify the register",
        )