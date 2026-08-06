// For connecting two ahb3lite interfaces together (with a buffer)
// Useful for putting interfaces into an array
//
// Same role as ahb_conn, but with a register stage in BOTH the request and
// the response direction, to break long combinational paths between the
// fabric and a physically distant slave.
//
// AHB has no way to simply "add latency": the data phase is one cycle wide
// unless the slave stretches it, so a plain register slice makes the
// response arrive two cycles after the master already sampled the bus. The
// only protocol-legal way to buy those cycles is to hold the data phase
// open, so this module keeps HREADYOUT low upstream until the buffered
// response has actually arrived.
//
// Read from a zero-wait-state slave:
//
//   cycle 0  upstream address phase     capture addr/ctrl   HREADYOUT 1
//   cycle 1  downstream address phase   capture HWDATA      HREADYOUT 0
//   cycle 2  downstream data phase      capture HRDATA      HREADYOUT 0
//   cycle 3  upstream data phase        HRDATA presented    HREADYOUT 1
//
// So a transfer that takes one cycle through ahb_conn takes three here.
// That is the cost of the register stage, not a bug.
//
// The response must be captured in exactly the downstream data-phase cycle:
// ahb_rom/ahb_ram drive read_enable from ~HWRITE without qualifying it with
// access, so their HRDATA is overwritten (with memory[0]) the cycle after.
//
// Bursts are issued downstream as a series of NONSEQ singles. Nothing in
// this SoC issues bursts today (picorv32 only does NONSEQ).

module ahb_conn_buff #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic          hclk,
  input logic          hresetn,
  ahb3lite_intf.master ahb_m,
  ahb3lite_intf.slave  ahb_s
);

  import ahb3lite_pkg::*;

  typedef enum logic [1:0] {
    IDLE,  // nothing in flight, able to accept an address phase
    REQ,   // presenting the address phase downstream
    RESP,  // downstream data phase, response being captured
    DONE   // presenting the buffered response upstream
  } state_t;

  state_t state;

  // Captured request (upstream address phase)
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [2:0]            req_burst;
  logic                  req_mastlock;
  logic [3:0]            req_prot;
  logic [2:0]            req_size;
  logic                  req_write;
  logic [DATA_WIDTH-1:0] req_wdata;

  // Captured response (downstream data phase)
  logic [DATA_WIDTH-1:0] resp_rdata;
  logic                  resp_resp;

  // A new upstream transfer is being presented this cycle
  logic accept;
  assign accept = ahb_s.HSEL && ahb_s.HREADYIN
                  && (ahb_s.HTRANS != HTRANS_IDLE)
                  && (ahb_s.HTRANS != HTRANS_BUSY);

  // Only IDLE and DONE drive HREADYOUT high, so those are the only states
  // in which an upstream address phase can complete.
  logic capture_req;
  assign capture_req = ((state == IDLE) || (state == DONE)) && accept;

  always_ff @(posedge hclk or negedge hresetn)
    if (~hresetn) begin
      state        <= IDLE;
      req_addr     <= '0;
      req_burst    <= '0;
      req_mastlock <= '0;
      req_prot     <= '0;
      req_size     <= '0;
      req_write    <= '0;
      req_wdata    <= '0;
      resp_rdata   <= '0;
      resp_resp    <= '0;
    end else begin
      if (capture_req) begin
        req_addr     <= ahb_s.HADDR;
        req_burst    <= ahb_s.HBURST;
        req_mastlock <= ahb_s.HMASTLOCK;
        req_prot     <= ahb_s.HPROT;
        req_size     <= ahb_s.HSIZE;
        req_write    <= ahb_s.HWRITE;
      end

      // Upstream is in its (stalled) data phase during REQ, so HWDATA is
      // valid and held stable by the master until we release HREADYOUT.
      if (state == REQ)
        req_wdata <= ahb_s.HWDATA;

      if ((state == RESP) && ahb_m.HREADYOUT) begin
        resp_rdata <= ahb_m.HRDATA;
        resp_resp  <= ahb_m.HRESP;
      end

      unique case (state)
        IDLE: if (accept)          state <= REQ;
        REQ:  if (ahb_m.HREADYOUT) state <= RESP;
        RESP: if (ahb_m.HREADYOUT) state <= DONE;
        DONE:                      state <= accept ? REQ : IDLE;
      endcase
    end

  always_comb begin
    // Request path: driven from the capture registers
    ahb_m.HADDR     = req_addr;
    ahb_m.HBURST    = req_burst;
    ahb_m.HMASTLOCK = req_mastlock;
    ahb_m.HPROT     = req_prot;
    ahb_m.HSIZE     = req_size;
    ahb_m.HWRITE    = req_write;
    ahb_m.HWDATA    = req_wdata;

    ahb_m.HSEL      = (state == REQ) || (state == RESP);
    ahb_m.HTRANS    = (state == REQ) ? HTRANS_NONSEQ : HTRANS_IDLE;

    // Point-to-point downstream, so the slave's own HREADYOUT is its HREADY
    ahb_m.HREADYIN  = ahb_m.HREADYOUT;

    // Response path: driven from the capture registers, with the upstream
    // data phase held open until they hold the real response.
    ahb_s.HRDATA    = resp_rdata;

    ahb_s.HRESP     = (state == DONE) ? resp_resp : 1'b0;
    ahb_s.HREADYOUT = (state == IDLE) || (state == DONE);
  end

endmodule
