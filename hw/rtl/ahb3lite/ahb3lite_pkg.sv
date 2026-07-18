package ahb3lite_pkg;

  // verilator lint_off UNUSEDPARAM
  
  localparam bit [1:0] HTRANS_IDLE    = 2'b00;
  localparam bit [1:0] HTRANS_BUSY    = 2'b01;
  localparam bit [1:0] HTRANS_NONSEQ  = 2'b10;
  localparam bit [1:0] HTRANS_SEQ     = 2'b11;
  
  // decode byte select signals from the size and the lowest two address bits
  function logic [3:0] generate_byte_select_32(logic [2:0] hsize, logic [1:0] byte_address);
    logic [3:0] bsel;
    unique case (hsize)
      3'b000: begin // Byte
        bsel = 4'b0001 << byte_address;
      end
      3'b001: begin // Halfword
        bsel = 4'b0011 << {byte_address[1], 1'b0}; // Must be halfword aligned
      end
      3'b010: begin // Word
        bsel = 4'b1111;
      end
      default: begin // Treat anything else as undefined
        bsel = 4'bXXXX;
      end
    endcase
    return bsel;
  endfunction

  // verilator lint_on UNUSEDPARAM
  
endpackage
