`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// EMBERFOX - square-wave sound engine (LEAN)
//
// One procedural voice, built to fit in the ~40 free LUTs left on the 4K.
// There is no tone table and no divider logic: the note is an octave bit of a
// free-running counter, and the event id is *encoded* so that its fields ARE
// the parameters:
//
//   ev[4:3]  duration class  00 = 2 frames  (33 ms blip)
//                            01 = 6 frames  (100 ms)
//                            10 = 12 frames (200 ms)
//                            11 = 20 frames (333 ms)
//   ev[2:0]  pitch class    oct_cnt[12+p] toggles at  3073/1536/768/384/192/96 Hz
//
// so the engine needs no decoder at all, only two compares (EV_NONE / EV_TRIP).
// Frequencies are octave-spaced (powers of two) - intentionally. For short
// arcade beeps on a small passive piezo this is indistinguishable from tuned
// notes, and it costs almost nothing in fabric.
//
// Wire a passive piezo from `buzz` to GND (board pins are 1.8 V LVCMOS; add a
// transistor buffer for a louder 3.3 V swing).
// ---------------------------------------------------------------------------

module sound_engine (
	input clk,
	input resetn,

	input pulse,        // one clock wide, event id valid on same clock
	input frame_tick,   // one pulse per video frame (~60 Hz), all states
	input [4:0] ev,     // encoded event id, see comment above

	output reg buzz
);
// Event ids - must match the values game_ctrl emits. Several events share an
// id (same encoded sound), which is fine: nothing decodes sound_ev, it only
// needs to be non-zero for "play" and EV_TRIP for "noise".
localparam EV_NONE    = 5'd0;
localparam EV_MENU    = 5'd1;
localparam EV_CONFIRM = 5'd2;
localparam EV_COUNT   = 5'd3;
localparam EV_JUMP    = 5'd6;
localparam EV_JUMP2   = 5'd5;
localparam EV_JUMP3   = 5'd4;
localparam EV_C1      = 5'd5;
localparam EV_C3      = 5'd17;
localparam EV_C5      = 5'd25;
localparam EV_CRYSTAL = 5'd4;
localparam EV_SUNSTONE= 5'd16;
localparam EV_SHARD   = 5'd7;
localparam EV_TRIP    = 5'd8;
localparam EV_SKILL   = 5'd24;
localparam EV_SKILL_E = 5'd26;
localparam EV_WARN    = 5'd18;
localparam EV_OVER    = 5'd28;
localparam EV_HIGH    = 5'd25;

function [3:0] ev_frames;
	input [1:0] d;
	begin
		case (d)
			2'b00:   ev_frames = 4'd2;
			2'b01:   ev_frames = 4'd6;
			2'b10:   ev_frames = 4'd12;
			default: ev_frames = 4'd20;
		endcase
	end
endfunction

reg [19:0] oct_cnt;      // free-running; bit k toggles at 25.175 MHz / 2^(k+1)
reg [7:0]  lfsr;         // 8-bit noise generator for the trip/crash sound
reg [3:0]  frames_left;
reg        tone_active;

always @(posedge clk) begin
	if (!resetn) begin
		oct_cnt     <= 20'd0;
		lfsr        <= 8'hFF;
		frames_left <= 4'd0;
		tone_active <= 1'b0;
		buzz        <= 1'b0;
	end else begin
		oct_cnt <= oct_cnt + 1'b1;
		lfsr    <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

		if (pulse && ev != EV_NONE) begin
			frames_left <= ev_frames(ev[4:3]);
			tone_active <= 1'b1;
		end else if (frame_tick && tone_active) begin
			if (frames_left == 4'd1) begin
				frames_left <= 4'd0;
				tone_active <= 1'b0;
			end else begin
				frames_left <= frames_left - 1'b1;
			end
		end

		if (tone_active) begin
			if (ev == EV_TRIP)
				buzz <= lfsr[7];
			else
				buzz <= oct_cnt[12 + ev[2:0]];
		end else begin
			buzz <= 1'b0;
		end
	end
end
endmodule
