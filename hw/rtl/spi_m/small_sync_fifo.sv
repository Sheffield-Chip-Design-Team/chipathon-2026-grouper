module small_sync_fifo #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 4
)(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   flush,

    input  logic [DATA_WIDTH-1:0]  wdata,
    input  logic                   write,

    input  logic                   read,

    output logic [DATA_WIDTH-1:0]  rdata,

    output logic                   full,
    output logic                   empty
);

localparam ADDR_W = $clog2(FIFO_DEPTH);

logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

logic [ADDR_W-1:0] wr_ptr;
logic [ADDR_W-1:0] rd_ptr;

logic [ADDR_W:0] count;

always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

        wr_ptr <= '0;
        rd_ptr <= '0;
        count  <= '0;
        rdata  <= '0;

    end

    else if (flush) begin

        wr_ptr <= '0;
        rd_ptr <= '0;
        count  <= '0;

    end

    else begin

        if (write && !full) begin
            mem[wr_ptr] <= wdata;

            if (wr_ptr == ADDR_W'(FIFO_DEPTH-1))
                wr_ptr <= '0;
            else
                wr_ptr <= wr_ptr + 1'b1;
        end

        if (read && !empty) begin

            rdata <= mem[rd_ptr];

            if (rd_ptr == ADDR_W'(FIFO_DEPTH-1))
                rd_ptr <= '0;
            else
                rd_ptr <= rd_ptr + 1'b1;

        end

        case ({write && !full, read && !empty})

            2'b10:
                count <= count + 1'b1;

            2'b01:
                count <= count - 1'b1;

            default:
                count <= count;

        endcase

    end

end

assign empty = (count == 0);

assign full = (count == FIFO_DEPTH);
assign level = count;

endmodule