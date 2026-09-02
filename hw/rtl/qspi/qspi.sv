// Arbitrary-command SPI/QPI transaction engine
//
// Supported transfer phases:
//   COMMAND -> optional ADDRESS -> optional DUMMY -> optional DATA
//
// Supported serial modes:
//   QUAD_MODE = 0: single-bit SPI (TX on SIO0, RX on SIO1)
//   QUAD_MODE = 1: four-bit QPI (SIO[3:0])
//
// Supported clock modes:
//   mode 0: CPOL=0, CPHA=0
//   mode 3: CPOL=1, CPHA=1
//
// The AHB wrapper rejects unsupported CPOL/CPHA combinations before START.

module qspi (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start,
  input  logic        dir,        // DATA direction only: 0=write, 1=read
  input  logic        addr_en,
  input  logic        data_en,
  input  logic        target,     // 0=PSRAM, 1=NOR
  input  logic        quad_mode,
  input  logic        cpol,
  input  logic        cpha,
  input  logic [7:0]  clkdiv,
  input  logic [7:0]  dummy,
  input  logic [7:0]  opcode,
  input  logic [23:0] address,
  input  logic [31:0] write_data,

  // Streaming DATA continuation. These controls are intentionally internal
  // to the serial engine at this stage; the existing AHB manual interface
  // keeps stream_enable low until the memory-mapped path is added later.
  input  logic        stream_enable,
  input  logic        stream_next,
  input  logic        stream_stop,
  input  logic [31:0] stream_write_data,

  output logic        busy,
  output logic        done,
  output logic        rx_valid,
  output logic        word_done,
  output logic [31:0] read_data,

  output logic        qspi_sck_o,
  output logic [1:0]  qspi_ce_n_o,
  input  logic [3:0]  qspi_sio_i,
  output logic [3:0]  qspi_sio_o,
  output logic [3:0]  qspi_sio_oe
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_COMMAND,
    ST_ADDRESS,
    ST_DUMMY,
    ST_DATA,
    ST_STREAM_WAIT,
    ST_FINISH,
    ST_CS_HIGH
  } state_t;

  state_t state;

  logic        dir_latched;
  logic        addr_en_latched;
  logic        data_en_latched;
  logic        target_latched;
  logic        quad_mode_latched;
  logic        cpol_latched;
  logic        cpha_latched;
  logic        stream_latched;
  logic [7:0]  clkdiv_latched;
  logic [7:0]  dummy_latched;
  logic [31:0] write_data_latched;
  logic [23:0] address_latched;

  logic [31:0] shift_reg;
  logic [31:0] rx_shift;
  logic [5:0]  phase_count;
  logic [7:0]  dummy_count;
  logic [7:0]  divider_count;
  logic        sck_level;
  logic        cs_high_half;

  logic       half_period_tick;
  logic [5:0] phase_last;

  // AHB uses byte lane 0 for the lowest byte address. Sequential QSPI memory
  // traffic therefore sends byte lane 0 first while preserving MSB-first
  // serial order within each byte.
  function automatic logic [31:0] byte_swap32(input logic [31:0] value);
    byte_swap32 = {value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  assign busy = (state != ST_IDLE);

  // While idle, SCK follows the configured polarity. During a transaction,
  // the polarity latched at START is used.
  assign qspi_sck_o = (state == ST_IDLE) ? cpol : sck_level;
  assign half_period_tick = (divider_count == clkdiv_latched);

  always_comb begin
    unique case (state)
      ST_COMMAND: phase_last = quad_mode_latched ? 6'd1 : 6'd7;
      ST_ADDRESS: phase_last = quad_mode_latched ? 6'd5 : 6'd23;
      ST_DATA:    phase_last = quad_mode_latched ? 6'd7 : 6'd31;
      default:    phase_last = 6'd0;
    endcase
  end

  // External bus drive
  always_comb begin
    qspi_ce_n_o = 2'b11;
    qspi_sio_o  = 4'b0000;
    qspi_sio_oe = 4'b0000;

    if ((state == ST_COMMAND) || (state == ST_ADDRESS) || (state == ST_DUMMY) || (state == ST_DATA) || (state == ST_STREAM_WAIT) || (state == ST_FINISH)) begin
      qspi_ce_n_o = target_latched ? 2'b01 : 2'b10;
    end

    if ((state == ST_COMMAND) || (state == ST_ADDRESS) || ((state == ST_DATA) && !dir_latched)) begin
      if (quad_mode_latched) begin
        qspi_sio_o  = shift_reg[31:28];
        qspi_sio_oe = 4'b1111;
      end else begin
        qspi_sio_o[0]  = shift_reg[31];
        qspi_sio_oe[0] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state              <= ST_IDLE;
      dir_latched        <= 1'b0;
      addr_en_latched    <= 1'b0;
      data_en_latched    <= 1'b0;
      target_latched     <= 1'b0;
      quad_mode_latched  <= 1'b0;
      cpol_latched       <= 1'b0;
      cpha_latched       <= 1'b0;
      stream_latched     <= 1'b0;
      clkdiv_latched     <= 8'h00;
      dummy_latched      <= 8'h00;
      write_data_latched <= 32'h0000_0000;
      address_latched    <= 24'h000000;

      shift_reg          <= 32'h0000_0000;
      rx_shift           <= 32'h0000_0000;
      read_data          <= 32'h0000_0000;

      phase_count        <= 6'd0;
      dummy_count        <= 8'h00;
      divider_count      <= 8'h00;

      sck_level          <= 1'b0;
      cs_high_half       <= 1'b0;

      done               <= 1'b0;
      rx_valid           <= 1'b0;
      word_done          <= 1'b0;
    end else begin
      done      <= 1'b0;
      rx_valid  <= 1'b0;
      word_done <= 1'b0;

      unique case (state)
        ST_IDLE: begin
          divider_count <= 8'h00;
          phase_count   <= 6'd0;
          dummy_count   <= 8'h00;
          cs_high_half  <= 1'b0;

          if (start) begin
            dir_latched        <= dir;
            addr_en_latched    <= addr_en;
            data_en_latched    <= data_en;
            target_latched     <= target;
            quad_mode_latched  <= quad_mode;
            cpol_latched       <= cpol;
            cpha_latched       <= cpha;
            stream_latched     <= stream_enable;
            clkdiv_latched     <= clkdiv;
            dummy_latched      <= dummy;
            write_data_latched <= write_data;
            address_latched    <= address;

            shift_reg <= {opcode, 24'h000000};
            rx_shift  <= 32'h0000_0000;
            sck_level <= cpol;
            state     <= ST_COMMAND;
          end
        end

        ST_COMMAND,
        ST_ADDRESS,
        ST_DATA: begin
          if (half_period_tick) begin
            divider_count <= 8'h00;

            if (sck_level == cpol_latched) begin
              // Leading SCK edge
              sck_level <= ~cpol_latched;

              // Mode 0 samples receive data on the leading edge.
              if ((state == ST_DATA) && dir_latched && !cpha_latched) begin
                if (quad_mode_latched) begin
                  rx_shift <= {rx_shift[27:0], qspi_sio_i};
                  if (phase_count == phase_last) read_data <= byte_swap32({rx_shift[27:0], qspi_sio_i});
                end else begin
                  rx_shift <= {rx_shift[30:0], qspi_sio_i[1]};
                  if (phase_count == phase_last) read_data <= byte_swap32({rx_shift[30:0], qspi_sio_i[1]});
                end
              end
            end else begin
              // Trailing SCK edge
              sck_level <= cpol_latched;

              // Mode 3 samples receive data on the trailing edge.
              if ((state == ST_DATA) && dir_latched && cpha_latched) begin
                if (quad_mode_latched) begin
                  rx_shift <= {rx_shift[27:0], qspi_sio_i};
                  if (phase_count == phase_last) read_data <= byte_swap32({rx_shift[27:0], qspi_sio_i});
                end else begin
                  rx_shift <= {rx_shift[30:0], qspi_sio_i[1]};
                  if (phase_count == phase_last) read_data <= byte_swap32({rx_shift[30:0], qspi_sio_i[1]});
                end
              end

              if (phase_count == phase_last) begin
                phase_count <= 6'd0;

                unique case (state)
                  ST_COMMAND: begin
                    if (addr_en_latched) begin
                      shift_reg <= {address_latched, 8'h00};
                      state     <= ST_ADDRESS;
                    end else if (data_en_latched && (dummy_latched != 8'h00)) begin
                      dummy_count <= 8'h00;
                      state       <= ST_DUMMY;
                    end else if (data_en_latched) begin
                      if (!dir_latched) shift_reg <= byte_swap32(write_data_latched);
                      else rx_shift <= 32'h0000_0000;
                      state <= ST_DATA;
                    end else begin
                      state <= ST_FINISH;
                    end
                  end

                  ST_ADDRESS: begin
                    if (data_en_latched && (dummy_latched != 8'h00)) begin
                      dummy_count <= 8'h00;
                      state       <= ST_DUMMY;
                    end else if (data_en_latched) begin
                      if (!dir_latched) shift_reg <= byte_swap32(write_data_latched);
                      else rx_shift <= 32'h0000_0000;
                      state <= ST_DATA;
                    end else begin
                      state <= ST_FINISH;
                    end
                  end

                  ST_DATA: begin
                    word_done <= 1'b1;
                    if (dir_latched && stream_latched) rx_valid <= 1'b1;
                    state <= stream_latched ? ST_STREAM_WAIT : ST_FINISH;
                  end

                  default: state <= ST_FINISH;
                endcase
              end else begin
                phase_count <= phase_count + 6'd1;

                if ((state == ST_COMMAND) || (state == ST_ADDRESS) || ((state == ST_DATA) && !dir_latched)) begin
                  if (quad_mode_latched) shift_reg <= {shift_reg[27:0], 4'h0};
                  else shift_reg <= {shift_reg[30:0], 1'b0};
                end
              end
            end
          end else begin
            divider_count <= divider_count + 8'd1;
          end
        end

        ST_DUMMY: begin
          if (half_period_tick) begin
            divider_count <= 8'h00;

            if (sck_level == cpol_latched) begin
              sck_level <= ~cpol_latched;
            end else begin
              sck_level <= cpol_latched;

              if (dummy_count == (dummy_latched - 8'd1)) begin
                dummy_count <= 8'h00;
                phase_count <= 6'd0;

                if (data_en_latched) begin
                  if (!dir_latched) shift_reg <= byte_swap32(write_data_latched);
                  else rx_shift <= 32'h0000_0000;
                  state <= ST_DATA;
                end else begin
                  state <= ST_FINISH;
                end
              end else begin
                dummy_count <= dummy_count + 8'd1;
              end
            end
          end else begin
            divider_count <= divider_count + 8'd1;
          end
        end

        ST_STREAM_WAIT: begin
          // Keep CE# asserted and SCK at the idle polarity while the caller
          // decides whether the sequential transfer continues or terminates.
          sck_level     <= cpol_latched;
          divider_count <= 8'h00;
          phase_count   <= 6'd0;

          if (stream_stop) begin
            state <= ST_FINISH;
          end else if (stream_next) begin
            if (!dir_latched) shift_reg <= byte_swap32(stream_write_data);
            else rx_shift <= 32'h0000_0000;
            state <= ST_DATA;
          end
        end

        ST_FINISH: begin
          // Keep CE# active at idle SCK polarity for one final half period.
          sck_level <= cpol_latched;

          if (half_period_tick) begin
            divider_count <= 8'h00;
            cs_high_half  <= 1'b0;
            state         <= ST_CS_HIGH;
          end else begin
            divider_count <= divider_count + 8'd1;
          end
        end

        ST_CS_HIGH: begin
          // CE# is inactive in this state. Hold it high for one complete
          // configured SCK period.
          sck_level <= cpol_latched;

          if (half_period_tick) begin
            divider_count <= 8'h00;

            if (cs_high_half) begin
              state <= ST_IDLE;
              done  <= 1'b1;
              if (dir_latched && data_en_latched && !stream_latched) rx_valid <= 1'b1;
            end else begin
              cs_high_half <= 1'b1;
            end
          end else begin
            divider_count <= divider_count + 8'd1;
          end
        end

        default: begin
          state         <= ST_IDLE;
          divider_count <= 8'h00;
          sck_level     <= 1'b0;
        end
      endcase
    end
  end

endmodule
