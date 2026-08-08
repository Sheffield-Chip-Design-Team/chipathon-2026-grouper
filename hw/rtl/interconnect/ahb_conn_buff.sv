// AHB-Lite register slice: a buffered connection between an upstream master
// port (s_*, on which this module is the slave) and a downstream slave port
// (m_*, on which this module is the master).
//
// A register stage in BOTH the request and the response direction, to break
// long combinational paths between the fabric and a physically distant slave.
// Slots that do not need one are wired straight through in
// ahb_interconnect_ss instead - a pass-through module would be pure wiring.
//
// Ports are flat AHB signal groups rather than `ahb3lite_intf` modports; see
// the note at the top of ahb_interconnect_ss.sv for why.
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
// So a transfer that takes one cycle straight through takes three here.
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
  input  logic                  hclk,
  input  logic                  hresetn,

  // Upstream port - this module is the AHB slave here
  input  logic [ADDR_WIDTH-1:0] s_HADDR,
  input  logic [2:0]            s_HBURST,
  input  logic                  s_HMASTLOCK,
  input  logic [3:0]            s_HPROT,
  input  logic [2:0]            s_HSIZE,
  input  logic [1:0]            s_HTRANS,
  input  logic [DATA_WIDTH-1:0] s_HWDATA,
  input  logic                  s_HWRITE,
  input  logic                  s_HREADYIN,
  input  logic                  s_HSEL,
  output logic [DATA_WIDTH-1:0] s_HRDATA,
  output logic                  s_HREADYOUT,
  output logic                  s_HRESP,

  // Downstream port - this module is the AHB master here
  output logic [ADDR_WIDTH-1:0] m_HADDR,
  output logic [2:0]            m_HBURST,
  output logic                  m_HMASTLOCK,
  output logic [3:0]            m_HPROT,
  output logic [2:0]            m_HSIZE,
  output logic [1:0]            m_HTRANS,
  output logic [DATA_WIDTH-1:0] m_HWDATA,
  output logic                  m_HWRITE,
  output logic                  m_HREADYIN,
  output logic                  m_HSEL,
  input  logic [DATA_WIDTH-1:0] m_HRDATA,
  input  logic                  m_HREADYOUT,
  input  logic                  m_HRESP
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
  assign accept = s_HSEL && s_HREADYIN
                  && (s_HTRANS != HTRANS_IDLE)
                  && (s_HTRANS != HTRANS_BUSY);

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
        req_addr     <= s_HADDR;
        req_burst    <= s_HBURST;
        req_mastlock <= s_HMASTLOCK;
        req_prot     <= s_HPROT;
        req_size     <= s_HSIZE;
        req_write    <= s_HWRITE;
      end

      // Upstream is in its (stalled) data phase during REQ, so HWDATA is
      // valid and held stable by the master until we release HREADYOUT.
      if (state == REQ)
        req_wdata <= s_HWDATA;

      if ((state == RESP) && m_HREADYOUT) begin
        resp_rdata <= m_HRDATA;
        resp_resp  <= m_HRESP;
      end

      unique case (state)
        IDLE: if (accept)        state <= REQ;
        REQ:  if (m_HREADYOUT)   state <= RESP;
        RESP: if (m_HREADYOUT)   state <= DONE;
        DONE:                    state <= accept ? REQ : IDLE;
      endcase
    end

  always_comb begin
    // Request path: driven from the capture registers
    m_HADDR     = req_addr;
    m_HBURST    = req_burst;
    m_HMASTLOCK = req_mastlock;
    m_HPROT     = req_prot;
    m_HSIZE     = req_size;
    m_HWRITE    = req_write;
    m_HWDATA    = req_wdata;

    m_HSEL      = (state == REQ) || (state == RESP);
    m_HTRANS    = (state == REQ) ? HTRANS_NONSEQ : HTRANS_IDLE;

    // Point-to-point downstream, so the slave's own HREADYOUT is its HREADY
    m_HREADYIN  = m_HREADYOUT;

    // Response path: driven from the capture registers, with the upstream
    // data phase held open until they hold the real response.
    s_HRDATA    = resp_rdata;

    s_HRESP     = (state == DONE) ? resp_resp : 1'b0;
    s_HREADYOUT = (state == IDLE) || (state == DONE);
  end

endmodule
