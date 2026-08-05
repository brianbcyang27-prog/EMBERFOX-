`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

module ui_layer #(
	`SVO_DEFAULT_PARAMS,
	parameter SKILL_ENABLE = 0
) (
	input clk,
	input resetn,

	input [11:0] timer_bcd,
	input [11:0] score_bcd,
	input [2:0] skill_charge,
	input [7:0] skill_timer,
	input [1:0] skill_sel,      // 0 = Ember, 1 = Gold, 2 = Lure
	input [2:0] score_mult,     // combo streak, or 3 while Gold Rush runs
	input [2:0] hp,             // health, 0..HP_MAX
	input hurt,                 // just took damage: flash the score red
	input game_over,
	input btn_left,
	input btn_right,

	// input stream from previous layer
	input in_axis_tvalid,
	output in_axis_tready,
	input [SVO_BITS_PER_PIXEL-1:0] in_axis_tdata,
	input [0:0] in_axis_tuser,

	// output stream to next layer
	output out_axis_tvalid,
	input out_axis_tready,
	output [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output [0:0] out_axis_tuser
);
`SVO_DECLS

localparam UI_TOP = 416;
localparam UI_TOP_BAR_H = 16;   // dark bar above the background image band
localparam DIGIT_Y = 424;       // bottom UI bar
localparam DIGIT_W = 24;
localparam DIGIT_H = 48;
localparam DIGIT_GAP = 6;

localparam TIMER_X = 32;        // bottom-left
localparam SCORE_X = 263;       // bottom-center

// HP bar, bottom-right, in the slot the best score used to occupy. Five
// segments of 16 with a 4 px gap span 96 px, so 494..589 - clear of the right
// button indicator at 620. Vertically centred in the big-digit band
// (424..471) so it reads as a peer of the timer and score, not an afterthought.
localparam HP_X   = 494;
localparam HP_Y   = 436;
localparam HP_W   = 16;
localparam HP_H   = 24;
localparam HP_GAP = 4;
localparam HP_SEGMENTS = 5;
localparam CHARGE_X = 220;
localparam CHARGE_Y = 474;
localparam CHARGE_W = 36;
localparam CHARGE_H = 6;
localparam CHARGE_GAP = 4;
localparam SKILL_TIME_X = 430;
localparam SKILL_TIME_Y = 452;
localparam COMBO_X = 410;        // next to score
localparam COMBO_Y = 424;
localparam SMALL_DIGIT_W = 12;
localparam SMALL_DIGIT_H = 24;
localparam SMALL_DIGIT_GAP = 3;

// 6x12 base glyph shared by all digits (see src/assets/font.mem)
localparam FONT_W = 6;
localparam FONT_H = 12;

localparam [23:0] UI_BG_RGB      = 24'h181818;
localparam [23:0] TIMER_RGB      = 24'hE8E8E8;
localparam [23:0] TIMER_LOW_RGB  = 24'h4040FF;  // BGR888: red, last 10 seconds
localparam [23:0] SCORE_RGB      = 24'h20E0FF;
localparam [23:0] SCORE_HURT_RGB = 24'h4040FF;  // red flash on losing heat
// HP: filled segments are bright green, spent ones stay as dark sockets so the
// maximum is always visible - an empty gap would just look like missing UI.
// Down to the last segment the whole bar turns red, which is the one piece of
// state worth shouting about.
localparam [23:0] HP_FULL_RGB    = 24'h40E040;
localparam [23:0] HP_LOW_RGB     = 24'h4040FF;  // BGR888: red
localparam [23:0] HP_EMPTY_RGB   = 24'h303030;
localparam [23:0] INDICATOR_RGB  = 24'h20FF40;
localparam [23:0] CHARGE_RGB     = 24'hFFEA20;
localparam [23:0] COMBO_RGB      = 24'h40E0FF;  // amber-ish, matches the charge

// The skill timer takes the colour of the equipped skill. All three skills
// draw the same burning-fox sprite, so without this there is no way to tell
// on screen which one is running.
localparam [23:0] SKILL_EMBER_RGB = 24'h2080FF;  // orange
localparam [23:0] SKILL_GOLD_RGB  = 24'h20D0FF;  // gold
localparam [23:0] SKILL_LURE_RGB  = 24'hC0FF20;  // cyan-green

reg [`SVO_XYBITS-1:0] hcursor, vcursor;
reg [4:0] blink_cnt;
reg blink_on;

wire fire = in_axis_tvalid && in_axis_tready;
wire [`SVO_XYBITS-1:0] pixel_x = in_axis_tuser[0] ? 0 : hcursor;
wire [`SVO_XYBITS-1:0] pixel_y = in_axis_tuser[0] ? 0 : vcursor;

