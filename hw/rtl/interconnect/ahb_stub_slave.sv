// AHB-Lite placeholder slave
//
// Stand-in for peripherals whose RTL is not yet wired into the SoC: QSPI and
// the SPI master always, the SPI slave under DRY_RUN. It occupies its slot on
// the fabric so accesses complete instead of hanging the bus, and it is sized
// and pad-connected so a PnR dry run sees something representative of the block
// that will eventually replace it. Swap the instance out for the real
// peripheral as each one lands.
//
// Two things make it representative rather than merely present:
//
//   TARGET_GE  sets how much area the stub occupies, in gate equivalents. One
//              GE is the area of one gf180mcu_fd_sc_mcu7t5v0__nand2_1 =
//              10.976 um^2, derived from the cell table in
//              librelane/classic/build.log. The intended recipe for a target is
//              (synthesized area of the block's existing RTL) x (a multiplier
//              for the features still to be built) - see
//              librelane/measure/README.md and `make measure-ge`.
//
//   pad_in /   carry the block's serial signals to and from io_ss, so the
//   pad_out /  alternate-function paths through the GPIO mux exist in the
//   pad_oe     netlist. Without them io_ss sees constants on those inputs and
//              the whole pad path constant-folds away, which flatters the
//              routing and congestion picture around the pad ring.

