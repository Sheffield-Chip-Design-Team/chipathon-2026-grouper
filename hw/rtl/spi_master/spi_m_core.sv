


module spi_m_core #(
    parameter int DATA_WIDTH = 8,
    parameter int FIFO_DEPTH = 4
)(
    input  logic clk,
    input  logic rst_n,

    // Configuration
    input  logic        enable,
    input  logic        start,
    input  logic        cpol,
    input  logic        cpha,
    input  logic [7:0]  clk_div,

    // Transaction 
    input  logic [7:0]  opcode,
    input  logic        cmd_en,
    input  logic        addr_en,
    input  logic [1:0]  addr_bytes,
    input  logic [31:0] addr,
    input  logic        data_en,
    input  logic        dir,
    input  logic [4:0]  dummy_cycles,
    input  logic [7:0]  data_len,



    // TX FIFO  interface
    input  logic                    flush_tx_fifo,
    input  logic                    tx_write,
    input  logic [DATA_WIDTH-1:0]   tx_data,
    output logic                    tx_full,
    output logic                    tx_empty,


    // RX   FIFO interface
    input  logic                    flush_rx_fifo,
    input  logic                    rx_read,
    output logic [DATA_WIDTH-1:0]   rx_data,
    output logic                    rx_full,
    output logic                    rx_empty,


    // Status
    output logic                    busy,
    output logic                    done,



    // SPI pins
    output logic                    spi_mosi,
    input  logic                    spi_miso,
    output logic                    spi_sck,
    output logic                    spi_cs_n


); 


//internal signals

logic               spi_clk_en;


logic               tx_busy;
logic               tx_done;
logic               rx_received;




// CLK Divider

spi_clk_div #(
    .CLK_DIV_BITS(8)
) u_clk_div (
    .clk     (clk),
    .rst_n   (rst_n),

    .enable  (enable),
    .clk_div (clk_div),

    .zero    (spi_clk_en)
);


//Instantiating TX module

spi_tx u_tx (
    .clk(clk),
    .rst_n(rst_n),

    .spi_clk_en(spi_clk_en),

    .enable(enable),
    .start(start),

    .cpol(cpol),
    .cpha(cpha),

    .opcode(opcode),
    .cmd_en(cmd_en),

    .addr_en(addr_en),
    .addr_bytes(addr_bytes),
    .addr(addr),

    .data_en(data_en),
    .dir(dir),
    .dummy_cycles(dummy_cycles),
    .data_len(data_len),

    .busy(tx_busy),
    .done(tx_done),

    .flush_tx_fifo(flush_tx_fifo),
    .tx_data(tx_data),
    .tx_write(tx_write),
    .tx_full(tx_full),
    .tx_empty(tx_empty),

    .spi_mosi(spi_mosi),
    .spi_sck(spi_sck),
    .spi_cs_n(spi_cs_n)
);


//  instantiating RX 

spi_rx u_rx (
   
    .clk(clk),
    .rst_n(rst_n),

    .spi_clk_en(spi_clk_en),

    .enable(enable && dir),

    .received(rx_received),

    .flush_rx_fifo(flush_rx_fifo),
    .rx_read(rx_read),

    .rx_full(rx_full),
    .rx_empty(rx_empty),
    .rx_data(rx_data),

    .spi_miso(spi_miso)
);

assign busy = tx_busy;
assign done = tx_done;

endmodule 