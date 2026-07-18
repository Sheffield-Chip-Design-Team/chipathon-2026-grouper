module small_sync_fifo #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  flush,

  input  logic [DATA_WIDTH-1:0] wdata,
  input  logic                  write,
  input  logic                  read,

  output logic [DATA_WIDTH-1:0] rdata,
  output logic                  full,
  output logic                  empty
);

  localparam int PTR_WIDTH = $clog2(FIFO_DEPTH);
  
  initial begin : check_fifo_depth
    if ((1<<PTR_WIDTH) != FIFO_DEPTH)
      $error("%m: FIFO_DEPTH must be a power of 2");
  end

  logic [PTR_WIDTH-1:0] wptr;
  logic [PTR_WIDTH-1:0] next_wptr;
  logic [PTR_WIDTH-1:0] rptr;
  logic [PTR_WIDTH-1:0] next_rptr;

  logic [FIFO_DEPTH-1:0] [DATA_WIDTH-1:0] memory;

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) begin
      memory <= '0;
      rdata <= '0;
      full <= '0;
      empty <= '1;
      wptr <= '0;
      rptr <= '0;
    end else if (flush) begin
      rdata <= '0;
      full <= '0;
      empty <= '1;
      wptr <= '0;
      rptr <= '0;
    end else begin
      wptr <= next_wptr;
      rptr <= next_rptr;
      if (read)
        rdata <= memory[rptr];
      if (write)
        memory[wptr] <= wdata;
      
      if (next_wptr == next_rptr) begin
        if (read && !write)
          empty <= '1;
        else if (write && !read)
          full <= '1;
      end else begin
        full <= '0;
        empty <= '0;
      end
    end

  always_comb begin
    /* verilator lint_off WIDTHEXPAND */
    // Don't cause wptr to go past rptr if full
    next_wptr = (write && !full) ? PTR_WIDTH'(unsigned'(wptr) + 'd1) : wptr; // Intentional overflow
    // Don't cause rptr to go past wptr if empty
    next_rptr = (read && !empty) ? PTR_WIDTH'(unsigned'(rptr) + 'd1) : rptr; // Intentional overflow
    /* verilator lint_on WIDTHEXPAND */
  end

endmodule
