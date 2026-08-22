// AHB spi_s

module ahb_spi_s #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // AHB Slave Interface

  // Master Signals
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL,

  // SPI interface
  input logic                   spi_ss,
  input logic                   spi_sck,
  input logic                   spi_mosi,
  output logic                  spi_miso
);

  import ahb3lite_pkg::*;

  localparam int SPI_S_DATA_W = 8;

  // AHB transfer codes needed in this module
  localparam bit [1:0] No_Transfer = 2'b00;

  localparam bit [1:0] ADDR_CTRL   = 2'b00;
  localparam bit [1:0] ADDR_STATUS = 2'b01;
  localparam bit [1:0] ADDR_TXDATA = 2'b10;
  localparam bit [1:0] ADDR_RXDATA = 2'b11;

  // SPI command codes
  localparam logic [7:0] SPI_WRITE  = 8'h02;
  localparam logic [7:0] SPI_READ   = 8'h03;
  localparam logic [7:0] FAST_WRITE = 8'h0A;
  localparam logic [7:0] FAST_READ  = 8'h0B;

  // SPI command FSM states
  typedef enum logic [2:0] {
    FSM_IDLE,
    FSM_COMMAND,
    FSM_ADDRESS,
    FSM_READ_DATA,
    FSM_WRITE_DATA
  } spi_state_t;

  spi_state_t spi_state;

  // Control registers
  logic ctrl_enable;
  logic ctrl_soft_reset;

  // Status registers
  logic status_busy;
  logic status_rx_valid;
  logic status_tx_ready;

  // SPI data registers
  logic [SPI_S_DATA_W-1:0] tx_data;
  logic [SPI_S_DATA_W-1:0] rx_data;

  // SPI receive shift register and bit counter
  logic [SPI_S_DATA_W-1:0] rx_shift;
  logic [2:0]              bit_count;

  // SPI transmit shift register and bit counter
  logic [SPI_S_DATA_W-1:0] tx_shift;
  logic [2:0]              tx_bit_count;

  // Received SPI byte
  logic [SPI_S_DATA_W-1:0] received_byte;

  // SPI command and address
  logic [SPI_S_DATA_W-1:0] spi_command;
  logic [23:0]             spi_address;
  logic [23:0]             address_shift;
  logic [4:0]              address_bit_count;

  // SPI clock edge detection
  logic spi_sck_d;
  logic spi_sck_rise;
  logic spi_sck_fall;

  // AHB control signals
  logic                       access;
  logic                       read_enable;
  logic                       read_enable_r;
  logic                       write_enable;
  logic [1:0]                 word_address;
  logic [1:0]                 word_address_r;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;
  logic [(DATA_WIDTH/8)-1:0]  byte_select_r;
  logic                       invalid_access;

  // Generate AHB control signals
  assign access      = HREADYIN && HSEL && (HTRANS != No_Transfer);
  assign read_enable = access && ~HWRITE;

  // Temporary value until the remaining SPI core logic is implemented.
  assign status_busy = 1'b0;

  // Detect SPI clock edges
  assign spi_sck_rise = spi_sck && !spi_sck_d;
  assign spi_sck_fall = !spi_sck && spi_sck_d;

  // AHB address and byte select
  assign word_address =
      access ? HADDR[3:2] : '0;

  assign byte_select =
      access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

  // Delay AHB control signals to the data phase
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin

      write_enable   <= 1'b0;
      read_enable_r  <= 1'b0;
      word_address_r <= '0;
      byte_select_r  <= '0;
    end
    else begin
      write_enable   <= access && HWRITE;
      read_enable_r  <= read_enable;
      word_address_r <= word_address;
      byte_select_r  <= byte_select;
    end
  end

  // Main SPI and register logic
  always_ff @(posedge HCLK, negedge HRESETn) begin

    if (~HRESETn) begin

      // Control registers
      ctrl_enable     <= 1'b0;
      ctrl_soft_reset <= 1'b0;

      // SPI command FSM
      spi_state <= FSM_IDLE;

      // Data registers
      tx_data       <= '0;
      rx_data       <= '0;
      received_byte <= '0;

      // SPI command and address
      spi_command       <= '0;
      spi_address       <= '0;
      address_shift     <= '0;
      address_bit_count <= '0;

      // Receive logic
      rx_shift  <= '0;
      bit_count <= '0;

      // Transmit logic
      tx_shift     <= '0;
      tx_bit_count <= '0;

      // SPI clock history
      spi_sck_d <= 1'b0;

      // Status
      status_rx_valid <= 1'b0;
      status_tx_ready <= 1'b1;

    end
    else begin

      // Remember previous SPI clock state
      spi_sck_d <= spi_sck;

      // SPI command FSM
      if (spi_ss) begin

        spi_state         <= FSM_IDLE;
        bit_count         <= 3'd0;
        address_bit_count <= 5'd0;

      end
      else if (spi_state == FSM_IDLE) begin

        spi_state <= FSM_COMMAND;

      end

      // SPI RECEIVE
      // sample MOSI on the rising edge of SCK
      if (!spi_ss && spi_sck_rise) begin

        rx_shift <= {
          rx_shift[6:0],
          spi_mosi
        };

        // Receiving command
        if (spi_state == FSM_COMMAND) begin

          if (bit_count == 3'd7) begin

            received_byte <= {
              rx_shift[6:0],
              spi_mosi
            };

            rx_data <= {
              rx_shift[6:0],
              spi_mosi
            };

            status_rx_valid <= 1'b1;

            bit_count <= 3'd0;

            // Save command
            spi_command <= {
              rx_shift[6:0],
              spi_mosi
            };

            // SPI command decode
            unique case ({
              rx_shift[6:0],
              spi_mosi
            })

              SPI_WRITE,
              SPI_READ,
              FAST_WRITE,
              FAST_READ:
                spi_state <= FSM_ADDRESS;

              default:
                spi_state <= FSM_IDLE;

            endcase

          end
          else begin

            bit_count <= bit_count + 1'b1;

          end

        end

        // Receiving address
        else if (spi_state == FSM_ADDRESS) begin

          address_shift <= {
            address_shift[22:0],
            spi_mosi
          };

          if (address_bit_count == 5'd23) begin

            // 24-bit address received.
            spi_address <= {
              address_shift[22:0],
              spi_mosi
            };

            address_bit_count <= 5'd0;

            // Decide whether this is a read or write.
            if (spi_command == SPI_READ ||
                spi_command == FAST_READ) begin

              spi_state <= FSM_READ_DATA;

            end
            else begin

              spi_state <= FSM_WRITE_DATA;

            end

          end
          else begin

            address_bit_count <= address_bit_count + 1'b1;

          end

        end

        // Receiving write data
        else if (spi_state == FSM_WRITE_DATA) begin

          if (bit_count == 3'd7) begin

            // Eight bits received.
            received_byte <= {
              rx_shift[6:0],
              spi_mosi
            };

            rx_data <= {
              rx_shift[6:0],
              spi_mosi
            };

            status_rx_valid <= 1'b1;

            bit_count <= 3'd0;

          end
          else begin

            bit_count <= bit_count + 1'b1;

          end

        end

      end

      // SPI READ DATA
      if (!spi_ss &&
          spi_state == FSM_READ_DATA &&
          status_tx_ready) begin

        // Load the current transmit byte.
        tx_shift     <= tx_data;
        tx_bit_count <= 3'd0;

        // A byte is now being transmitted.
        status_tx_ready <= 1'b0;

      end

      // SPI TRANSMIT
      if (!spi_ss && spi_sck_fall && !status_tx_ready) begin

        if (tx_bit_count == 3'd7) begin

          // All eight bits have been transmitted.
          tx_bit_count <= 3'd0;

          status_tx_ready <= 1'b1;

        end
        else begin

          tx_bit_count <= tx_bit_count + 1'b1;

        end

      end

      // Keep transmit shift register updated
      if (!spi_ss && spi_sck_fall && !status_tx_ready) begin

        tx_shift <= {
          tx_shift[6:0],
          1'b0
        };

      end

      // Clear RX_VALID after software reads RXDATA
      if (read_enable_r && word_address_r == ADDR_RXDATA) begin

        status_rx_valid <= 1'b0;

      end

      // AHB WRITE
      if (write_enable) begin

        unique case (word_address_r)

          // CTRL register
          ADDR_CTRL: begin

            if (byte_select_r[0]) begin

              ctrl_enable     <= HWDATA[0];
              ctrl_soft_reset <= HWDATA[1];

              // Software reset
              if (HWDATA[1]) begin

                rx_shift          <= '0;
                bit_count         <= '0;

                tx_shift          <= '0;
                tx_bit_count      <= '0;

                status_rx_valid   <= 1'b0;
                status_tx_ready   <= 1'b1;

                spi_state         <= FSM_IDLE;

                spi_command       <= '0;
                spi_address       <= '0;
                address_shift     <= '0;
                address_bit_count <= '0;

              end
            end
          end

          // TXDATA register
          ADDR_TXDATA: begin

            if (byte_select_r[0]) begin

              // Store the byte written by the AHB master.
              tx_data <= HWDATA[7:0];

              // Also load the shift register.
              tx_shift <= HWDATA[7:0];

              // Start at the MSB.
              tx_bit_count <= 3'd0;

              // A byte is now waiting to be transmitted.
              status_tx_ready <= 1'b0;

            end
          end

          default: begin
          end

        endcase
      end
    end
  end

  // SPI MISO
  always_comb begin

    if (!spi_ss && ctrl_enable && !status_tx_ready) begin

      spi_miso = tx_shift[7];

    end
    else begin

      spi_miso = 1'b0;

    end

  end

  // AHB READ DATA
  always_comb begin

    if (!read_enable_r) begin

      HRDATA = '0;

    end
    else begin

      unique case (word_address_r)

        // CTRL register - 0x00
        ADDR_CTRL:
          HRDATA = {
            30'b0,
            ctrl_soft_reset,
            ctrl_enable
          };

        // STATUS register - 0x04
        ADDR_STATUS:
          HRDATA = {
            29'b0,
            status_tx_ready,
            status_rx_valid,
            status_busy
          };

        // RXDATA register - 0x0C
        ADDR_RXDATA:
          HRDATA = {
            24'b0,
            rx_data
          };

        default:
          HRDATA = '0;

      endcase
    end

  end

  // AHB invalid-access detection
  always_comb begin

    invalid_access = 1'b0;

    if (write_enable) begin

      unique case (word_address_r)

        // STATUS is read-only
        ADDR_STATUS:
          invalid_access |= 1'b1;

        // RXDATA is read-only
        ADDR_RXDATA:
          invalid_access |= 1'b1;

        default: begin
        end

      endcase
    end
  end

  // AHB response
  // Single-cycle (zero-wait-state)
  assign HREADYOUT = 1'b1;

  // FIXME: add 2-cycle error response for invalid access.
  assign HRESP = invalid_access ? 1'b1 : 1'b0;

endmodule
