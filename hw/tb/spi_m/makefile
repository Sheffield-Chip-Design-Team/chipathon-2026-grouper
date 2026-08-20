

SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(PWD)/../ahb3lite/ahb3lite_pkg.sv \
                  $(PWD)/spi_m_core.sv \
                  $(PWD)/spi_tx.sv \
                  $(PWD)/spi_rx.sv \
                  $(PWD)/spi_clk_div.sv \
                  $(PWD)/downcounter.sv \
                  $(PWD)/shift_reg.sv \
                  $(PWD)/small_sync_fifo.sv \
                  $(PWD)/ahb_spi_master.sv

COCOTB_TOPLEVEL = ahb_spi_master
COCOTB_TEST_MODULES = test_ahb_spi_master

include $(shell cocotb-config --makefiles)/Makefile.sim
