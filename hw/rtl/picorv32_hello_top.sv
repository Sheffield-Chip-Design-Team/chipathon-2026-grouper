module picorv32_hello_top(
  input logic sysclk,
  
  input logic reset_btn_n,

  // UART interface
  output logic  uart_tx,
  input  logic  uart_rx
);

  // TODO: Add PLL
  picorv32_hello_core u_core (
    .clk      (sysclk),
    .rst_n    (reset_btn_n),
    .uart_tx  (uart_tx),
    .uart_rx  (uart_rx)
  );

endmodule
