
module spi_m_tx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4

) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    spi_clk_en,

  // Control signals
  input  logic                    enable,
  input  logic                    start,

  input  logic                    cpol,
  input  logic                    cpha,

  input  logic [7:0]              opcode,
  input  logic                    cmd_en,

  input  logic                    addr_en,
  input  logic [1:0]              addr_bytes,
  input  logic [31:0]             addr,


  input  logic                    data_en,
  input  logic                    dir,
  input  logic [4:0]              dummy_cycles,
  input  logic [7:0]              data_len,


  output logic                    busy,
  output logic                    done,

  input  logic                    flush_tx_fifo,
  input  logic [DATA_WIDTH-1:0]   tx_data,
  input  logic                    tx_write,
  output logic                    tx_full,
  output logic                    tx_empty,

  // SPI interface
  output logic                    spi_mosi,
  output logic                    spi_sck,
  output logic                    spi_cs_n
);

logic                             shift_load;
logic                             shift_bit;
logic                             shift_out;
logic                             shift_ctr_zero;
logic [1:0]                       addr_count;
logic [DATA_WIDTH-1:0]            shift_data;

localparam int SHIFT_CTR_W = $clog2(DATA_WIDTH);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_CMD,
    ST_ADDR,
    ST_DUMMY,
    ST_DATA,
    ST_DONE
  } e_state;

logic                    fifo_read;
logic [DATA_WIDTH-1:0]   fifo_rdata;

logic [31:0]             addr_shift;

logic [7:0]              data_count;
logic [4:0]              dummy_count;

logic                    spi_leading_edge;
logic                    spi_trailing_edge;

logic                    load_next_byte;

e_state                  state;
e_state                  next_state;
e_state                  prev_state;

  small_sync_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk    (clk),
    .rst_n  (rst_n),
    .flush  (flush_tx_fifo),
    .wdata  (tx_data),
    .write  (tx_write),
    .read   (fifo_read),
    .rdata  (fifo_rdata),
    .full   (tx_full),
    .empty  (tx_empty)
  );

  assign fifo_read = (state == ST_DATA) && shift_ctr_zero;

  shift_reg #(
    .WIDTH          (DATA_WIDTH),
    .LSB_FIRST      (0),          // SPI is MSB first
    .REGISTERED_OUT (0)
  ) u_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),
    .shift      (shift_bit),
    .load       (shift_load),
    .load_value (shift_data),
    .in         (1'b0),
    .value_out  (),
    .out        (shift_out)
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

  always_comb begin : next_state_logic

    next_state = state;
     $display("state=%0d enable=%0b start=%0b cmd_en=%0b next=%0d",
             state, enable, start, cmd_en, next_state);


    unique case (state)

      //IDLE
      ST_IDLE: begin
        if (!enable)
          next_state = ST_IDLE;
        else if (!start)
          next_state = ST_IDLE;
        else if (cmd_en)
          next_state = ST_CMD;
        else if (addr_en)
          next_state = ST_ADDR;
        else if (dummy_cycles != 0)
          next_state = ST_DUMMY;
        else if (data_en)
          next_state = ST_DATA;
        else
          next_state = ST_DONE;
      end

      //COMMAND
      ST_CMD: begin
        if (shift_ctr_zero) begin
          if (addr_en)
            next_state = ST_ADDR;
          else if (dummy_cycles != 0)
            next_state = ST_DUMMY;
          else if (data_en)
            next_state = ST_DATA;
          else
            next_state = ST_DONE;
        end
      end

      //ADDRESS
      ST_ADDR: begin
        if (shift_ctr_zero) begin
          if (addr_count < addr_bytes + 1)
            next_state = ST_ADDR;
          else if (dummy_cycles != 0)
            next_state = ST_DUMMY;
          else if (data_en)
            next_state = ST_DATA;
          else
            next_state = ST_DONE;
        end
      end

      //DUMMY
      ST_DUMMY: begin
        if (dummy_count == dummy_cycles) begin
          if (data_en)
            next_state = ST_DATA;
          else
            next_state = ST_DONE;
        end
      end

      //DATA
      ST_DATA: begin
        if ((data_count == data_len) && shift_ctr_zero)
          next_state = ST_DONE;
      end

      //DONE
      ST_DONE: begin
        next_state = ST_IDLE;
      end

      default: begin
        next_state = ST_IDLE;
      end
    endcase
  end

  always_comb begin
    shift_data = 8'h00;

    unique case (state)
      ST_CMD:
        shift_data = opcode;

      ST_ADDR:
        shift_data = addr_shift[31:24];

      ST_DATA:
        shift_data = fifo_rdata;

      default:
        shift_data = 8'h00;
    endcase
  end

  always_comb begin
    shift_load = 1'b0;

    unique case (state)
      ST_CMD:
        shift_load = (prev_state != ST_CMD);

      ST_ADDR:
        shift_load = (prev_state != ST_ADDR) || load_next_byte;

      ST_DATA:
        shift_load = (prev_state != ST_DATA) || shift_ctr_zero;

      default: ;
    endcase
  end

  assign shift_bit = cpha ? spi_leading_edge : spi_trailing_edge;

  assign spi_mosi = shift_out;

  assign spi_cs_n = (state == ST_IDLE);

  assign busy = (state != ST_IDLE);

  assign done = (state == ST_DONE);

  assign spi_leading_edge  = spi_clk_en && (spi_sck == cpol);

  assign spi_trailing_edge = spi_clk_en && (spi_sck != cpol);

  assign load_next_byte = spi_clk_en && shift_ctr_zero;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      prev_state  <= ST_IDLE;

      addr_count  <= '0;
      data_count  <= '0;
      dummy_count <= '0;

      addr_shift  <= '0;
    end else begin

      // Always update state
      prev_state <= state;
      state      <= next_state;

      // Start of a new transaction
      if (state == ST_IDLE && start) begin
        addr_count  <= 0;
        data_count  <= 0;
        dummy_count <= 0;
        addr_shift  <= addr;
      end

      // Counters only advance on SPI clock
      if (spi_clk_en) begin

        if (state == ST_ADDR && shift_ctr_zero) begin
          addr_count <= addr_count + 1;
          addr_shift <= {addr_shift[23:0], 8'h00};
        end

        if (state == ST_DUMMY)
          dummy_count <= dummy_count + 1;

        if (state == ST_DATA && shift_ctr_zero)
          data_count <= data_count + 1;

      end
    end
  end

endmodule