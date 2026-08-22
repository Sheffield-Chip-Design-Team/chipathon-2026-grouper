

module shift_reg #(
    parameter WIDTH = 8,
    parameter LSB_FIRST = 0,
    parameter REGISTERED_OUT = 0
)(
    input  logic             clk,
    input  logic             rst_n,

    input  logic             shift,
    input  logic             load,

    input  logic [WIDTH-1:0] load_value,

    input  logic             in,

    output logic [WIDTH-1:0] value_out,
    output logic             out
);

logic [WIDTH-1:0] shreg;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        shreg <= '0;

    else if (load)
        shreg <= load_value;

    else if (shift) begin

        if (LSB_FIRST)
            shreg <= {in, shreg[WIDTH-1:1]};
        else
            shreg <= {shreg[WIDTH-2:0], in};

    end
end

assign value_out = shreg;

generate
if (LSB_FIRST)
    assign out = shreg[0];
else
    assign out = shreg[WIDTH-1];
endgenerate

endmodule