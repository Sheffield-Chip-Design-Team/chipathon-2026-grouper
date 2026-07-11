`ifndef DUMP_FILE
`define DUMP_FILE "dump.vcd"
`endif

module picorv32_hello_tb;
  timeunit 1ns/1ps;

  localparam real CLK_FREQ = 10e6;
  localparam int TX_BAUD_RATE = 19200; // Baud rate of uart_tx
  localparam int RX_BAUD_RATE = 19200; // Baud rate of uart_rx (useful for testing resync)

  logic clk;
  logic rst_n;

  logic uart_tx;
  logic uart_rx;

  mailbox #(byte) uart_tx_mb = new();

  picorv32_hello_core #(
    .CLK_FREQ (CLK_FREQ)
  ) DUT (
    .clk      (clk),
    .rst_n    (rst_n),
    .uart_tx  (uart_tx),
    .uart_rx  (uart_rx)
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
    
    repeat(1_000_000) @(posedge clk);
    $error("TB Timed Out");
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