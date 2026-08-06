module spi_m_rx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    spi_clk_en,

  input  logic                    enable,

  output logic                    received,

  input  logic                    flush_rx_fifo,
  input  logic                    rx_read,
  output logic                    rx_full,
  output logic                    rx_empty,
  output logic [DATA_WIDTH-1:0]   rx_data,

  input  logic                    spi_miso
);

  localparam int SHIFT_CTR_W = $clog2(DATA_WIDTH);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_RECEIVE,
    ST_FIFO_WRITE,
    ST_DONE
  } e_state;

  logic                   shift_bit;
  logic                   fifo_write;
  logic [DATA_WIDTH-1:0]  fifo_wdata;
  logic                   shift_load;
  logic                   shift_ctr_zero;
  e_state                 state;
  e_state                 next_state;
  logic                   enable_r;

  // FIFO
  small_sync_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk    (clk),
    .rst_n  (rst_n),
    .flush  (flush_rx_fifo),
    .wdata  (fifo_wdata),
    .write  (fifo_write),
    .read   (rx_read),
    .rdata  (rx_data),
    .full   (rx_full),
    .empty  (rx_empty)
  );

 
  shift_reg #(
    .WIDTH          (DATA_WIDTH),
    .LSB_FIRST      (0),
    .REGISTERED_OUT (0)
  ) u_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),
    .shift      (shift_bit),
    .load       ('0),
    .load_value ('0),
    .in         (spi_miso),
    .value_out  (fifo_wdata),
    .out        ()
  );

  
  downcounter #(
    .WIDTH(SHIFT_CTR_W)
  ) u_shift_ctr (
    .clk        (clk),
    .rst_n      (rst_n),
    .load       (shift_load),
    .enable     (shift_bit),
    .load_value (SHIFT_CTR_W'(DATA_WIDTH-1)),
    .value      (),
    .zero       (shift_ctr_zero)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      enable_r <= 1'b0;
    else if (spi_clk_en)
      enable_r <= enable;
  end

  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      state <= ST_IDLE;
    else if (enable && spi_clk_en) begin
      if (!enable_r)
        state <= ST_IDLE;
      else
        state <= next_state;
    end
  end

  
  always_comb begin
    next_state  = state;
    received    = 1'b0;
    fifo_write  = 1'b0;
    shift_load  = 1'b0;
    shift_bit   = 1'b0;

    if (enable && spi_clk_en) begin
      case (state)

        ST_IDLE: begin
          
          shift_load = 1'b1;
          if (enable)
            next_state = ST_RECEIVE;
        end

        ST_RECEIVE: begin
         
          shift_bit = 1'b1;
          
          if (shift_ctr_zero)
            next_state = ST_FIFO_WRITE;
        end

        ST_FIFO_WRITE: begin
          
          fifo_write = 1'b1;
          next_state = ST_DONE;
        end

        ST_DONE: begin
          
          received   = 1'b1;
          next_state = ST_IDLE;
        end

        default:
          next_state = ST_IDLE;

      endcase
    end
  end

endmodule