wire [3:0] timer_d2 = timer_bcd[11:8];
wire [3:0] timer_d1 = timer_bcd[7:4];
wire [3:0] timer_d0 = timer_bcd[3:0];

wire [3:0] score_d2 = score_bcd[11:8];
wire [3:0] score_d1 = score_bcd[7:4];
wire [3:0] score_d0 = score_bcd[3:0];


wire skill_timer_ge_10 = skill_timer >= 10;
wire [3:0] skill_timer_d1 = skill_timer_ge_10 ? 1 : 0;
wire [3:0] skill_timer_d0 = skill_timer_ge_10 ? skill_timer - 10 : skill_timer[3:0];
wire skill_small_on = SKILL_ENABLE && (skill_timer != 0);

// For a big-digit field at base X, report which of the 3 columns the current
// pixel hits: {hit(1), col(2), local_x(5)}.
function [7:0] big_col;
	input [`SVO_XYBITS-1:0] px;
	input [`SVO_XYBITS-1:0] base;
	integer i;
	reg [`SVO_XYBITS-1:0] dleft;
	reg [4:0] lx;
	begin
		big_col = 8'd0;
		for (i = 0; i < 3; i = i + 1) begin
			dleft = base + i * (DIGIT_W + DIGIT_GAP);
			if (px >= dleft && px < dleft + DIGIT_W) begin
				lx = px - dleft;
				big_col = {1'b1, i[1:0], lx};
			end
		end
	end
endfunction

// Same, for the 2-digit small (skill timer) field.
function [7:0] small_col;
	input [`SVO_XYBITS-1:0] px;
	input [`SVO_XYBITS-1:0] base;
	integer i;
	reg [`SVO_XYBITS-1:0] dleft;
	reg [4:0] lx;
	begin
		small_col = 8'd0;
		for (i = 0; i < 2; i = i + 1) begin
			dleft = base + i * (SMALL_DIGIT_W + SMALL_DIGIT_GAP);
			if (px >= dleft && px < dleft + SMALL_DIGIT_W) begin
				lx = px - dleft;
				small_col = {1'b1, i[1:0], lx};
			end
		end
	end
endfunction

// 1-digit combo multiplier (x1, x2, x3)
function [7:0] combo_col;
	input [`SVO_XYBITS-1:0] px;
	input [`SVO_XYBITS-1:0] base;
	reg [`SVO_XYBITS-1:0] dleft;
	reg [4:0] lx;
	begin
		combo_col = 8'd0;
		dleft = base;
		if (px >= dleft && px < dleft + SMALL_DIGIT_W) begin
			lx = px - dleft;
			combo_col = {1'b1, 2'd0, lx};
		end
	end
endfunction

function charge_bar_pixel;
	input [`SVO_XYBITS-1:0] x;
	input [`SVO_XYBITS-1:0] y;
	input [2:0] charge;

	integer j;
	reg [`SVO_XYBITS-1:0] bar_x;
	begin
		charge_bar_pixel = 0;

		if (y >= CHARGE_Y && y < CHARGE_Y + CHARGE_H) begin
			for (j = 0; j < 5; j = j + 1) begin
				bar_x = CHARGE_X + j * (CHARGE_W + CHARGE_GAP);

				if (charge > j &&
					x >= bar_x && x < bar_x + CHARGE_W) begin
					charge_bar_pixel = 1;
				end
			end
		end
	end
endfunction

// HP bar. Returns {inside a segment, that segment is filled} so one pass over
// the five rectangles serves both the "is anything drawn here" test and the
// colour choice - two separate functions would double the compare count, and
// there is no logic budget for that.
function [1:0] hp_bar_pixel;
	input [`SVO_XYBITS-1:0] x;
	input [`SVO_XYBITS-1:0] y;
	input [2:0] health;

	integer j;
	reg [`SVO_XYBITS-1:0] seg_x;
	begin
		hp_bar_pixel = 2'b00;

		if (y >= HP_Y && y < HP_Y + HP_H) begin
			for (j = 0; j < HP_SEGMENTS; j = j + 1) begin
				seg_x = HP_X + j * (HP_W + HP_GAP);
				if (x >= seg_x && x < seg_x + HP_W)
					hp_bar_pixel = {1'b1, health > j};
			end
		end
	end
endfunction

// Combinational: for this pixel, decide which glyph cell it lands in, its BCD
// value, colour field, and the 6x12 source coordinate (screen coords scaled
// down by replication: big = >>2 for 24x48, small = >>1 for 12x24).
reg        glyph_hit;
reg [2:0]  field;        // 0=timer 1=score 2=high 3=skill(small) 4=combo
reg [3:0]  digit;
reg [2:0]  src_x;
reg [3:0]  src_y;

reg [7:0]  tcol, scol, kcol, ccol;
reg [4:0]  lx_sel;
reg [`SVO_XYBITS-1:0] ly_big, ly_small;

always @(*) begin
	glyph_hit = 1'b0;
	field     = 3'd0;
	digit     = 4'd0;
	src_x     = 3'd0;
	src_y     = 4'd0;
	lx_sel    = 5'd0;
	ly_big    = 0;
	ly_small  = 0;

	tcol = big_col(pixel_x, TIMER_X);
	scol = big_col(pixel_x, SCORE_X);
	kcol = small_col(pixel_x, SKILL_TIME_X);
	ccol = combo_col(pixel_x, COMBO_X);

	if (pixel_y >= DIGIT_Y && pixel_y < DIGIT_Y + DIGIT_H) begin
		ly_big = pixel_y - DIGIT_Y;
		if (tcol[7]) begin
			glyph_hit = 1'b1; field = 3'd0; lx_sel = tcol[4:0];
			case (tcol[6:5])
				2'd0: digit = timer_d2;
				2'd1: digit = timer_d1;
				default: digit = timer_d0;
			endcase
			src_x = lx_sel[4:2];
			src_y = ly_big[5:2];
		end else if (scol[7]) begin
			glyph_hit = 1'b1; field = 3'd1; lx_sel = scol[4:0];
			case (scol[6:5])
				2'd0: digit = score_d2;
				2'd1: digit = score_d1;
				default: digit = score_d0;
			endcase
			src_x = lx_sel[4:2];
			src_y = ly_big[5:2];
		end
	end

	// Small (skill timer) field is checked independently: its Y band overlaps
	// the big-digit band but its X range is disjoint, so a pixel is in at most
	// one glyph. Only reachable when the big field did not already claim it.
	if (!glyph_hit && skill_small_on &&
		pixel_y >= SKILL_TIME_Y && pixel_y < SKILL_TIME_Y + SMALL_DIGIT_H) begin
		ly_small = pixel_y - SKILL_TIME_Y;
		if (kcol[7]) begin
			glyph_hit = 1'b1; field = 3'd3; lx_sel = kcol[4:0];
			case (kcol[6:5])
				2'd0: digit = skill_timer_d1;
				default: digit = skill_timer_d0;
			endcase
			src_x = lx_sel[3:1];
			src_y = ly_small[4:1];
		end
	end

	// Score multiplier (x2, x3) - shown next to score when > 1
	if (!glyph_hit && (score_mult > 3'd1) &&
		pixel_y >= COMBO_Y && pixel_y < COMBO_Y + SMALL_DIGIT_H) begin
		ly_small = pixel_y - COMBO_Y;
		if (ccol[7]) begin
			glyph_hit = 1'b1; field = 3'd4; lx_sel = ccol[4:0];
			digit = score_mult;  // just show 2 or 3
			src_x = lx_sel[3:1];
			src_y = ly_small[4:1];
		end
	end
end

wire [7:0] font_addr = {digit, src_y};
wire [5:0] font_row;

(* ramstyle = "distributed" *) rom #(
	.DATA_WIDTH(6),
	.ADDR_WIDTH(8),
	.DEPTH(160),
	.INIT_FILE("src/assets/font.mem")
) u_font_rom (
	.clk(clk),
	.addr(font_addr),
	.data(font_row)
);

// Non-glyph overlay decisions (cheap rectangles), all combinational this cycle.
wire score_on = !game_over || blink_on;
wire in_ui = (pixel_y >= UI_TOP) || (pixel_y < UI_TOP_BAR_H);

// The clock is BCD and clamped to 99, so "under ten seconds" is just "the tens
// digit is zero" - no binary compare needed. Deliberately does NOT look at
// timer_bcd[11:8]: bin2bcd7 only drives two digits, and game_ctrl ties the
// hundreds nibble low rather than leaving it floating.
wire timer_low = timer_bcd[7:4] == 4'd0;

wire [23:0] skill_rgb = (skill_sel == 2'd0) ? SKILL_EMBER_RGB :
						(skill_sel == 2'd1) ? SKILL_GOLD_RGB  : SKILL_LURE_RGB;
wire charge_pixel = SKILL_ENABLE && charge_bar_pixel(pixel_x, pixel_y, skill_charge);
wire [1:0] hp_px = hp_bar_pixel(pixel_x, pixel_y, hp);
wire hp_in_bar = hp_px[1];
wire hp_filled = hp_px[0];
wire hp_low    = hp <= 3'd1;
wire left_indicator = btn_left && pixel_y >= UI_TOP + 8 && pixel_y < UI_TOP + 56 &&
						pixel_x >= 4 && pixel_x < 20;
wire right_indicator = btn_right && pixel_y >= UI_TOP + 8 && pixel_y < UI_TOP + 56 &&
						pixel_x >= SVO_HOR_PIXELS - 20 && pixel_x < SVO_HOR_PIXELS - 4;

// 1-stage pipeline to line up with the registered font ROM read (1 cycle).
reg glyph_hit_d;
reg [2:0] field_d;
reg [2:0] src_x_d;
reg [SVO_BITS_PER_PIXEL-1:0] bg_d;
reg [0:0] tuser_d;
reg tvalid_d;
reg score_on_d;
reg left_ind_d, right_ind_d, charge_d, in_ui_d;
reg hp_in_bar_d, hp_filled_d;

assign in_axis_tready  = out_axis_tready;
assign out_axis_tvalid = tvalid_d;
assign out_axis_tuser  = tuser_d;

wire glyph_on = glyph_hit_d & font_row[3'd5 - src_x_d];

// timer_low / hurt / skill_rgb are used unpipelined on purpose. Every other
// term here has to be delayed a cycle because it depends on the pixel being
// drawn and must line up with the font ROM read; these three change at most
// once per frame, so a one-pixel skew lands in the dark top-left corner and
// they cost no registers - which matters, the design places at 100% CLS.
assign out_axis_tdata =
	left_ind_d                              ? INDICATOR_RGB :
	right_ind_d                             ? INDICATOR_RGB :
	(glyph_on && field_d == 3'd0)               ? (timer_low ? TIMER_LOW_RGB : TIMER_RGB) :
	(glyph_on && field_d == 3'd1 && score_on_d) ? (hurt ? SCORE_HURT_RGB : SCORE_RGB) :
	(glyph_on && field_d == 3'd3)               ? skill_rgb :
	(glyph_on && field_d == 3'd4)               ? COMBO_RGB :
	hp_in_bar_d                             ? (hp_filled_d ? (hp_low ? HP_LOW_RGB : HP_FULL_RGB)
													       : HP_EMPTY_RGB) :
	charge_d                                ? CHARGE_RGB :
	in_ui_d                                 ? UI_BG_RGB :
											  bg_d;

always @(posedge clk) begin
	if (!resetn) begin
		glyph_hit_d <= 0;
		field_d <= 0;
		src_x_d <= 0;
		bg_d <= 0;
		tuser_d <= 0;
		tvalid_d <= 0;
		score_on_d <= 0;
		left_ind_d <= 0;
		right_ind_d <= 0;
		charge_d <= 0;
		in_ui_d <= 0;
		hp_in_bar_d <= 0;
		hp_filled_d <= 0;
	end else if (out_axis_tready) begin
		tvalid_d <= in_axis_tvalid;
		if (fire) begin
			glyph_hit_d <= glyph_hit;
			field_d <= field;
			src_x_d <= src_x;
			bg_d <= in_axis_tdata;
			tuser_d <= in_axis_tuser;
			score_on_d <= score_on;
			left_ind_d <= left_indicator;
			right_ind_d <= right_indicator;
			charge_d <= charge_pixel;
			in_ui_d <= in_ui;
			hp_in_bar_d <= hp_in_bar;
			hp_filled_d <= hp_filled;
		end
	end
end

always @(posedge clk) begin
	if (!resetn) begin
		blink_cnt <= 0;
		blink_on <= 1'b1;
	end else if (fire) begin
		if (in_axis_tuser[0] && game_over) begin
			if (blink_cnt == 5'd29) begin
				blink_cnt <= 5'd0;
				blink_on <= !blink_on;
			end else begin
				blink_cnt <= blink_cnt + 1'b1;
			end
		end else if (!game_over) begin
			blink_cnt <= 5'd0;
			blink_on <= 1'b1;
		end
	end
end

always @(posedge clk) begin
	if (!resetn) begin
		hcursor <= 0;
		vcursor <= 0;
	end else if (fire) begin
		if (in_axis_tuser[0]) begin
			hcursor <= 1;
			vcursor <= 0;
		end else if (hcursor == SVO_HOR_PIXELS - 1) begin
			hcursor <= 0;
			if (vcursor == SVO_VER_PIXELS - 1)
				vcursor <= 0;
			else
				vcursor <= vcursor + 1;
		end else begin
			hcursor <= hcursor + 1;
		end
	end
end
endmodule
