`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// EMBERFOX - spawn post-processor
//
// Sits between spawn_queue (which is pure random and difficulty-blind) and the
// object registers. It is the one place where the DIFFICULTY touches the
// falling half of the game, and it is where the opening teaching window lives.
//
// spawn_queue always produces the same mix:
//
//     +1 20%   +3 20%   +5 10%   -3 20%   -5 15%   +time 5%   charge 10%
//
// so 35% of everything that falls is a hazard no matter what the player chose
// on the menu. That is why EASY used to feel exactly as busy as HARD. This
// block rewrites the type on the way past:
//
//     warmup   every hazard -> +1        (first seconds of every run)
//     EASY     3 hazards in 4 -> +1, the survivor capped at -3   (~9% hazards)
//     NORMAL   -5 -> -3                  (still 35% hazards, but all mild)
//     HARD     untouched                 (35% hazards, full -3 / -5)
//
// Position is never changed - only the value. The "3 in 4" roll reuses the low
// bits of raw_xoff, which are already random and only decide where inside a
// 32 px lane the sprite sits; borrowing them costs no extra LFSR and the
// correlation (a softened hazard never lands on a 4-pixel offset of 3) is far
// below anything a player could see.
// ---------------------------------------------------------------------------

module spawn_postprocess #(
	parameter LANE_BITS = 4,
	parameter XOFF_BITS = 4,
	parameter OBJ_TYPE_BITS = 3
)(
	input clk,
	input resetn,
	input fire,
	input warmup,
	input [1:0] diff,             // 0 = EASY, 1 = NORMAL, 2 = HARD

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

localparam DIFF_EASY = 0;
localparam DIFF_HARD = 2;

wire is_hazard = (raw_type == TYPE_MINUS3) || (raw_type == TYPE_MINUS5);

// EASY throws away three hazards out of four; the warmup window throws away
// all of them, on every difficulty.
wire soften = warmup || ((diff == DIFF_EASY) && (raw_xoff[1:0] != 2'd3));

assign out_lane = raw_lane;
assign out_xoff = raw_xoff;
assign out_type = (is_hazard && soften)                          ? TYPE_COIN_1 :
                  ((diff != DIFF_HARD) && (raw_type == TYPE_MINUS5)) ? TYPE_MINUS3 :
                                                                   raw_type;

endmodule
