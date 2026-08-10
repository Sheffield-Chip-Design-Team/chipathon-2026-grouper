// Arbitrary-command quad QSPI engine
//
// Fixed transaction format:
//   8-bit opcode
//   24-bit address
//   8-bit data
//
// All fields use SIO[3:0], most-significant nibble first.


// FIXME - no CPHA or POL, no dummy cycles, etc...
// FIXME - There should be an arbitrary command interface that can be used to send any spi command ( look at spi review docs)

module qspi (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start,
  input  logic        dir,        // 0 = write, 1 = read
  input  logic        target,
  input  logic [7:0]  clkdiv,

  input  logic [7:0]  opcode,
  input  logic [23:0] address,
  input  logic [7:0]  write_data,

  output logic        busy,
  output logic        done,
  output logic        rx_valid,
  output logic [7:0]  read_data,

  output logic        qspi_sck_o,
  output logic [1:0]  qspi_ce_n_o,
  input  logic [3:0]  qspi_sio_i,
  output logic [3:0]  qspi_sio_o,
  output logic [3:0]  qspi_sio_oe
);

  typedef enum logic [1:0] {
    IDLE,
    TRANSFER,
    FINISH
  } state_t;

  state_t state;

  logic        dir_latched;
  logic        target_latched;
  logic [7:0]  clkdiv_latched;

  logic [39:0] tx_shift;
  logic [7:0]  rx_shift;

  logic [3:0]  nibble_count;
  logic [7:0]  divider_count;
  logic        sck_level;

  assign busy       = (state != IDLE);
  assign qspi_sck_o = sck_level;

  always_comb begin
    qspi_ce_n_o = 2'b11;
    qspi_sio_o  = tx_shift[39:36];
    qspi_sio_oe = 4'b0000;

    if (state != IDLE) begin
      qspi_ce_n_o = target_latched
          ? 2'b01
          : 2'b10;
    end

    if (state == TRANSFER) begin
      // A read releases the bus for the final two data nibbles.
      if (!(dir_latched && (nibble_count >= 4'd8))) begin
        qspi_sio_oe = 4'b1111;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state            <= IDLE;
      dir_latched      <= 1'b0;
      target_latched   <= 1'b0;
      clkdiv_latched   <= 8'h00;

      tx_shift         <= 40'h0;
      rx_shift         <= 8'h00;
      read_data        <= 8'h00;

      nibble_count     <= 4'd0;
      divider_count    <= 8'h00;
      sck_level        <= 1'b0;

      done             <= 1'b0;
      rx_valid         <= 1'b0;
    end else begin
      done     <= 1'b0;
      rx_valid <= 1'b0;

      unique case (state)
        IDLE: begin
          sck_level     <= 1'b0;
          divider_count <= 8'h00;
          nibble_count  <= 4'd0;

          if (start) begin
            dir_latched    <= dir;
            target_latched <= target;
            clkdiv_latched <= clkdiv;

            tx_shift <= {
              opcode,
              address,
              write_data
            };

            rx_shift <= 8'h00;
            state    <= TRANSFER;
          end
        end

        TRANSFER: begin
          if (divider_count == clkdiv_latched) begin
            divider_count <= 8'h00;

            if (!sck_level) begin
              // Rising edge: sample read data.
              sck_level <= 1'b1;

              if (
                dir_latched &&
                (nibble_count >= 4'd8)
              ) begin
                rx_shift <= {
                  rx_shift[3:0],
                  qspi_sio_i
                };

                if (nibble_count == 4'd9) begin
                  read_data <= {
                    rx_shift[3:0],
                    qspi_sio_i
                  };
                end
              end
            end else begin
              // Falling edge: advance to the next nibble.
              sck_level <= 1'b0;

              if (nibble_count == 4'd9) begin
                state <= FINISH;
              end else begin
                nibble_count <= nibble_count + 4'd1;
                tx_shift     <= {
                  tx_shift[35:0],
                  4'h0
                };
              end
            end
          end else begin
            divider_count <= divider_count + 8'd1;
          end
        end

        FINISH: begin
          // Hold chip select active with SCK low for one half-period.
          sck_level <= 1'b0;

          if (divider_count == clkdiv_latched) begin
            divider_count <= 8'h00;
            state         <= IDLE;
            done          <= 1'b1;

            if (dir_latched) begin
              rx_valid <= 1'b1;
            end
          end else begin
            divider_count <= divider_count + 8'd1;
          end
        end

        default: begin
          state         <= IDLE;
          sck_level     <= 1'b0;
          divider_count <= 8'h00;
        end
      endcase
    end
  end

endmodule
