module picorv32_hello_top(
// `ifdef USE_POWER_PINS
// 	inout wire  VDD,
// 	inout wire  VSS,
// `endif
  input logic clk,
  
  input logic async_rst_n,

  // UART interface
  output logic  uart_tx,
  input  logic  uart_rx
);

  logic rst_n;

  logic         bus_error;

  logic         trap;

  // RAM Interface
  logic [9:0]   ram_addr;
  logic         ram_read;
  logic         ram_write;
  logic [31:0]  ram_wdata;
  logic [3:0]   ram_wstrb;
  logic [31:0]  ram_rdata;

  // Memory interface
  logic         mem_valid;
  logic         mem_instr;
  logic         mem_ready;
  logic [31:0]  mem_addr;
  logic [31:0]  mem_wdata;
  logic [ 3:0]  mem_wstrb;
  logic [31:0]  mem_rdata;

  // Look-Ahead Interface
  logic         mem_la_read;
  logic         mem_la_write;
  logic [31:0]  mem_la_addr;
  logic [31:0]  mem_la_wdata;
  logic [ 3:0]  mem_la_wstrb;

  // IRQ Interface
  logic [31:0]  irq_int;
  logic [31:0]  eoi;

  sync u_rst_sync (
    .clk    (clk),
    .rst_n  (async_rst_n),
    .data_i (1'b1),
    .data_o (rst_n)
  );

  picorv32 #(
	  .ENABLE_COUNTERS      (1),
	  .ENABLE_COUNTERS64    (1),
	  .ENABLE_REGS_16_31    (0),
	  .ENABLE_REGS_DUALPORT (1),
	  .LATCHED_MEM_RDATA    (0),
	  .TWO_STAGE_SHIFT      (1),
	  .BARREL_SHIFTER       (0),
	  .TWO_CYCLE_COMPARE    (0),
	  .TWO_CYCLE_ALU        (0),
	  .COMPRESSED_ISA       (1),
	  .CATCH_MISALIGN       (1),
	  .CATCH_ILLINSN        (1),
	  .ENABLE_PCPI          (0),
	  .ENABLE_MUL           (1),
	  .ENABLE_FAST_MUL      (0),
	  .ENABLE_DIV           (1),
	  .ENABLE_IRQ           (1),
	  .ENABLE_IRQ_QREGS     (1),
	  .ENABLE_IRQ_TIMER     (1),
	  .ENABLE_TRACE         (0),
	  .REGS_INIT_ZERO       (0),
	  .MASKED_IRQ           (32'h 0000_0000),
	  .LATCHED_IRQ          (32'h ffff_ffff),
	  .PROGADDR_RESET       (32'h 0000_0000),
	  .PROGADDR_IRQ         (32'h 0000_0010),
	  .STACKADDR            (32'h ffff_ffff)
  ) u_cpu (
    .clk          (clk),
    .resetn       (rst_n),
    .trap         (trap),

    // Memory interface
    .mem_valid    (mem_valid),
    .mem_instr    (mem_instr),
    .mem_ready    (mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),

	  // Look-Ahead Interface
    .mem_la_read  (mem_la_read),
    .mem_la_write (mem_la_write),
    .mem_la_addr  (mem_la_addr),
    .mem_la_wdata (mem_la_wdata),
    .mem_la_wstrb (mem_la_wstrb),

	  // Pico Co-Processor Interface (PCPI)
	  .pcpi_valid   (),
	  .pcpi_insn    (),
	  .pcpi_rs1     (),
	  .pcpi_rs2     (),
    .pcpi_wr      ('0),
    .pcpi_rd      ('0),
    .pcpi_wait    ('0),
    .pcpi_ready   ('0),

    // IRQ Interface
    .irq          (irq_int),
    .eoi          (eoi),

	  // Trace Interface
    .trace_valid  (),
    .trace_data   ()
  );

  ram_ss u_ram_ss (
    .clk        (clk),
    .rst_n      (rst_n),
    .ram_addr   (ram_addr),
    .ram_read   (ram_read),
    .ram_write  (ram_write),
    .ram_wdata  (ram_wdata),
    .ram_wstrb  (ram_wstrb),
    .ram_rdata  (ram_rdata)
  );

  assign irq_int = '0;

  assign ram_addr = mem_la_addr[9:0];
  assign ram_read = mem_la_read; // Read using look ahead to avoid delay
  assign ram_write = |mem_wstrb;
  assign ram_wdata = mem_wdata;
  assign ram_wstrb = mem_wstrb;
  assign mem_rdata = ram_rdata;
  assign mem_ready = 1'b1; // Single cycle read/write

  // Prevent cpu getting optimized away by outputting a signal
  assign uart_tx = mem_wdata[0];

endmodule
