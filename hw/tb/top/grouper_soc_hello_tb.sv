`ifndef DUMP_FILE
`define DUMP_FILE "dump.fst"
`endif

module grouper_soc_hello_tb;
  timeunit 1ns/1ps;

  localparam int TX_BAUD_RATE = 19200;   // Baud rate of uart_tx
  localparam int RX_BAUD_RATE = 19200;   // Baud rate of uart_rx (useful for testing resync)

  // The firmware computes its baud divisor from a hardcoded core clock
  // (SYS_CLK_HZ in sw/src/uart/uart.h) - if this doesn't match it, the DUT
  // transmits at the wrong baud rate and this testbench decodes nothing but
  // framing errors. Keep the two in step.
  localparam int CLK_FREQ = 10_000_000;  // Frequency of the clock in Hz

  logic clk;
  logic rst_n;

  logic uart_tx;
  logic uart_rx;

  mailbox #(byte) uart_tx_mb = new();

  // FIXME - instantiate grouper_soc_top
  
  digital_ss  u_grouper_soc_core (
      .clk                       (clk),
      .rst_n                     (rst_n),

      .uart_tx                   (uart_tx),
      .uart_rx                   (uart_rx),

      .gpio_in                   ('0),
      .gpio_out                  (),
      .gpio_oe                   (),
      .gpio_cs                   (),
      .gpio_sl                   (),
      .gpio_ie                   (),
      .gpio_pu                   (),
      .gpio_pd                   (),
      .gpio_sync_en_n            (),

      .ext_ahb_m_if_HADDR        (),
      .ext_ahb_m_if_HBURST       (),
      .ext_ahb_m_if_HMASTLOCK    (),
      .ext_ahb_m_if_HPROT        (),
      .ext_ahb_m_if_HSIZE        (),
      .ext_ahb_m_if_HTRANS       (),
      .ext_ahb_m_if_HWDATA       (),
      .ext_ahb_m_if_HWRITE       (),
      .ext_ahb_m_if_HRDATA       ('0),
      .ext_ahb_m_if_HREADY       (1'b1),
      .ext_ahb_m_if_HRESP        (1'b0)
  );

  initial begin
    clk = 1'b0;
    forever begin
      #(0.5s/(CLK_FREQ));
      clk = ~clk;
    end
  end

  task reset();
    rst_n   = 1'b0;
    #123ns;
    fork
      begin @(posedge clk) rst_n = 1'b1; end
    join
    @(posedge clk);
  endtask

  initial begin
    rst_n   = 1'b1; // Generate an initial falling edge
    #1ns;
    reset();
    
    repeat(400_000) @(posedge clk);
    $display("TB_TIMEOUT: gave up waiting for firmware to reach the exit sequence");
    $finish;
  end

  // Dump waves
  initial begin
    $dumpfile(`DUMP_FILE);
    $dumpvars();
  end

  event uart_tx_sample;
  event uart_tx_invalid_start_bit;
  event uart_tx_invalid_stop_bit;
  event uart_tx_newline;
  byte last_tx_byte;

  initial begin
    byte value;
    forever begin
      value = 0;
      // Wait for start bit
      @(negedge uart_tx);
      #(500ms/TX_BAUD_RATE); // Wait half a bit period
      ->uart_tx_sample;
      if (uart_tx) ->uart_tx_invalid_start_bit;
      repeat (8) begin
        #(1000ms/TX_BAUD_RATE);
        ->uart_tx_sample;
        value = { uart_tx, value[7:1] };
      end
      #(1000ms/TX_BAUD_RATE);
      ->uart_tx_sample;
      if (~uart_tx) ->uart_tx_invalid_stop_bit;
      else begin
        last_tx_byte = value;
        $write("%c", value);
        uart_tx_mb.put(value);
        if (value == 8'h0a) ->uart_tx_newline;
      end
    end
  end

  // A baud rate mismatch between the DUT and TX_BAUD_RATE shows up as nothing
  // but framing errors, and without this the run just goes quiet until
  // TB_TIMEOUT. Say so the first time it happens.
  initial begin
    fork
      @(uart_tx_invalid_start_bit);
      @(uart_tx_invalid_stop_bit);
    join_any
    $display("TB_ERROR: uart_tx framing error - DUT baud rate does not match TX_BAUD_RATE (%0d). Check CLK_FREQ here against SYS_CLK_HZ in sw/src/uart/uart.h", TX_BAUD_RATE);
  end

  task uart_rx_send(input byte c);
    uart_rx = 0;
    #(1000ms/RX_BAUD_RATE);
    repeat (8) begin
      {c, uart_rx} = {1'b0, c};
      #(1000ms/RX_BAUD_RATE);
    end
    uart_rx = 1;
    #(1000ms/RX_BAUD_RATE);
  endtask

  initial begin
    uart_rx = 1'b1;

    @(uart_tx_newline);
    
    uart_rx_send("t");
    uart_rx_send("e");
    uart_rx_send("s");
    uart_rx_send("t");
    uart_rx_send("\n");
    
    @(uart_tx_newline);

    uart_rx_send("e");
    uart_rx_send("x");
    uart_rx_send("i");
    uart_rx_send("t");
    uart_rx_send("\n");

    // Send a break
    uart_rx = 0;
  end

endmodule