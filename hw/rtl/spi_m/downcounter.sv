module downcounter #(
    parameter WIDTH = 3
)(
    input  logic             clk,
    input  logic             rst_n,

    input  logic             load,
    input  logic             enable,

    input  logic [WIDTH-1:0] load_value,

    output logic [WIDTH-1:0] value,
    output logic             zero
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        value <= '0;

    else if (load)
        value <= load_value;

    else if (enable && value != 0)
        value <= value - 1'b1;
end

assign zero = (value == 0);

endmodule