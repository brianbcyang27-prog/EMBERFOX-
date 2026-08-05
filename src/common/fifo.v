`timescale 1ns / 1ps

module fifo #(
	parameter WIDTH = 10,
	parameter DEPTH = 4,
	parameter ADDR_W = $clog2(DEPTH)
) (
	input wire clk,
	input wire resetn,

	input wire wr_en,
	input wire [WIDTH-1:0] wr_data,
	output wire full,

	input wire rd_en,
	output wire [WIDTH-1:0] rd_data,
	output wire empty,

	output wire [ADDR_W:0] level
);
(* ramstyle = "distributed" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

reg [ADDR_W-1:0] wr_ptr;
reg [ADDR_W-1:0] rd_ptr;
reg [ADDR_W:0] count;

wire do_wr = wr_en && !full;
wire do_rd = rd_en && !empty;

assign full  = (count == DEPTH);
assign empty = (count == 0);
assign level = count;

assign rd_data = mem[rd_ptr];

always @(posedge clk) begin
	if (!resetn) begin
		wr_ptr <= 0;
		rd_ptr <= 0;
		count  <= 0;
	end else begin
		if (do_wr) begin
			mem[wr_ptr] <= wr_data;
			wr_ptr <= wr_ptr + 1;
		end

		if (do_rd) begin
			rd_ptr <= rd_ptr + 1;
		end

		case ({do_wr, do_rd})
			2'b10: count <= count + 1;
			2'b01: count <= count - 1;
			default: count <= count;
		endcase
	end
end
endmodule
