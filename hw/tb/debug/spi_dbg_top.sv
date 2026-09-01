// SPI Slave + Debug Unit integration top, for hw/tb/debug/test_spi_dbg.py.
//
// The narrowest DUT that still contains the thing the SoC-level Debug Unit
// tests kept tripping over: the *seam* between the SPI transport
// (ahb_spi_s/spi_s_core, which frames wire commands into debug-port requests
// and shifts responses back out) and the Debug Unit (dbg_ctrl, which answers
// them). Neither block-level bench covers that seam --
// sharc:comms_ip:ahb_spi_s_directed's debug_port target drives ahb_spi_s
// against a Python DebugStub, and sharc:soc_ip:ahb_debug_unit_directed drives
// dbg_ctrl against a Python CpuStub -- so a response-phase timing bug between
// the two only ever showed up at the full SoC level, where a single run costs
// a ~90 us boot and every diagnosis loop is a rebuild.
//
// Everything below dbg_ctrl is still Python (hw/tb/debug/cpu_stub.py's
// CpuStub, driving dbg_ready/dbg_rdata/cpu_trace_*), and the AHB side of
// ahb_spi_s is tied off: firmware never configures this block in the debug
// flow, since CTRL.ENABLE resets set (GRPR-SOC-028) precisely so a debug host
// can talk to it out of reset. The SPI pins are driven directly rather than
// through io_ss's pad mux -- the pad model's own drive delay is a separate
// concern, and keeping it out of this bench is what makes the wire timing
// here unambiguous.

module spi_dbg_top (
  input  logic        clk,
  input  logic        rst_n,

  // Wire side, driven by the Python SPI master.
  input  logic        spi_s_ss,
  input  logic        spi_s_sck,
  input  logic        spi_s_mosi,
  output logic        spi_s_miso,

  // CpuStub's side of dbg_ctrl's bus request.
  output logic        dbg_own,
  output logic        dbg_req,
  output logic        dbg_write,
  output logic [31:0] dbg_addr,
  output logic [31:0] dbg_wdata,
  output logic [3:0]  dbg_wstrb,
  input  logic        dbg_ready,
  input  logic [31:0] dbg_rdata,
  input  logic        dbg_bus_error,

  // CPU control and retirement, also CpuStub's.
  output logic        cpu_freeze,
  output logic        cpu_rst_req,
  input  logic        cpu_trace_valid,
  input  logic [35:0] cpu_trace_data,

  output logic        dbg_lock_active
);

  logic        dbg_req_valid;
  logic        dbg_req_ready;
  logic [3:0]  dbg_req_cmd;
  logic [31:0] dbg_req_addr;
  logic [31:0] dbg_req_wdata;
  logic [1:0]  dbg_req_size;
  logic        dbg_rsp_valid;
  logic        dbg_rsp_ready;
  logic [31:0] dbg_rsp_rdata;
  logic        dbg_rsp_err;

  ahb_spi_s #(
    .DEBUG_PORT_EN (1)
  ) u_spi_s (
    .HCLK          (clk),
    .HRESETn       (rst_n),

    // AHB tied off: this bench never configures the block over AHB.
    .HADDR         (32'b0),
    .HBURST        (3'b0),
    .HMASTLOCK     (1'b0),
    .HPROT         (4'b0),
    .HSIZE         (3'b010),
    .HTRANS        (2'b00),
    .HWDATA        (32'b0),
    .HWRITE        (1'b0),
    .HRDATA        (),
    .HREADYOUT     (),
    .HRESP         (),
    .HREADYIN      (1'b1),
    .HSEL          (1'b0),

    .spi_s_ss        (spi_s_ss),
    .spi_s_sck       (spi_s_sck),
    .spi_s_mosi      (spi_s_mosi),
    .spi_s_miso      (spi_s_miso),

    .dbg_req_valid (dbg_req_valid),
    .dbg_req_ready (dbg_req_ready),
    .dbg_req_cmd   (dbg_req_cmd),
    .dbg_req_addr  (dbg_req_addr),
    .dbg_req_wdata (dbg_req_wdata),
    .dbg_req_size  (dbg_req_size),
    .dbg_rsp_valid (dbg_rsp_valid),
    .dbg_rsp_ready (dbg_rsp_ready),
    .dbg_rsp_rdata (dbg_rsp_rdata),
    .dbg_rsp_err   (dbg_rsp_err),

    .irq           ()
  );

  dbg_ctrl u_dbg_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),

    .dbg_req_valid   (dbg_req_valid),
    .dbg_req_ready   (dbg_req_ready),
    .dbg_req_cmd     (dbg_req_cmd),
    .dbg_req_addr    (dbg_req_addr),
    .dbg_req_wdata   (dbg_req_wdata),
    .dbg_req_size    (dbg_req_size),
    .dbg_rsp_valid   (dbg_rsp_valid),
    .dbg_rsp_ready   (dbg_rsp_ready),
    .dbg_rsp_rdata   (dbg_rsp_rdata),
    .dbg_rsp_err     (dbg_rsp_err),

    .dbg_lock_active (dbg_lock_active),

    .dbg_own         (dbg_own),
    .dbg_req         (dbg_req),
    .dbg_write       (dbg_write),
    .dbg_addr        (dbg_addr),
    .dbg_wdata       (dbg_wdata),
    .dbg_wstrb       (dbg_wstrb),
    .dbg_ready       (dbg_ready),
    .dbg_rdata       (dbg_rdata),
    .dbg_bus_error   (dbg_bus_error),

    .cpu_freeze      (cpu_freeze),
    .cpu_rst_req     (cpu_rst_req),
    .cpu_trace_valid (cpu_trace_valid),
    .cpu_trace_data  (cpu_trace_data)
  );

endmodule