module ahb_stub_slave #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,

  // Area target in gate equivalents. 0 gives the smallest legal stub.
  parameter int TARGET_GE  = 0,

  // Pad-facing widths. Defaults keep the ports legal for callers that have no
  // serial signals to route; such callers can leave them unconnected.
  parameter int PAD_OUT_W  = 1,
  parameter int PAD_OE_W   = 1,
  parameter int PAD_IN_W   = 1
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // AHB Slave Interface

  // Master Signals
  /* verilator lint_off UNUSEDSIGNAL */
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,
  /* verilator lint_on UNUSEDSIGNAL */

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL,

  // Pad-facing signals, towards io_ss. Named for the direction relative to
  // this block, not relative to the pad.
  input  logic [PAD_IN_W-1:0]   pad_in,
  output logic [PAD_OUT_W-1:0]  pad_out,
  output logic [PAD_OE_W-1:0]   pad_oe
);

  import ahb3lite_pkg::*;

  // Address-phase access qualifier.
  logic access;
  assign access = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);

  // --- Sizing ----------------------------------------------------------------
  //
  // Cost model for one ballast bit, from the same build.log cell table that
  // defines the GE: one dffrnq_1 (74.637 um^2, 6.80 GE) plus its share of the
  // incrementer's carry chain and the injection XOR. GE_FIXED covers the access
  // qualifier and the two-flop error response below.
  //
  // These are a starting estimate. Because the SoC instantiates three stubs at
  // three different BALLAST_W, one synthesis run gives three points on
  //   GE = GE_FIXED + GE_PER_BIT * BALLAST_W
  // so both constants can be fitted and written back - see `make report-stub-ge`.

  localparam int GE_PER_BIT = 13;
  localparam int GE_FIXED   = 60;

  function automatic int imax(input int a, input int b);
    return (a > b) ? a : b;
  endfunction

  // Floor: wide enough to drive HRDATA, to absorb HADDR and pad_in without
  // truncating them, and to give pad_out and pad_oe taps that do not overlap.
  localparam int MIN_W     = imax(imax(DATA_WIDTH, ADDR_WIDTH),
                                  imax(PAD_IN_W, PAD_OUT_W + PAD_OE_W));
  localparam int SIZED_W   = (TARGET_GE > GE_FIXED) ? (TARGET_GE - GE_FIXED) / GE_PER_BIT : 0;
  localparam int RAW_W     = (SIZED_W > MIN_W) ? SIZED_W : MIN_W;

  // The register increments a lane at a time so its carry chain never gets
  // longer than one lane - a single adder across several hundred bits would
  // become the critical path of the whole SoC at CLOCK_PERIOD 62.5. The last
  // lane takes whatever is left over, so TARGET_GE is honoured exactly rather
  // than quantised up to the next whole lane.
  localparam int LANE_W    = 32;
  localparam int BALLAST_W = RAW_W;
  localparam int NUM_LANES = (BALLAST_W + LANE_W - 1) / LANE_W;

  // --- Ballast datapath ------------------------------------------------------
  //
  // This block has no storage, so a constant HRDATA would leave the whole write
  // path with no consumer and the read path with no real driver, and synthesis
  // would prune the slot down to tie cells. One register keeps everything live:
  //
  //   - rotate-left-by-one puts every bit in a single feedback ring, so no bit
  //     is provably constant even though only the low DATA_WIDTH bits reach
  //     HRDATA directly, and the lanes below stay coupled to each other;
  //   - the per-lane incrementers' carry chains are the bulk of the
  //     combinational area;
  //   - HADDR, HWDATA and pad_in are XOR'd in, giving every one of those bits a
  //     real endpoint.
  //
  // It is not a memory: reads do not return what was written.

  logic [BALLAST_W-1:0] ballast_q;
  logic [BALLAST_W-1:0] ballast_d;
  logic [BALLAST_W-1:0] rotated;
  logic [BALLAST_W-1:0] stimulus;

  // Everything the block observes, collected into the low bits. Written as
  // part-selects into a zeroed vector rather than width casts so the widths
  // line up whatever BALLAST_W the sizing above lands on.
  always_comb begin
    stimulus = '0;
    stimulus[PAD_IN_W-1:0] = pad_in;
    if (access)
      stimulus[ADDR_WIDTH-1:0] = stimulus[ADDR_WIDTH-1:0] ^ HADDR;
    if (access && HWRITE)
      stimulus[DATA_WIDTH-1:0] = stimulus[DATA_WIDTH-1:0] ^ HWDATA;
  end

  assign rotated = {ballast_q[BALLAST_W-2:0], ballast_q[BALLAST_W-1]};

  // A generate loop rather than a procedural one: the final lane is narrower
  // than the rest whenever BALLAST_W is not a multiple of LANE_W, and a
  // part-select's width has to be a constant.
  logic [BALLAST_W-1:0] incremented;

  for (genvar l = 0; l < NUM_LANES; l++) begin : g_lane
    localparam int LANE_LO = l * LANE_W;
    localparam int LANE_HI = ((LANE_LO + LANE_W) > BALLAST_W) ? BALLAST_W
                                                             : (LANE_LO + LANE_W);
    localparam int THIS_W  = LANE_HI - LANE_LO;

    assign incremented[LANE_LO +: THIS_W] = rotated[LANE_LO +: THIS_W] + THIS_W'(1'b1);
  end

  assign ballast_d = incremented ^ stimulus;

  always_ff @(posedge HCLK, negedge HRESETn)
    if (!HRESETn) ballast_q <= '0;
    else          ballast_q <= ballast_d;

  assign HRDATA = ballast_q[DATA_WIDTH-1:0];

  // Pad taps come off opposite ends of the register so they stay independent.
  // pad_in is data into the ballast next-state, never a clock, so routing a pad
  // clock (e.g. the SPI slave's SCK) in here creates no new clock domain.
  assign pad_out = ballast_q[PAD_OUT_W-1:0];
  assign pad_oe  = ballast_q[BALLAST_W-1 -: PAD_OE_W];

  // --- Two-cycle error response ----------------------------------------------
  //
  // Same shape as the SLVERR response in ahb_gpio_ctrl.sv: cycle one drives
  // HRESP high with HREADYOUT low, cycle two drives both high.
  //
  // The trigger is the MSB of the ballast register, sampled at the end of the
  // address phase. Sampled rather than used live because the register keeps
  // running through the stalled cycle, and AHB requires HRESP to stay asserted
  // for both cycles of the response.
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
      err_req <= access && ballast_q[BALLAST_W-1];

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) err_phase2 <= '0;
    else          err_phase2 <= err_req && !err_phase2;

  assign HREADYOUT = !(err_req && !err_phase2);
  assign HRESP     = err_req || err_phase2;

  // MIN_W already guarantees this; fail loudly if someone edits it out rather
  // than silently overlapping the two pad taps. Same idea as the NUM_GPIO
  // check in io_ss.sv.
  initial begin : check_pad_taps
    if (PAD_OUT_W + PAD_OE_W > BALLAST_W)
      $error("%m: pad_out and pad_oe taps overlap (%0d + %0d > %0d)",
             PAD_OUT_W, PAD_OE_W, BALLAST_W);
  end

endmodule
