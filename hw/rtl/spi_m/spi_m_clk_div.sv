module spi_clk_div #(
    parameter int CLK_DIV_BITS = 10
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    enable,
    input  logic [CLK_DIV_BITS-1:0] clk_div,

    output logic                    zero
);

logic                    enable_r;
logic [CLK_DIV_BITS-1:0] ctr;

assign zero = (ctr == 0);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        enable_r <= 1'b0;
    else
        enable_r <= enable;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ctr <= '0;
    end else if (!enable) begin
        ctr <= '0;
    end else if (!enable_r) begin
        ctr <= clk_div;
    end else if (ctr == 0) begin
        ctr <= clk_div;
    end else begin
        ctr <= ctr - 1'b1;
    end
end

endmodule