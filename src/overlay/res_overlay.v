`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

// ---------------------------------------------------------------------------
// EMBERFOX - panel and menu overlay
//
// Five screens share one text renderer:
//
//   mode 1  results        TIME UP / HEAT nnn / BEST nnn / PLAY AGAIN  LEAVE
//   mode 2  difficulty     EASY | NORMAL | HARD
//   mode 3  skill          EMBER | GOLD | LURE
//   mode 4  how-to         full screen, no panel box
//   mode 5  countdown      GET READY + one big digit
//
// Every glyph comes from the shared 6x12 res_font ROM and is scaled by
// power-of-two replication: title x4 (24x48), body/labels x2 (12x24), the
// countdown digit x8 (48x96).
//
// ---------------------------------------------------------------------------
// Why there are exactly four glyph_col calls
//
// glyph_col is a 24-iteration loop of 14-bit compares and a subtract, and it
// is combinational, so every call site becomes its own copy in fabric. An
// earlier version called it eight times - and passed a RUNTIME character count,
// which meant none of the 24 iterations could ever fold away. On a part that
// places at 100% CLS that was the single most expensive thing in the design.
//
// There are now four call sites, one per text SIZE, and each is given a
// CONSTANT character count so the loop shrinks to exactly that many compares:
//
//   title   11 chars   scale 4    every heading
//   body    21 chars   scale 2    menu hints, how-to lines, results choice
//   label    4 chars   scale 2    HEAT and BEST (same X, disjoint rows)
//   value    3 chars   scale 4    the two BCD numbers (same X, disjoint rows)
//
// Fields shorter than the constant are safe: the glyph lookup returns SPACE
// past the end of the word and nothing is drawn.
// ---------------------------------------------------------------------------

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
	input [2:0] count_val,          // 3..1 during the pre-game countdown
	input [1:0] over_phase,         // 0 = score, 1 = best popped, 2 = choice up
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

// ---------------------------------------------------------------------------
// Text metrics
//
// Every base X below is the centred position for its own word, worked out
// from the glyph pitch rather than eyeballed:
//
//   scale 4:  width = 28n - 4    x = 322 - 14n
//   scale 2:  width = 14n - 2    x = 321 -  7n
// ---------------------------------------------------------------------------
localparam [9:0] TITLE_Y       = 10'd140;
localparam [9:0] TITLE_STRIDE  = 10'd28;   // (6+1) * 4
localparam [9:0] TITLE_GW      = 10'd24;   // 6 * 4
localparam [5:0] TITLE_NCHARS  = 6'd11;    // constant: the longest heading

localparam [9:0] TITLE_X_TIMEUP = 10'd224; // "TIME UP"      7
localparam [9:0] TITLE_X_EASY   = 10'd266; // "EASY"         4
localparam [9:0] TITLE_X_NORMAL = 10'd238; // "NORMAL"       6
localparam [9:0] TITLE_X_EMBER  = 10'd252; // "EMBER"        5
localparam [9:0] TITLE_X_HOWTO  = 10'd168; // "HOW TO PLAY" 11
localparam [9:0] TITLE_X_READY  = 10'd196; // "GET READY"    9

localparam [9:0] BODY_STRIDE  = 10'd14;    // (6+1) * 2
localparam [9:0] BODY_GW      = 10'd12;    // 6 * 2
localparam [5:0] BODY_NCHARS  = 6'd21;     // constant: the longest body line

// The seven body lines, and the centred X for each.
localparam [2:0] LN_MOVE   = 3'd0;   // "MOVE LEFT OR RIGHT"     18
localparam [2:0] LN_CONFIRM= 3'd1;   // "JUMP TO CONFIRM"        15
localparam [2:0] LN_CATCH  = 3'd2;   // "CATCH EMBERS FOR HEAT"  21
localparam [2:0] LN_RIDGES = 3'd3;   // "JUMP OR RIDGES HURT"    19
localparam [2:0] LN_SKILL  = 3'd4;   // "LEFT AND RIGHT SKILL"   21
localparam [2:0] LN_START  = 3'd5;   // "PRESS JUMP TO START"    19
localparam [2:0] LN_CHOICE = 3'd6;   // "PLAY AGAIN  LEAVE"      17
localparam [2:0] LN_NONE   = 3'd7;

localparam [9:0] X_MOVE    = 10'd195;
localparam [9:0] X_CONFIRM = 10'd216;
localparam [9:0] X_CATCH   = 10'd174;
localparam [9:0] X_RIDGES  = 10'd188;   // 19 chars: 321 - 7*19
localparam [9:0] X_SKILL   = 10'd174;
localparam [9:0] X_START   = 10'd188;
localparam [9:0] X_CHOICE  = 10'd202;

// Menu body rows. They sit below the option boxes and above the panel's
// bottom border (348). The previous layout drew these two lines AND then drew
// the very same two strings again 40 px lower as a separate "hint" block, so
// every menu page showed each instruction twice.
localparam [9:0] MENU_BODY_Y0 = 10'd252;
localparam [9:0] MENU_BODY_Y1 = 10'd288;

// Full-screen how-to page: title high, four evenly spaced lines under it.
localparam [9:0] HOWTO_TITLE_Y     = 10'd48;
localparam [9:0] HOWTO_BODY_Y0     = 10'd160;
localparam [9:0] HOWTO_BODY_STRIDE = 10'd56;

// Countdown digit, scale 8 (48x96), centred on 320.
localparam [9:0] COUNT_X = 10'd296;
localparam [9:0] COUNT_Y = 10'd200;
localparam [9:0] COUNT_GW = 10'd48;

// Results rows. LABEL_X / VALUE_X are shared by both rows, which is what lets
// the two labels share one glyph_col call and the two numbers share another.
localparam [9:0] LABEL_STRIDE  = 10'd14;   // (6+1) * 2
localparam [9:0] LABEL_GW      = 10'd12;   // 6 * 2
localparam [9:0] LABEL_X       = 10'd228;
localparam [9:0] SCORE_LABEL_Y = 10'd208;
localparam [9:0] BEST_LABEL_Y  = 10'd264;

localparam [9:0] VALUE_X       = 10'd322;
localparam [9:0] VAL_STRIDE    = 10'd32;   // (6+2) * 4
localparam [9:0] VAL_GW        = 10'd24;   // 6 * 4
localparam [9:0] SCORE_VAL_Y   = 10'd196;
localparam [9:0] BEST_VAL_Y    = 10'd252;

localparam [9:0] CHOICE_Y = 10'd318;

// glyph indices in res_font.mem: 0..9 = digits, 10 = space, 11..36 = A..Z
localparam GLYPH_SPACE = 6'd10;

// char codes: 0..25 = A-Z, 36 = space
localparam [5:0] CH_A = 6'd0, CH_B = 6'd1, CH_C = 6'd2, CH_D = 6'd3, CH_E = 6'd4,
                 CH_F = 6'd5, CH_G = 6'd6, CH_H = 6'd7, CH_I = 6'd8, CH_J = 6'd9,
                 CH_K = 6'd10, CH_L = 6'd11, CH_M = 6'd12, CH_N = 6'd13, CH_O = 6'd14,
                 CH_P = 6'd15, CH_Q = 6'd16, CH_R = 6'd17, CH_S = 6'd18, CH_T = 6'd19,
                 CH_U = 6'd20, CH_V = 6'd21, CH_W = 6'd22, CH_X = 6'd23, CH_Y = 6'd24,
                 CH_Z = 6'd25, CH_SP = 6'd36;

// title_id values, matching game_ctrl
localparam TITLE_TIMEUP = 3'd0;
localparam TITLE_EASY   = 3'd1;
localparam TITLE_NORMAL = 3'd2;
localparam TITLE_HARD   = 3'd3;
localparam TITLE_EMBER  = 3'd4;
localparam TITLE_GOLD   = 3'd5;
localparam TITLE_LURE   = 3'd6;

// The three option boxes under a menu title. DOT_X0 centres the row of three
// on 320: 3*40 + 2*20 = 160 wide, so it starts at 240.
localparam [9:0] DOT_Y  = 10'd212;
localparam [9:0] DOT_H  = 10'd20;
localparam [9:0] DOT_W  = 10'd40;
localparam [9:0] DOT_X0 = 10'd240;
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

// The best score appears at phase 1 and must STAY up at phase 2. Testing
// over_phase[0] hid it again the moment the PLAY AGAIN / LEAVE row appeared,
// because phase 2 is binary 10.
wire show_best   = show_result && (over_phase != 2'd0);
wire show_choice = show_result && over_phase[1];

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
	input [5:0] ch;               // 0..25 = A-Z, 36 = space
	begin
		if (ch >= 6'd26)
			glyph_of = GLYPH_SPACE;
		else
			glyph_of = 6'd11 + ch;        // A-Z
	end
endfunction

// The heading line, chosen by which screen is up. Menu modes reuse title_id
// for the highlighted difficulty / skill name.
function [5:0] title_char;
	input [2:0] scr;               // mode
	input [2:0] tsel;              // title_id
	input [5:0] idx;
	begin
		title_char = CH_SP;
		case (scr)
			3'd1: case (idx)           // "TIME UP"
				0: title_char = CH_T;  1: title_char = CH_I;
				2: title_char = CH_M;  3: title_char = CH_E;
				5: title_char = CH_U;  6: title_char = CH_P;
			endcase
			3'd4: case (idx)          // "HOW TO PLAY"
				0: title_char = CH_H;  1: title_char = CH_O;
				2: title_char = CH_W;  4: title_char = CH_T;
				5: title_char = CH_O;  7: title_char = CH_P;
				8: title_char = CH_L;  9: title_char = CH_A;
				10: title_char = CH_Y;
			endcase
			3'd5: case (idx)          // "GET READY"
				0: title_char = CH_G;  1: title_char = CH_E;
				2: title_char = CH_T;  4: title_char = CH_R;
				5: title_char = CH_E;  6: title_char = CH_A;
				7: title_char = CH_D;  8: title_char = CH_Y;
			endcase
			default: case (tsel)      // menu: the selected option's name
				TITLE_EASY: case (idx)      // "EASY"
					0: title_char = CH_E;  1: title_char = CH_A;
					2: title_char = CH_S;  3: title_char = CH_Y;
				endcase
				TITLE_NORMAL: case (idx)    // "NORMAL"
					0: title_char = CH_N;  1: title_char = CH_O;
					2: title_char = CH_R;  3: title_char = CH_M;
					4: title_char = CH_A;  5: title_char = CH_L;
				endcase
				TITLE_HARD: case (idx)      // "HARD"
					0: title_char = CH_H;  1: title_char = CH_A;
					2: title_char = CH_R;  3: title_char = CH_D;
				endcase
				TITLE_EMBER: case (idx)     // "EMBER"
					0: title_char = CH_E;  1: title_char = CH_M;
					2: title_char = CH_B;  3: title_char = CH_E;
					4: title_char = CH_R;
				endcase
				TITLE_GOLD: case (idx)      // "GOLD"
					0: title_char = CH_G;  1: title_char = CH_O;
					2: title_char = CH_L;  3: title_char = CH_D;
				endcase
				default: case (idx)         // "LURE"
					0: title_char = CH_L;  1: title_char = CH_U;
					2: title_char = CH_R;  3: title_char = CH_E;
				endcase
			endcase
		endcase
	end
endfunction

// The body text: one shared 21-char field whose content depends on which line
// the pixel is in.
function [5:0] body_char;
	input [2:0] line;
	input [5:0] idx;
	begin
		body_char = CH_SP;
		case (line)
			LN_MOVE: case (idx)          // "MOVE LEFT OR RIGHT"
				0: body_char = CH_M;  1: body_char = CH_O;  2: body_char = CH_V;
				3: body_char = CH_E;  5: body_char = CH_L;  6: body_char = CH_E;
				7: body_char = CH_F;  8: body_char = CH_T;  10: body_char = CH_O;
				11: body_char = CH_R; 13: body_char = CH_R; 14: body_char = CH_I;
				15: body_char = CH_G; 16: body_char = CH_H; 17: body_char = CH_T;
			endcase
			LN_CONFIRM: case (idx)       // "JUMP TO CONFIRM"
				0: body_char = CH_J;  1: body_char = CH_U;  2: body_char = CH_M;
				3: body_char = CH_P;  5: body_char = CH_T;  6: body_char = CH_O;
				8: body_char = CH_C;  9: body_char = CH_O;  10: body_char = CH_N;
				11: body_char = CH_F; 12: body_char = CH_I; 13: body_char = CH_R;
				14: body_char = CH_M;
			endcase
			LN_CATCH: case (idx)         // "CATCH EMBERS FOR HEAT"
				0: body_char = CH_C;  1: body_char = CH_A;  2: body_char = CH_T;
				3: body_char = CH_C;  4: body_char = CH_H;  6: body_char = CH_E;
				7: body_char = CH_M;  8: body_char = CH_B;  9: body_char = CH_E;
				10: body_char = CH_R; 11: body_char = CH_S; 13: body_char = CH_F;
				14: body_char = CH_O; 15: body_char = CH_R; 17: body_char = CH_H;
				18: body_char = CH_E; 19: body_char = CH_A; 20: body_char = CH_T;
			endcase
			LN_RIDGES: case (idx)        // "JUMP OR RIDGES HURT"
				0: body_char = CH_J;  1: body_char = CH_U;  2: body_char = CH_M;
				3: body_char = CH_P;  5: body_char = CH_O;  6: body_char = CH_R;
				8: body_char = CH_R;  9: body_char = CH_I;  10: body_char = CH_D;
				11: body_char = CH_G; 12: body_char = CH_E; 13: body_char = CH_S;
				15: body_char = CH_H; 16: body_char = CH_U; 17: body_char = CH_R;
				18: body_char = CH_T;
			endcase
			LN_SKILL: case (idx)         // "LEFT AND RIGHT SKILL"
				0: body_char = CH_L;  1: body_char = CH_E;  2: body_char = CH_F;
				3: body_char = CH_T;  5: body_char = CH_A;  6: body_char = CH_N;
				7: body_char = CH_D;  9: body_char = CH_R;  10: body_char = CH_I;
				11: body_char = CH_G; 12: body_char = CH_H; 13: body_char = CH_T;
				15: body_char = CH_S; 16: body_char = CH_K; 17: body_char = CH_I;
				18: body_char = CH_L; 19: body_char = CH_L;
			endcase
			LN_START: case (idx)         // "PRESS JUMP TO START"
				0: body_char = CH_P;  1: body_char = CH_R;  2: body_char = CH_E;
				3: body_char = CH_S;  4: body_char = CH_S;  6: body_char = CH_J;
				7: body_char = CH_U;  8: body_char = CH_M;  9: body_char = CH_P;
				11: body_char = CH_T; 12: body_char = CH_O; 14: body_char = CH_S;
				15: body_char = CH_T; 16: body_char = CH_A; 17: body_char = CH_R;
				18: body_char = CH_T;
			endcase
			LN_CHOICE: case (idx)        // "PLAY AGAIN  LEAVE"
				0: body_char = CH_P;  1: body_char = CH_L;  2: body_char = CH_A;
				3: body_char = CH_Y;  5: body_char = CH_A;  6: body_char = CH_G;
				7: body_char = CH_A;  8: body_char = CH_I;  9: body_char = CH_N;
				12: body_char = CH_L; 13: body_char = CH_E; 14: body_char = CH_A;
				15: body_char = CH_V; 16: body_char = CH_E;
			endcase
			default: body_char = CH_SP;
		endcase
	end
endfunction

// "HEAT" / "BEST", the only two fixed labels.
function [5:0] label_char;
	input is_best;
	input [5:0] idx;
	begin
		label_char = CH_SP;
		if (is_best) begin
			case (idx)                   // "BEST"
				0: label_char = CH_B;  1: label_char = CH_E;
				2: label_char = CH_S;  3: label_char = CH_T;
			endcase
		end else begin
			case (idx)                   // "HEAT"
				0: label_char = CH_H;  1: label_char = CH_E;
				2: label_char = CH_A;  3: label_char = CH_T;
			endcase
		end
	end
endfunction

// For a text field at base X with a given char stride & scaled glyph width,
// report which char the pixel hits: {hit(1), idx(5), local_x(7)}. `nchars` is
// always a literal at the call site so the loop folds to that many compares.
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
		for (i = 0; i < 24; i = i + 1) begin
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

// ---------------------------------------------------------------------------
// Which title, and where
// ---------------------------------------------------------------------------
reg [9:0] title_base;
reg [9:0] title_y;

always @(*) begin
	title_y = TITLE_Y;
	case (mode)
		3'd1:    title_base = TITLE_X_TIMEUP;
		3'd4: begin title_base = TITLE_X_HOWTO; title_y = HOWTO_TITLE_Y; end
		3'd5:    title_base = TITLE_X_READY;
		default: case (title_id)
			TITLE_NORMAL: title_base = TITLE_X_NORMAL;
			TITLE_EMBER:  title_base = TITLE_X_EMBER;
			default:      title_base = TITLE_X_EASY;   // every 4-letter word
		endcase
	endcase
end

// ---------------------------------------------------------------------------
// Which body line, and where
// ---------------------------------------------------------------------------
reg [2:0] body_line;
reg [9:0] body_y0;
reg [9:0] body_x;

always @(*) begin
	body_line = LN_NONE;
	body_y0   = 10'd0;

	if (show_howto) begin
		if      (pixel_y >= HOWTO_BODY_Y0     && pixel_y < HOWTO_BODY_Y0 + 24)
			begin body_line = LN_CATCH;  body_y0 = HOWTO_BODY_Y0; end
		else if (pixel_y >= HOWTO_BODY_Y0 +   HOWTO_BODY_STRIDE && pixel_y < HOWTO_BODY_Y0 +   HOWTO_BODY_STRIDE + 24)
			begin body_line = LN_RIDGES; body_y0 = HOWTO_BODY_Y0 +   HOWTO_BODY_STRIDE; end
		else if (pixel_y >= HOWTO_BODY_Y0 + 2*HOWTO_BODY_STRIDE && pixel_y < HOWTO_BODY_Y0 + 2*HOWTO_BODY_STRIDE + 24)
			begin body_line = LN_SKILL;  body_y0 = HOWTO_BODY_Y0 + 2*HOWTO_BODY_STRIDE; end
		else if (pixel_y >= HOWTO_BODY_Y0 + 3*HOWTO_BODY_STRIDE && pixel_y < HOWTO_BODY_Y0 + 3*HOWTO_BODY_STRIDE + 24)
			begin body_line = LN_START;  body_y0 = HOWTO_BODY_Y0 + 3*HOWTO_BODY_STRIDE; end
	end else if (show_menu) begin
		if      (pixel_y >= MENU_BODY_Y0 && pixel_y < MENU_BODY_Y0 + 24)
			begin body_line = LN_MOVE;    body_y0 = MENU_BODY_Y0; end
		else if (pixel_y >= MENU_BODY_Y1 && pixel_y < MENU_BODY_Y1 + 24)
			begin body_line = LN_CONFIRM; body_y0 = MENU_BODY_Y1; end
	end else if (show_choice &&
		pixel_y >= CHOICE_Y && pixel_y < CHOICE_Y + 24) begin
		body_line = LN_CHOICE;
		body_y0   = CHOICE_Y;
	end

	case (body_line)
		LN_MOVE:    body_x = X_MOVE;
		LN_CONFIRM: body_x = X_CONFIRM;
		LN_CATCH:   body_x = X_CATCH;
		LN_RIDGES:  body_x = X_RIDGES;
		LN_SKILL:   body_x = X_SKILL;
		LN_START:   body_x = X_START;
		default:    body_x = X_CHOICE;
	endcase
end

// ---------------------------------------------------------------------------
// Pick the one field this pixel lands in. Rows are disjoint, so a !glyph_hit
// guarded if-chain is exact.
// ---------------------------------------------------------------------------
reg        glyph_hit;
reg        is_title;
reg [5:0]  glyph;
reg [2:0]  font_x;
reg [3:0]  font_y;

reg [12:0] gc_title, gc_body, gc_label, gc_value;
reg [4:0]  ci;
reg        best_row;

always @(*) begin
	glyph_hit = 1'b0;
	is_title  = 1'b0;
	glyph     = 6'd0;
	font_x    = 3'd0;
	font_y    = 4'd0;
	ci        = 5'd0;

	gc_title = glyph_col(pixel_x, title_base, TITLE_STRIDE, TITLE_GW, TITLE_NCHARS);
	gc_body  = glyph_col(pixel_x, body_x,     BODY_STRIDE,  BODY_GW,  BODY_NCHARS);
	gc_label = glyph_col(pixel_x, LABEL_X,    LABEL_STRIDE, LABEL_GW, 6'd4);
	gc_value = glyph_col(pixel_x, VALUE_X,    VAL_STRIDE,   VAL_GW,   6'd3);

	// The BEST row and the HEAT row share both call sites, so one flag picks
	// the word and the number for whichever row the pixel is in.
	best_row = pixel_y >= BEST_LABEL_Y;

	// --- title, scale 4 ---
	if (pixel_y >= title_y && pixel_y < title_y + 48 && gc_title[12]) begin
		ci    = gc_title[11:7];
		glyph = glyph_of(title_char(mode, title_id, {1'b0, ci}));
		if (glyph != GLYPH_SPACE) begin
			glyph_hit = 1'b1;
			is_title  = 1'b1;
			font_x    = gc_title[6:0] >> 2;
			font_y    = (pixel_y - title_y) >> 2;
		end
	end

	// --- body, scale 2 ---
	if (!glyph_hit && body_line != LN_NONE && gc_body[12]) begin
		ci    = gc_body[11:7];
		glyph = glyph_of(body_char(body_line, {1'b0, ci}));
		if (glyph != GLYPH_SPACE) begin
			glyph_hit = 1'b1;
			is_title  = (body_line == LN_CHOICE);   // highlight the choice row
			font_x    = gc_body[6:0] >> 1;
			font_y    = (pixel_y - body_y0) >> 1;
		end
	end

	// --- countdown digit, scale 8 ---
	if (!glyph_hit && show_count &&
		pixel_y >= COUNT_Y && pixel_y < COUNT_Y + 96 &&
		pixel_x >= COUNT_X && pixel_x < COUNT_X + COUNT_GW) begin
		glyph     = {3'b000, count_val};
		glyph_hit = 1'b1;
		font_x    = (pixel_x - COUNT_X) >> 3;
		font_y    = (pixel_y - COUNT_Y) >> 3;
	end

	// --- HEAT / BEST label, scale 2 (results only) ---
	if (!glyph_hit && show_result && gc_label[12] &&
		((pixel_y >= SCORE_LABEL_Y && pixel_y < SCORE_LABEL_Y + 24) ||
		 (show_best && pixel_y >= BEST_LABEL_Y && pixel_y < BEST_LABEL_Y + 24))) begin
		ci    = gc_label[11:7];
		glyph = glyph_of(label_char(best_row, {1'b0, ci}));
		if (glyph != GLYPH_SPACE) begin
			glyph_hit = 1'b1;
			font_x    = gc_label[6:0] >> 1;
			font_y    = (pixel_y - (best_row ? BEST_LABEL_Y : SCORE_LABEL_Y)) >> 1;
		end
	end

	// --- HEAT / BEST value, 3 BCD digits, scale 4 (results only) ---
	if (!glyph_hit && show_result && gc_value[12] &&
		((pixel_y >= SCORE_VAL_Y && pixel_y < SCORE_VAL_Y + 48) ||
		 (show_best && pixel_y >= BEST_VAL_Y && pixel_y < BEST_VAL_Y + 48))) begin
		ci = gc_value[11:7];
		if (best_row) begin
			case (ci)
				5'd0:    glyph = {2'b00, high_score_bcd[11:8]};
				5'd1:    glyph = {2'b00, high_score_bcd[7:4]};
				default: glyph = {2'b00, high_score_bcd[3:0]};
			endcase
		end else begin
			case (ci)
				5'd0:    glyph = {2'b00, score_bcd[11:8]};
				5'd1:    glyph = {2'b00, score_bcd[7:4]};
				default: glyph = {2'b00, score_bcd[3:0]};
			endcase
		end
		glyph_hit = 1'b1;
		font_x    = gc_value[6:0] >> 2;
		font_y    = (pixel_y - (best_row ? BEST_VAL_Y : SCORE_VAL_Y)) >> 2;
	end
end

wire [9:0] font_addr = {glyph, font_y};
wire [5:0] font_row_bits;

(* ramstyle = "distributed" *) rom #(
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
	(show_d && glyph_on)                  ? (is_title_d ? COLOR_TITLE : COLOR_TEXT) :
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
