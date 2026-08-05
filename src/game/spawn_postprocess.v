`timescale 1ns / 1ps

module spawn_postprocess #(
	parameter LANE_BITS = 4,
	parameter XOFF_BITS = 4,
	parameter OBJ_TYPE_BITS = 3
)(
	input clk,
	input resetn,
	input fire,
	input warmup,

	input [LANE_BITS-1:0] raw_lane,
	input [XOFF_BITS-1:0] raw_xoff,
	input [OBJ_TYPE_BITS-1:0] raw_type,

	output [LANE_BITS-1:0] out_lane,
	output [XOFF_BITS-1:0] out_xoff,
	output [OBJ_TYPE_BITS-1:0] out_type
);
localparam TYPE_COIN_1 = 0;
localparam TYPE_MINUS3 = 3;
localparam TYPE_MINUS5 = 4;

// Base branch is pass-through; the warmup branch turns the run's opening
// window into pure teaching: frost shards are remapped to plain +1 embers, so
// a new player is never punished before they have learned to read the sprite.
// Position is left untouched - the only thing that changes is the value.
assign out_lane = raw_lane;
assign out_xoff = raw_xoff;
assign out_type = warmup && ((raw_type == TYPE_MINUS3) || (raw_type == TYPE_MINUS5))
				? TYPE_COIN_1 : raw_type;

endmodule
