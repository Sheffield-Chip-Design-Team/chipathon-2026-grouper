// AHB-Lite placeholder slave
//
// Stand-in for peripherals that don't have RTL yet (SPI Master, QSPI,
// GPIO Mux, and the reserved External Peripheral window). It occupies its
// slot on the fabric so accesses complete instead of hanging the bus, and
// flags every access as an error (HRESP) so software notices it hit an
// unimplemented block. Swap the instance out for the real peripheral as
// each one lands.

module ahb_stub_slave #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // AHB Slave Interface

  // Master Signals
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL
);

  import ahb3lite_pkg::*;

  // Address-phase access qualifier.
  logic access;
  assign access = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);

  // --- Data-path counters ----------------------------------------------------
  //
  // The same idea as the DRY_RUN placeholder in ahb_ram.sv: this block has no
  // storage, so a constant HRDATA leaves the whole write path with no consumer
  // and the read path with no real driver, and synthesis prunes the slot down
  // to tie cells. Two counters keep both live:
  //
  //   wdata_cnt  loads the bus write data on a write, free-runs otherwise, so
  //              every HWDATA bit reaches a real endpoint.
  //   rdata_cnt  free-runs, and mixes in wdata_cnt on a read, so HRDATA has a
  //              real driver that depends on traffic the block has seen.
  //
  // Neither is a memory: reads do not return what was written.

  logic [DATA_WIDTH-1:0] wdata_cnt;
  logic [DATA_WIDTH-1:0] rdata_cnt;

  always_ff @(posedge HCLK, negedge HRESETn)
    if (!HRESETn) begin
      wdata_cnt <= '0;
      rdata_cnt <= '0;
    end else begin
      wdata_cnt <= (access &&  HWRITE) ? HWDATA                : wdata_cnt + 1'b1;
      rdata_cnt <= (access && !HWRITE) ? (rdata_cnt ^ wdata_cnt) : rdata_cnt + 1'b1;
    end

  assign HRDATA = rdata_cnt;

  // --- Two-cycle error response ----------------------------------------------
  //
  // Same shape as the SLVERR response in ahb_gpio_ctrl.sv: cycle one drives
  // HRESP high with HREADYOUT low, cycle two drives both high.
  //
  // The trigger is the MSB of wdata_cnt, sampled at the end of the address
  // phase. Sampled rather than used live because the counters keep running
  // through the stalled cycle, and AHB requires HRESP to stay asserted for
  // both cycles of the response.
  //
  // NOTE: this is a behavioural change from "every access to an unimplemented
  // block is an error". Roughly half of all accesses now complete with OKAY,
  // so software can no longer rely on HRESP to detect that it hit a stub.

  logic err_req;
  logic err_phase2;

  always_ff @(posedge HCLK, negedge HRESETn)
    if (!HRESETn)
      err_req <= '0;
    else if (HREADYOUT)   // hold the trigger for the whole response
      err_req <= access && wdata_cnt[DATA_WIDTH-1];

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) err_phase2 <= '0;
    else          err_phase2 <= err_req && !err_phase2;

  assign HREADYOUT = !(err_req && !err_phase2);
  assign HRESP     = err_req || err_phase2;

endmodule
