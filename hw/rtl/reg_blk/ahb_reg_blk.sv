// AHB Register Block
module ahb_reg_blk #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int NUM_REGS   = 4
)(
  input logic                    hclk,
  input logic                    hresetn,
  // AHB Slave Interface
  input logic  [ADDR_WIDTH-1:0]  haddr,
  input logic  [2:0]             hburst,
  input logic                    hmastlock,
  input logic  [3:0]             hprot,
  input logic  [2:0]             hsize,
  input logic  [1:0]             htrans,
  input logic  [DATA_WIDTH-1:0]  hwdata,
  input logic                    hwrite,
  output logic [DATA_WIDTH-1:0]  hrdata,
  output logic                   hreadyout,
  output logic                   hresp,
  input logic                    hreadyin,
  input logic                    hsel
);

  // AHB3lite Paramaters and Types
  import ahb3lite_pkg::*;
  localparam int WORD_ADDR_BITS = $clog2(NUM_REGS);

  // Control signals
  logic                    write_enable;
  logic                    read_enable;
  logic [ADDR_WIDTH-1:0]   word_address;
  logic [DATA_WIDTH/8-1:0] byte_select;
  logic                    read_enable_r;
  logic [ADDR_WIDTH-1:0]   word_address_r;
  logic [DATA_WIDTH/8-1:0] byte_select_r;

  // Response status
  logic                    invalid_access;

  // Internal storage
  logic [DATA_WIDTH-1:0] regs [0:NUM_REGS-1]; 

//----------------------------------------------------------------------
// Address Phase
//----------------------------------------------------------------------

  // Generate the control signals 
  assign access       = hreadyin && hsel && (htrans != HTRANS_IDLE);
  assign read_enable  = access && ~hwrite;
  
  assign word_address = access ? {{(ADDR_WIDTH-WORD_ADDR_BITS){1'b0}}, 
                                 haddr[WORD_ADDR_BITS+1:2]} : '0;

  assign byte_select  = access ? generate_byte_select_32(hsize, haddr[1:0]) : '0;

  // Delay write control signals to data phase
  always_ff @(posedge hclk, negedge hresetn)
    if (~hresetn) begin
      write_enable    <= '0;
      read_enable_r   <= '0;
      word_address_r  <= '0;
      byte_select_r   <= '0;
    end else begin
      write_enable    <= access && hwrite;
      read_enable_r   <= read_enable;
      word_address_r  <= word_address;
      byte_select_r   <= byte_select;
    end

//----------------------------------------------------------------------
// Data Phase
//----------------------------------------------------------------------

  // Write data
  always_ff @(posedge hclk, negedge hresetn) begin
    if (~hresetn) begin
      for (int i = 0; i < NUM_REGS; i++) begin
        regs[i] <= '0;
      end
    end else begin
      if (write_enable) begin
        if (word_address_r < NUM_REGS) begin
          for (int i = 0; i < DATA_WIDTH/8; i++) begin
            if (byte_select_r[i]) regs[word_address_r][i*8 +: 8] <= hwdata[i*8 +: 8];
          end
        end
      end
    end
  end

  // Read data
  always_comb
    if (!read_enable_r)
      hrdata = '0;
    else begin
      if (word_address_r < NUM_REGS) begin
        hrdata = regs[word_address_r];
      end else begin
        hrdata = '0;
      end
    end
      
  // Transfer response
  always_comb begin
    invalid_access = '0;
    if (access && (word_address >= NUM_REGS)) invalid_access = 1'b1;
  end

  // AHB3lite response signals
  assign hreadyout = '1; // Single cycle Write & Read. Zero Wait state operations
  assign hresp     = invalid_access ? 1'b1 : 1'b0;
endmodule

