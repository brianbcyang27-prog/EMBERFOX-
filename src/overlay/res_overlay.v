`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

module res_overlay #(
	`SVO_DEFAULT_PARAMS
) (
	input clk,
	input resetn,

	// 0 = hidden (playing), 1 = run over, 2 = difficulty menu, 3 = skill menu,
	// 4 = how-to-play screen, 5 = pre-game countdown
	input [2:0] mode,
	input [2:0] title_id,
	input [1:0] menu_sel,
	input [2:0] count_val,          // 5..1 during the pre-game countdown
	input [11:0] score_bcd,
	input [11:0] high_score_bcd,

	input in_axis_tvalid,
	output in_axis_tready,
	input [SVO_BITS_PER_PIXEL-1:0] in_axis_tdata,
	input [0:0] in_axis_tuser,

	output out_axis_tvalid,
	input out_axis_tready,
	output [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output [0:0] out_axis_tuser
);
`SVO_DECLS

localparam [9:0] PANEL_X0 = 10'd128;
localparam [9:0] PANEL_X1 = 10'd512;
localparam [9:0] PANEL_Y0 = 10'd128;
localparam [9:0] PANEL_Y1 = 10'd352;
localparam [9:0] BORDER_T = 10'd4;

// Text layout. All glyphs come from the shared 6x12 res_font ROM and are
// scaled by power-of-2 replication (title/value x4 -> 24x48, labels/body x2 ->
// 12x24, countdown digit x8 -> 48x96). The title base X and char count move
// with the word so every heading is centred.
localparam [9:0] TITLE_Y       = 10'd140;
localparam [9:0] TITLE_STRIDE  = 10'd28;   // (6+1) * 4
localparam [9:0] TITLE_GW      = 10'd24;   // 6 * 4
// Each base X centres its word on the 320 pixel panel centre. Word widths:
// 4 chars -> 108px, 5 -> 136, 6 -> 164, 7 -> 192, 9 -> 248, 11 -> 304.
localparam [9:0] TITLE_X_TIMEUP = 10'd222; // "TIME UP"        (7 chars)
localparam [9:0] TITLE_X_EASY   = 10'd266; // "EASY"           (4 chars)
localparam [9:0] TITLE_X_NORMAL = 10'd238; // "NORMAL"         (6 chars)
localparam [9:0] TITLE_X_HARD   = 10'd266; // "HARD"           (4 chars)
localparam [9:0] TITLE_X_EMBER  = 10'd252; // "EMBER"          (5 chars)
localparam [9:0] TITLE_X_TIME   = 10'd266; // "TIME"           (4 chars)
localparam [9:0] TITLE_X_LURE   = 10'd266; // "LURE"           (4 chars)
localparam [9:0] TITLE_X_HOWTO  = 10'd166; // "HOW TO PLAY"    (11 chars)
localparam [9:0] TITLE_X_READY  = 10'd194; // "GET READY"      (9 chars)

// Body text, scale 2, left-aligned at BODY_X. The menu uses lines 0-1 as a
// short game description under the option dots; the how-to screen uses 0-3.
localparam [9:0] BODY_X       = 10'd160;
localparam [9:0] BODY_STRIDE  = 10'd14;    // (6+1) * 2
localparam [9:0] BODY_GW      = 10'd12;    // 6 * 2
localparam [9:0] BODY_NCHARS  = 6'd24;     // longest line
localparam [9:0] BODY_Y_GAP   = 10'd28;
localparam [9:0] MENU_BODY_Y0 = 10'd236;   // below the option dots

// Full-screen how-to page: the title sits high and five centred body lines
// spread down the screen, over a full black page (the panel is disabled).
localparam [9:0] HOWTO_TITLE_Y    = 10'd48;
localparam [9:0] HOWTO_BODY_Y0_FS = 10'd144;
localparam [9:0] HOWTO_BODY_STRIDE = 10'd56;
localparam [9:0] HOWTO_X0   = 10'd160;  // "CATCH EMBERS FOR POINTS"  (23 chars)
localparam [9:0] HOWTO_X1   = 10'd195;  // "JUMP THE OBSTACLES"       (18)
localparam [9:0] HOWTO_X2   = 10'd181;  // "LEFT OR RIGHT TO MOVE"    (20)
localparam [9:0] HOWTO_X3   = 10'd181;  // "PRESS JUMP WHEN READY"    (20)
localparam [9:0] HOWTO_X_HINT = 10'd230; // "JUMP TO START"           (13)

// Menu button legend, scale 2, centred: tells the player which button to press.
localparam [9:0] HINT1_Y = 10'd292;        // "SELECT LEFT OR RIGHT"  (20 chars)
localparam [9:0] HINT1_X = 10'd181;
localparam [9:0] HINT2_Y = 10'd320;        // "JUMP TO CONFIRM"       (15 chars)
localparam [9:0] HINT2_X = 10'd216;

// Countdown digit, scale 8 (48x96), centred on the panel.
localparam [9:0] COUNT_X = 10'd296;
localparam [9:0] COUNT_Y = 10'd200;
localparam [9:0] COUNT_GW = 10'd48;

localparam [9:0] LABEL_STRIDE  = 10'd14;   // (6+1) * 2
localparam [9:0] LABEL_GW      = 10'd12;   // 6 * 2
localparam [9:0] SCORE_LABEL_X = 10'd152;
localparam [9:0] SCORE_LABEL_Y = 10'd228;
localparam [9:0] BEST_LABEL_X  = 10'd152;
localparam [9:0] BEST_LABEL_Y  = 10'd300;

localparam [9:0] VALUE_X       = 10'd300;
localparam [9:0] VAL_STRIDE    = 10'd32;   // (6+2) * 4
localparam [9:0] VAL_GW        = 10'd24;   // 6 * 4
localparam [9:0] SCORE_VAL_Y   = 10'd216;
localparam [9:0] BEST_VAL_Y    = 10'd288;

// glyph indices in res_font.mem
localparam GLYPH_SPACE = 6'd10;
// 11..36 = A..Z, 0..9 = digits, 10 = space

// char codes: 0..25 = A-Z, 26..35 = 0-9, 36 = space
localparam [5:0] CH_A = 6'd0, CH_B = 6'd1, CH_C = 6'd2, CH_D = 6'd3, CH_E = 6'd4,
                 CH_F = 6'd5, CH_G = 6'd6, CH_H = 6'd7, CH_I = 6'd8, CH_J = 6'd9,
                 CH_K = 6'd10, CH_L = 6'd11, CH_M = 6'd12, CH_N = 6'd13, CH_O = 6'd14,
                 CH_P = 6'd15, CH_Q = 6'd16, CH_R = 6'd17, CH_S = 6'd18, CH_T = 6'd19,
                 CH_U = 6'd20, CH_V = 6'd21, CH_W = 6'd22, CH_X = 6'd23, CH_Y = 6'd24,
                 CH_Z = 6'd25, CH_SP = 6'd36;

localparam [1:0] TXT_HEAT  = 2'd1;
localparam [1:0] TXT_BEST  = 2'd2;

// title_id values, matching game_ctrl
localparam TITLE_TIMEUP = 3'd0;
localparam TITLE_EASY   = 3'd1;
localparam TITLE_NORMAL = 3'd2;
localparam TITLE_HARD   = 3'd3;
localparam TITLE_EMBER  = 3'd4;
localparam TITLE_TIME   = 3'd5;
localparam TITLE_LURE   = 3'd6;

// The three little option dots under the menu title
localparam [9:0] DOT_Y  = 10'd212;
localparam [9:0] DOT_H  = 10'd20;
localparam [9:0] DOT_W  = 10'd40;
localparam [9:0] DOT_X0 = 10'd242;
localparam [9:0] DOT_GAP = 10'd20;

localparam [23:0] COLOR_PANEL  = 24'h000000;
localparam [23:0] COLOR_BORDER = 24'hFFFFFF;
localparam [23:0] COLOR_TEXT   = 24'hFFFFFF;
localparam [23:0] COLOR_TITLE  = 24'h20EAFF;
localparam [23:0] COLOR_DOT_ON  = 24'h20EAFF;   // the chosen option
localparam [23:0] COLOR_DOT_OFF = 24'h404040;   // the other two

`ifdef RES_OVERLAY_DIM
localparam DIM_BACKGROUND = 1;
`else
localparam DIM_BACKGROUND = 0;
`endif

reg [`SVO_XYBITS-1:0] hcursor;
reg [`SVO_XYBITS-1:0] vcursor;

wire fire = in_axis_tvalid && in_axis_tready;
wire [`SVO_XYBITS-1:0] pixel_x = in_axis_tuser[0] ? 0 : hcursor;
wire [`SVO_XYBITS-1:0] pixel_y = in_axis_tuser[0] ? 0 : vcursor;

wire show        = mode != 3'd0;
wire show_result = mode == 3'd1;
wire show_menu   = (mode == 3'd2) || (mode == 3'd3);
wire show_howto  = mode == 3'd4;
wire show_count  = mode == 3'd5;

wire in_panel =
	pixel_x >= PANEL_X0 && pixel_x < PANEL_X1 &&
	pixel_y >= PANEL_Y0 && pixel_y < PANEL_Y1;

// Three little boxes under the title; the chosen one is filled bright.
reg dot_on;
reg dot_sel;
integer d;
reg [9:0] dot_left;

always @(*) begin
	dot_on = 1'b0;
	dot_sel = 1'b0;
	dot_left = 10'd0;

	if (show_menu && pixel_y >= DOT_Y && pixel_y < DOT_Y + DOT_H) begin
		for (d = 0; d < 3; d = d + 1) begin
			dot_left = DOT_X0 + d * (DOT_W + DOT_GAP);
			if (pixel_x >= dot_left && pixel_x < dot_left + DOT_W) begin
				dot_on = 1'b1;
				if (menu_sel == d[1:0]) dot_sel = 1'b1;
			end
		end
	end
end

wire in_border =
	in_panel &&
	(pixel_x < PANEL_X0 + BORDER_T ||
	 pixel_x >= PANEL_X1 - BORDER_T ||
	 pixel_y < PANEL_Y0 + BORDER_T ||
	 pixel_y >= PANEL_Y1 - BORDER_T);

function [23:0] dim_bgr888;
	input [23:0] rgb;
	begin
		dim_bgr888 = {1'b0, rgb[23:17], 1'b0, rgb[15:9], 1'b0, rgb[7:1]};
	end
endfunction

// Map a char code to a res_font glyph index.
function [5:0] glyph_of;
	input [5:0] ch;               // 0..25 = A-Z, 26..35 = 0-9, 36 = space
	begin
		if (ch == CH_SP)
			glyph_of = GLYPH_SPACE;
		else if (ch < 6'd26)
			glyph_of = 6'd11 + ch;        // A-Z
		else
			glyph_of = ch - 6'd26;        // 0-9
	end
endfunction

// The heading line, chosen by which screen is up. mode 2/3 reuse title_id for
// the highlighted difficulty / skill name.
function [5:0] title_glyph;
	input [2:0] mode;
	input [2:0] tsel;              // title_id
	input [5:0] idx;
	begin
		title_glyph = GLYPH_SPACE;
		case (mode)
			3'd1: case (idx)           // "TIME UP"
				0: title_glyph = glyph_of(CH_T);  1: title_glyph = glyph_of(CH_I);
				2: title_glyph = glyph_of(CH_M);  3: title_glyph = glyph_of(CH_E);
				5: title_glyph = glyph_of(CH_U);  6: title_glyph = glyph_of(CH_P);
				default: title_glyph = GLYPH_SPACE;
			endcase
			3'd2: case (tsel)
				TITLE_EASY: case (idx) // "EASY"
					0: title_glyph = glyph_of(CH_E);  1: title_glyph = glyph_of(CH_A);
					2: title_glyph = glyph_of(CH_S);  3: title_glyph = glyph_of(CH_Y);
					default: title_glyph = GLYPH_SPACE;
				endcase
				TITLE_NORMAL: case (idx) // "NORMAL"
					0: title_glyph = glyph_of(CH_N);  1: title_glyph = glyph_of(CH_O);
					2: title_glyph = glyph_of(CH_R);  3: title_glyph = glyph_of(CH_M);
					4: title_glyph = glyph_of(CH_A);  5: title_glyph = glyph_of(CH_L);
					default: title_glyph = GLYPH_SPACE;
				endcase
				default: case (idx)    // "HARD"
					0: title_glyph = glyph_of(CH_H);  1: title_glyph = glyph_of(CH_A);
					2: title_glyph = glyph_of(CH_R);  3: title_glyph = glyph_of(CH_D);
					default: title_glyph = GLYPH_SPACE;
				endcase
			endcase
			3'd3: case (tsel)
				TITLE_EMBER: case (idx) // "EMBER"
					0: title_glyph = glyph_of(CH_E);  1: title_glyph = glyph_of(CH_M);
					2: title_glyph = glyph_of(CH_B);  3: title_glyph = glyph_of(CH_E);
					4: title_glyph = glyph_of(CH_R);
					default: title_glyph = GLYPH_SPACE;
				endcase
				TITLE_TIME: case (idx)  // "TIME"
					0: title_glyph = glyph_of(CH_T);  1: title_glyph = glyph_of(CH_I);
					2: title_glyph = glyph_of(CH_M);  3: title_glyph = glyph_of(CH_E);
					default: title_glyph = GLYPH_SPACE;
				endcase
				default: case (idx)    // "LURE"
					0: title_glyph = glyph_of(CH_L);  1: title_glyph = glyph_of(CH_U);
					2: title_glyph = glyph_of(CH_R);  3: title_glyph = glyph_of(CH_E);
					default: title_glyph = GLYPH_SPACE;
				endcase
			endcase
			3'd4: case (idx)          // "HOW TO PLAY"
				0: title_glyph = glyph_of(CH_H);  1: title_glyph = glyph_of(CH_O);
				2: title_glyph = glyph_of(CH_W);  4: title_glyph = glyph_of(CH_T);
				5: title_glyph = glyph_of(CH_O);  7: title_glyph = glyph_of(CH_P);
				8: title_glyph = glyph_of(CH_L);  9: title_glyph = glyph_of(CH_A);
				10: title_glyph = glyph_of(CH_Y);
				default: title_glyph = GLYPH_SPACE;
			endcase
			default: case (idx)        // "GET READY"
				0: title_glyph = glyph_of(CH_G);  1: title_glyph = glyph_of(CH_E);
				2: title_glyph = glyph_of(CH_T);  4: title_glyph = glyph_of(CH_R);
				5: title_glyph = glyph_of(CH_E);  6: title_glyph = glyph_of(CH_A);
				7: title_glyph = glyph_of(CH_D);  8: title_glyph = glyph_of(CH_Y);
				default: title_glyph = GLYPH_SPACE;
			endcase
		endcase
	end
endfunction

// The body text: one shared 24-char field whose content depends on which line
// the pixel is in. Lines 0-1 double as the menu description and the top of the
// how-to list; lines 2-3 are how-to only.
function [5:0] body_char;
	input [2:0] line;
	input [5:0] idx;
	begin
		body_char = CH_SP;
		case (line)
			3'd0: case (idx)        // "CATCH EMBERS FOR POINTS"
				0: body_char = CH_C;  1: body_char = CH_A;  2: body_char = CH_T;
				3: body_char = CH_C;  4: body_char = CH_H;  6: body_char = CH_E;
				7: body_char = CH_M;  8: body_char = CH_B;  9: body_char = CH_E;
				10: body_char = CH_R; 11: body_char = CH_S; 13: body_char = CH_F;
				14: body_char = CH_O; 15: body_char = CH_R; 17: body_char = CH_P;
				18: body_char = CH_O; 19: body_char = CH_I; 20: body_char = CH_N;
				21: body_char = CH_T; 22: body_char = CH_S;
				default: body_char = CH_SP;
			endcase
			3'd1: case (idx)         // "JUMP THE OBSTACLES"
				0: body_char = CH_J;  1: body_char = CH_U;  2: body_char = CH_M;
				3: body_char = CH_P;  5: body_char = CH_T;  6: body_char = CH_H;
				7: body_char = CH_E;  9: body_char = CH_O;  10: body_char = CH_B;
				11: body_char = CH_S; 12: body_char = CH_T; 13: body_char = CH_A;
				14: body_char = CH_C; 15: body_char = CH_L; 16: body_char = CH_E;
				17: body_char = CH_S;
				default: body_char = CH_SP;
			endcase
			3'd2: case (idx)         // "LEFT OR RIGHT TO MOVE"
				0: body_char = CH_L;  1: body_char = CH_E;  2: body_char = CH_F;
				3: body_char = CH_T;  5: body_char = CH_O;  6: body_char = CH_R;
				8: body_char = CH_R;  9: body_char = CH_I;  10: body_char = CH_G;
				11: body_char = CH_H; 12: body_char = CH_T; 14: body_char = CH_T;
				15: body_char = CH_O; 17: body_char = CH_M; 18: body_char = CH_O;
				19: body_char = CH_V; 20: body_char = CH_E;
				default: body_char = CH_SP;
			endcase
			3'd4: case (idx)         // "JUMP TO START"
				0: body_char = CH_J;  1: body_char = CH_U;  2: body_char = CH_M;
				3: body_char = CH_P;  5: body_char = CH_T;  6: body_char = CH_O;
				8: body_char = CH_S;  9: body_char = CH_T; 10: body_char = CH_A;
				11: body_char = CH_R; 12: body_char = CH_T;
				default: body_char = CH_SP;
			endcase
			default: case (idx)      // "PRESS JUMP WHEN READY"
				0: body_char = CH_P;  1: body_char = CH_R;  2: body_char = CH_E;
				3: body_char = CH_S;  4: body_char = CH_S;  6: body_char = CH_J;
				7: body_char = CH_U;  8: body_char = CH_M;  9: body_char = CH_P;
				11: body_char = CH_W; 12: body_char = CH_H; 13: body_char = CH_E;
				14: body_char = CH_N; 16: body_char = CH_R; 17: body_char = CH_E;
				18: body_char = CH_A; 19: body_char = CH_D; 20: body_char = CH_Y;
				default: body_char = CH_SP;
			endcase
		endcase
	end
endfunction

// The menu button legend: two centred lines telling the player which button
// does what. Line 0 = how to pick, line 1 = how to confirm.
function [5:0] hint_glyph;
	input [2:0] line;
	input [5:0] idx;
	begin
		hint_glyph = CH_SP;
		case (line)
			3'd0: case (idx)         // "SELECT LEFT OR RIGHT"
				0: hint_glyph = CH_S;  1: hint_glyph = CH_E;  2: hint_glyph = CH_L;
				3: hint_glyph = CH_E;  4: hint_glyph = CH_C;  5: hint_glyph = CH_T;
				7: hint_glyph = CH_L;  8: hint_glyph = CH_E;  9: hint_glyph = CH_F;
				10: hint_glyph = CH_T; 12: hint_glyph = CH_O; 13: hint_glyph = CH_R;
				15: hint_glyph = CH_R; 16: hint_glyph = CH_I; 17: hint_glyph = CH_G;
				18: hint_glyph = CH_H; 19: hint_glyph = CH_T;
				default: hint_glyph = CH_SP;
			endcase
			default: case (idx)      // "JUMP TO CONFIRM"
				0: hint_glyph = CH_J;  1: hint_glyph = CH_U;  2: hint_glyph = CH_M;
				3: hint_glyph = CH_P;  5: hint_glyph = CH_T;  6: hint_glyph = CH_O;
				8: hint_glyph = CH_C;  9: hint_glyph = CH_O; 10: hint_glyph = CH_N;
				11: hint_glyph = CH_F; 12: hint_glyph = CH_I; 13: hint_glyph = CH_R;
				14: hint_glyph = CH_M;
				default: hint_glyph = CH_SP;
			endcase
		endcase
	end
endfunction

// For a text field at base X with a given char stride & scaled glyph width,
// report which char the pixel hits: {hit(1), idx(5), local_x(7)}.
function [12:0] glyph_col;
	input [`SVO_XYBITS-1:0] px;
	input [9:0] base;
	input [9:0] stride;
	input [9:0] gw;
	input [5:0] nchars;
	integer i;
	reg [9:0] cleft;
	begin
		glyph_col = 13'd0;
		for (i = 0; i < 32; i = i + 1) begin
			if (i < nchars) begin
				cleft = base + i * stride;
				if (px >= cleft && px < cleft + gw) begin
					glyph_col[12]   = 1'b1;
					glyph_col[11:7] = i[4:0];
					glyph_col[6:0]  = px - cleft;
				end
			end
		end
	end
endfunction

// "HEAT" / "BEST" label glyphs (kept small - only these two fixed words).
function [5:0] label_glyph;
	input [1:0] tid;
	input [4:0] idx;
	begin
		label_glyph = GLYPH_SPACE;
		case (tid)
			TXT_HEAT: case (idx)         // "HEAT"
				5'd0: label_glyph = glyph_of(CH_H);
				5'd1: label_glyph = glyph_of(CH_E);
				5'd2: label_glyph = glyph_of(CH_A);
				5'd3: label_glyph = glyph_of(CH_T);
				default: label_glyph = GLYPH_SPACE;
			endcase
			default: case (idx)          // "BEST"
				5'd0: label_glyph = glyph_of(CH_B);
				5'd1: label_glyph = glyph_of(CH_E);
				5'd2: label_glyph = glyph_of(CH_S);
				5'd3: label_glyph = glyph_of(CH_T);
				default: label_glyph = GLYPH_SPACE;
			endcase
		endcase
	end
endfunction

// Combinational: pick the single text field this pixel lands in and compute
// the glyph index, source column (font_x) and row (font_y). Fields occupy
// disjoint screen regions, so an if-chain (guarded by !glyph_hit) is exact.
reg        glyph_hit;
reg        is_title;
reg [5:0]  glyph;
reg [2:0]  font_x;
reg [3:0]  font_y;

reg [12:0] gc;
reg [4:0]  ci;
reg [9:0]  title_base;
reg [5:0]  title_n;
reg [9:0]  title_y;
reg [2:0]  body_line;
reg [9:0]  body_y0;
reg [9:0]  body_x;
reg        body_vis;   // pixel is inside one of the body text lines

always @(*) begin
	glyph_hit = 1'b0;
	is_title  = 1'b0;
	glyph     = 6'd0;
	font_x    = 3'd0;
	font_y    = 4'd0;
	gc        = 13'd0;
	ci        = 5'd0;
	title_base = TITLE_X_EASY;
	title_n    = 6'd4;
	title_y    = TITLE_Y;
	body_line  = 3'd0;
	body_y0    = MENU_BODY_Y0;

	// Title line, scale 4. The base X, char count, and Y follow the heading.
	case (mode)
		3'd1: begin title_base = TITLE_X_TIMEUP; title_n = 6'd7; end
		3'd4: begin title_base = TITLE_X_HOWTO;  title_n = 6'd11; title_y = HOWTO_TITLE_Y; end
		3'd5: begin title_base = TITLE_X_READY;  title_n = 6'd9; end
		3'd2: case (title_id)
			TITLE_NORMAL: begin title_base = TITLE_X_NORMAL; title_n = 6'd6; end
			default:      begin title_base = TITLE_X_EASY;   title_n = 6'd4; end
		endcase
		default: case (title_id)
			TITLE_EMBER: begin title_base = TITLE_X_EMBER; title_n = 6'd5; end
			default:     begin title_base = TITLE_X_TIME;  title_n = 6'd4; end
		endcase
	endcase

	if (pixel_y >= title_y && pixel_y < title_y + 48) begin
		gc = glyph_col(pixel_x, title_base, TITLE_STRIDE, TITLE_GW, title_n);
		if (gc[12]) begin
			ci = gc[11:7];
			glyph = title_glyph(mode, title_id, ci);
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				is_title  = 1'b1;
				font_x    = gc[6:0] >> 2;
				font_y    = (pixel_y - title_y) >> 2;
			end
		end
	end

	// Body text, scale 2. Which of the lines (and its top Y) is picked by the
	// pixel row; all lines share one glyph_col field. body_vis stays 0 for the
	// gaps between lines so nothing is drawn there. The how-to page is full
	// screen and centres each line; the menu stays left-aligned under the dots.
	body_line = 3'd0;
	body_y0   = MENU_BODY_Y0;
	body_x    = BODY_X;
	body_vis  = 1'b0;
	if (show_howto) begin
		if      (pixel_y >= HOWTO_BODY_Y0_FS                                             && pixel_y < HOWTO_BODY_Y0_FS + 24) begin body_line = 3'd0; body_vis = 1'b1; end
		else if (pixel_y >= HOWTO_BODY_Y0_FS +     HOWTO_BODY_STRIDE                     && pixel_y < HOWTO_BODY_Y0_FS +     HOWTO_BODY_STRIDE + 24) begin body_line = 3'd1; body_vis = 1'b1; end
		else if (pixel_y >= HOWTO_BODY_Y0_FS + 2 * HOWTO_BODY_STRIDE                     && pixel_y < HOWTO_BODY_Y0_FS + 2 * HOWTO_BODY_STRIDE + 24) begin body_line = 3'd2; body_vis = 1'b1; end
		else if (pixel_y >= HOWTO_BODY_Y0_FS + 3 * HOWTO_BODY_STRIDE                     && pixel_y < HOWTO_BODY_Y0_FS + 3 * HOWTO_BODY_STRIDE + 24) begin body_line = 3'd3; body_vis = 1'b1; end
		else if (pixel_y >= HOWTO_BODY_Y0_FS + 4 * HOWTO_BODY_STRIDE                     && pixel_y < HOWTO_BODY_Y0_FS + 4 * HOWTO_BODY_STRIDE + 24) begin body_line = 3'd4; body_vis = 1'b1; end
		body_y0 = HOWTO_BODY_Y0_FS + {1'b0, body_line} * HOWTO_BODY_STRIDE;
		case (body_line)
			3'd0:   body_x = HOWTO_X0;
			3'd1:   body_x = HOWTO_X1;
			3'd2:   body_x = HOWTO_X2;
			3'd3:   body_x = HOWTO_X3;
			default: body_x = HOWTO_X_HINT;
		endcase
	end else if (show_menu) begin
		if      (pixel_y >= MENU_BODY_Y0                        && pixel_y < MENU_BODY_Y0 + 24) begin body_line = 3'd0; body_vis = 1'b1; end
		else if (pixel_y >= MENU_BODY_Y0 + BODY_Y_GAP           && pixel_y < MENU_BODY_Y0 + BODY_Y_GAP + 24) begin body_line = 3'd1; body_vis = 1'b1; end
		body_y0 = MENU_BODY_Y0 + {1'b0, body_line} * BODY_Y_GAP;
	end

	if (!glyph_hit && body_vis) begin
		gc = glyph_col(pixel_x, body_x, BODY_STRIDE, BODY_GW, BODY_NCHARS);
		if (gc[12]) begin
			ci = gc[11:7];
			glyph = glyph_of(body_char(body_line, ci));
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				font_x    = gc[6:0] >> 1;
				font_y    = (pixel_y - body_y0) >> 1;
			end
		end
	end

	// Countdown digit, scale 8.
	if (!glyph_hit && show_count &&
		pixel_y >= COUNT_Y && pixel_y < COUNT_Y + 96 &&
		pixel_x >= COUNT_X && pixel_x < COUNT_X + COUNT_GW) begin
		glyph     = {2'b00, count_val};
		glyph_hit = 1'b1;
		font_x    = (pixel_x - COUNT_X) >> 3;
		font_y    = (pixel_y - COUNT_Y) >> 3;
	end

	// Heat label "HEAT", scale 2. Only on the results screen - in the menu
	// this row is where the option dots go instead.
	if (!glyph_hit && show_result &&
		pixel_y >= SCORE_LABEL_Y && pixel_y < SCORE_LABEL_Y + 24) begin
		gc = glyph_col(pixel_x, SCORE_LABEL_X, LABEL_STRIDE, LABEL_GW, 6'd4);
		if (gc[12]) begin
			ci = gc[11:7];
			glyph = label_glyph(TXT_HEAT, ci);
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				font_x    = gc[6:0] >> 1;
				font_y    = (pixel_y - SCORE_LABEL_Y) >> 1;
			end
		end
	end

	// Best label "BEST", scale 2. Results screen only - the menu bottom rows
	// belong to the button legend instead.
	if (!glyph_hit && show_result &&
		pixel_y >= BEST_LABEL_Y && pixel_y < BEST_LABEL_Y + 24) begin
		gc = glyph_col(pixel_x, BEST_LABEL_X, LABEL_STRIDE, LABEL_GW, 6'd4);
		if (gc[12]) begin
			ci = gc[11:7];
			glyph = label_glyph(TXT_BEST, ci);
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				font_x    = gc[6:0] >> 1;
				font_y    = (pixel_y - BEST_LABEL_Y) >> 1;
			end
		end
	end

	// Heat value (3 BCD digits), scale 4. Results screen only.
	if (!glyph_hit && show_result &&
		pixel_y >= SCORE_VAL_Y && pixel_y < SCORE_VAL_Y + 48) begin
		gc = glyph_col(pixel_x, VALUE_X, VAL_STRIDE, VAL_GW, 6'd3);
		if (gc[12]) begin
			ci = gc[11:7];
			case (ci)
				5'd0: glyph = {1'b0, score_bcd[11:8]};
				5'd1: glyph = {1'b0, score_bcd[7:4]};
				default: glyph = {1'b0, score_bcd[3:0]};
			endcase
			glyph_hit = 1'b1;
			font_x    = gc[6:0] >> 2;
			font_y    = (pixel_y - SCORE_VAL_Y) >> 2;
		end
	end

	// Best value (3 BCD digits), scale 4
	if (!glyph_hit && show_result &&
		pixel_y >= BEST_VAL_Y && pixel_y < BEST_VAL_Y + 48) begin
		gc = glyph_col(pixel_x, VALUE_X, VAL_STRIDE, VAL_GW, 6'd3);
		if (gc[12]) begin
			ci = gc[11:7];
			case (ci)
				5'd0: glyph = {1'b0, high_score_bcd[11:8]};
				5'd1: glyph = {1'b0, high_score_bcd[7:4]};
				default: glyph = {1'b0, high_score_bcd[3:0]};
			endcase
			glyph_hit = 1'b1;
			font_x    = gc[6:0] >> 2;
			font_y    = (pixel_y - BEST_VAL_Y) >> 2;
		end
	end

	// Menu button legend, scale 2. Two centred lines in the bottom rows that
	// the BEST row used to occupy on the results screen.
	if (!glyph_hit && show_menu) begin
		if (pixel_y >= HINT1_Y && pixel_y < HINT1_Y + 24) begin
			gc = glyph_col(pixel_x, HINT1_X, BODY_STRIDE, BODY_GW, 6'd20);
			if (gc[12]) begin
				ci = gc[11:7];
				glyph = hint_glyph(3'd0, ci);
				if (glyph != GLYPH_SPACE) begin
					glyph_hit = 1'b1;
					font_x    = gc[6:0] >> 1;
					font_y    = (pixel_y - HINT1_Y) >> 1;
				end
			end
		end else if (pixel_y >= HINT2_Y && pixel_y < HINT2_Y + 24) begin
			gc = glyph_col(pixel_x, HINT2_X, BODY_STRIDE, BODY_GW, 6'd15);
			if (gc[12]) begin
				ci = gc[11:7];
				glyph = hint_glyph(3'd1, ci);
				if (glyph != GLYPH_SPACE) begin
					glyph_hit = 1'b1;
					font_x    = gc[6:0] >> 1;
					font_y    = (pixel_y - HINT2_Y) >> 1;
				end
			end
		end
	end
end

wire [9:0] font_addr = {glyph, font_y};
wire [5:0] font_row_bits;

rom #(
	.DATA_WIDTH(6),
	.ADDR_WIDTH(10),
	.DEPTH(1024),
	.INIT_FILE("src/assets/res_font.mem")
) u_res_font_rom (
	.clk(clk),
	.addr(font_addr),
	.data(font_row_bits)
);

// 1-stage pipeline to line up with the registered font ROM read (1 cycle),
// mirroring ui_layer / obj_layer.
reg glyph_hit_d;
reg is_title_d;
reg [2:0] font_x_d;
reg show_d;
reg howto_d;
reg in_panel_d;
reg in_border_d;
reg dot_on_d;
reg dot_sel_d;
reg [SVO_BITS_PER_PIXEL-1:0] base_d;
reg [0:0] tuser_d;
reg tvalid_d;

assign in_axis_tready  = out_axis_tready;
assign out_axis_tvalid = tvalid_d;
assign out_axis_tuser  = tuser_d;

wire glyph_on = glyph_hit_d & font_row_bits[3'd5 - font_x_d];
wire [23:0] dimmed = DIM_BACKGROUND ? dim_bgr888(base_d) : base_d;
wire [23:0] bg_sel = show_d ? dimmed : base_d;

// The how-to page is full screen: no panel box, just a black page with text.
assign out_axis_tdata =
	(show_d && glyph_on)                 ? (is_title_d ? COLOR_TITLE : COLOR_TEXT) :
	(show_d && dot_on_d)                 ? (dot_sel_d ? COLOR_DOT_ON : COLOR_DOT_OFF) :
	(show_d && in_border_d && !howto_d)  ? COLOR_BORDER :
	(show_d && in_panel_d  && !howto_d)  ? COLOR_PANEL :
	howto_d                              ? COLOR_PANEL :
										   bg_sel;

always @(posedge clk) begin
	if (!resetn) begin
		glyph_hit_d <= 0;
		is_title_d <= 0;
		font_x_d <= 0;
		show_d <= 0;
		howto_d <= 0;
		in_panel_d <= 0;
		in_border_d <= 0;
		dot_on_d <= 0;
		dot_sel_d <= 0;
		base_d <= 0;
		tuser_d <= 0;
		tvalid_d <= 0;
	end else if (out_axis_tready) begin
		tvalid_d <= in_axis_tvalid;
		if (fire) begin
			glyph_hit_d <= glyph_hit;
			is_title_d <= is_title;
			font_x_d <= font_x;
			show_d <= show;
			howto_d <= show_howto;
			dot_on_d <= dot_on;
			dot_sel_d <= dot_sel;
			in_panel_d <= in_panel;
			in_border_d <= in_border;
			base_d <= in_axis_tdata;
			tuser_d <= in_axis_tuser;
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
