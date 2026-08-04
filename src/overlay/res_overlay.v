`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

module res_overlay #(
	`SVO_DEFAULT_PARAMS
) (
	input clk,
	input resetn,

	// 0 = hidden (playing), 1 = run over, 2 = difficulty menu, 3 = skill menu
	input [1:0] mode,
	input [2:0] title_id,
	input [1:0] menu_sel,
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
// scaled by power-of-2 replication (title/value x4 -> 24x48, labels x2 -> 12x24).
localparam [9:0] TITLE_X       = 10'd222;
localparam [9:0] TITLE_Y       = 10'd140;
localparam [9:0] TITLE_STRIDE  = 10'd28;   // (6+1) * 4
localparam [9:0] TITLE_GW      = 10'd24;   // 6 * 4

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

// combined-font glyph indices (see .vscode/bitmap2mem.ps1)
localparam GLYPH_SPACE = 5'd10;
// 11..21 = B C E I M O P R S T U      22..27 = A D H L N Y
localparam G_B = 5'd11, G_C = 5'd12, G_E = 5'd13, G_I = 5'd14, G_M = 5'd15;
localparam G_O = 5'd16, G_P = 5'd17, G_R = 5'd18, G_S = 5'd19, G_T = 5'd20;
localparam G_U = 5'd21, G_A = 5'd22, G_D = 5'd23, G_H = 5'd24, G_L = 5'd25;
localparam G_N = 5'd26, G_Y = 5'd27;

localparam [1:0] TXT_TITLE = 2'd0;
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

wire show        = mode != 2'd0;
wire show_result = mode == 2'd1;
wire show_menu   = mode[1];            // 2 or 3

wire in_panel =
	pixel_x >= PANEL_X0 && pixel_x < PANEL_X1 &&
	pixel_y >= PANEL_Y0 && pixel_y < PANEL_Y1;

// Three little boxes under the title; the chosen one is filled bright.
// Cheap: three fixed rectangles and a compare against menu_sel.
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

// Map a text string + char position to a combined-font glyph index.
//
// The title line is shared by every screen: it shows TIME UP when a run ends,
// and the name of the highlighted option while in the menu. Reusing the same
// 7-character field for all of them means the menu costs almost no extra
// hardware - only this case statement grows.
function [4:0] text_glyph;
	input [1:0] tid;
	input [2:0] tsel;              // which title, when tid == TXT_TITLE
	input [2:0] idx;
	begin
		text_glyph = GLYPH_SPACE;
		case (tid)
			TXT_TITLE: case (tsel)
				TITLE_TIMEUP: case (idx)       // "TIME UP"
					0: text_glyph = G_T;  1: text_glyph = G_I;
					2: text_glyph = G_M;  3: text_glyph = G_E;
					5: text_glyph = G_U;  6: text_glyph = G_P;
					default: text_glyph = GLYPH_SPACE;
				endcase
				TITLE_EASY: case (idx)         // "EASY"
					0: text_glyph = G_E;  1: text_glyph = G_A;
					2: text_glyph = G_S;  3: text_glyph = G_Y;
					default: text_glyph = GLYPH_SPACE;
				endcase
				TITLE_NORMAL: case (idx)       // "NORMAL"
					0: text_glyph = G_N;  1: text_glyph = G_O;
					2: text_glyph = G_R;  3: text_glyph = G_M;
					4: text_glyph = G_A;  5: text_glyph = G_L;
					default: text_glyph = GLYPH_SPACE;
				endcase
				TITLE_HARD: case (idx)         // "HARD"
					0: text_glyph = G_H;  1: text_glyph = G_A;
					2: text_glyph = G_R;  3: text_glyph = G_D;
					default: text_glyph = GLYPH_SPACE;
				endcase
				TITLE_EMBER: case (idx)        // "EMBER"
					0: text_glyph = G_E;  1: text_glyph = G_M;
					2: text_glyph = G_B;  3: text_glyph = G_E;
					4: text_glyph = G_R;
					default: text_glyph = GLYPH_SPACE;
				endcase
				TITLE_TIME: case (idx)         // "TIME"
					0: text_glyph = G_T;  1: text_glyph = G_I;
					2: text_glyph = G_M;  3: text_glyph = G_E;
					default: text_glyph = GLYPH_SPACE;
				endcase
				default: case (idx)            // "LURE"
					0: text_glyph = G_L;  1: text_glyph = G_U;
					2: text_glyph = G_R;  3: text_glyph = G_E;
					default: text_glyph = GLYPH_SPACE;
				endcase
			endcase
			TXT_HEAT: case (idx)           // "HEAT"
				0: text_glyph = G_H;
				1: text_glyph = G_E;
				2: text_glyph = G_A;
				3: text_glyph = G_T;
				default: text_glyph = GLYPH_SPACE;
			endcase
			TXT_BEST: case (idx)           // "BEST"
				0: text_glyph = G_B;
				1: text_glyph = G_E;
				2: text_glyph = G_S;
				3: text_glyph = G_T;
				default: text_glyph = GLYPH_SPACE;
			endcase
			default: text_glyph = GLYPH_SPACE;
		endcase
	end
endfunction

// For a text field at base X with a given char stride & scaled glyph width,
// report which char the pixel hits: {hit(1), idx(3), local_x(5)}.
function [8:0] glyph_col;
	input [`SVO_XYBITS-1:0] px;
	input [9:0] base;
	input [9:0] stride;
	input [9:0] gw;
	input [3:0] nchars;
	integer i;
	reg [9:0] cleft;
	reg [4:0] lx;
	begin
		glyph_col = 9'd0;
		for (i = 0; i < 7; i = i + 1) begin
			if (i < nchars) begin
				cleft = base + i * stride;
				if (px >= cleft && px < cleft + gw) begin
					lx = px - cleft;
					glyph_col = {1'b1, i[2:0], lx};
				end
			end
		end
	end
endfunction

// Combinational: pick the single text field this pixel lands in and compute
// the glyph index, source column (font_x) and row (font_y). Fields occupy
// disjoint screen regions, so an if-chain (guarded by !glyph_hit) is exact.
reg        glyph_hit;
reg        is_title;
reg [4:0]  glyph;
reg [2:0]  font_x;
reg [3:0]  font_y;

reg [8:0]  gc;
reg [2:0]  ci;

always @(*) begin
	glyph_hit = 1'b0;
	is_title  = 1'b0;
	glyph     = 5'd0;
	font_x    = 3'd0;
	font_y    = 4'd0;
	gc        = 9'd0;
	ci        = 3'd0;

	// Title line, scale 4. Shows TIME UP after a run, or the highlighted
	// option's name while in the menu.
	if (pixel_y >= TITLE_Y && pixel_y < TITLE_Y + 48) begin
		gc = glyph_col(pixel_x, TITLE_X, TITLE_STRIDE, TITLE_GW, 4'd7);
		if (gc[8]) begin
			ci = gc[7:5];
			glyph = text_glyph(TXT_TITLE, title_id, ci);
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				is_title  = 1'b1;
				font_x    = gc[4:0] >> 2;
				font_y    = (pixel_y - TITLE_Y) >> 2;
			end
		end
	end

	// Heat label "HEAT", scale 2. Only on the results screen - in the menu
	// this row is where the option dots go instead.
	if (!glyph_hit && show_result &&
		pixel_y >= SCORE_LABEL_Y && pixel_y < SCORE_LABEL_Y + 24) begin
		gc = glyph_col(pixel_x, SCORE_LABEL_X, LABEL_STRIDE, LABEL_GW, 4'd4);
		if (gc[8]) begin
			ci = gc[7:5];
			glyph = text_glyph(TXT_HEAT, 3'd0, ci);
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				font_x    = gc[4:0] >> 1;
				font_y    = (pixel_y - SCORE_LABEL_Y) >> 1;
			end
		end
	end

	// Best label "BEST", scale 2
	if (!glyph_hit && pixel_y >= BEST_LABEL_Y && pixel_y < BEST_LABEL_Y + 24) begin
		gc = glyph_col(pixel_x, BEST_LABEL_X, LABEL_STRIDE, LABEL_GW, 4'd4);
		if (gc[8]) begin
			ci = gc[7:5];
			glyph = text_glyph(TXT_BEST, 3'd0, ci);
			if (glyph != GLYPH_SPACE) begin
				glyph_hit = 1'b1;
				font_x    = gc[4:0] >> 1;
				font_y    = (pixel_y - BEST_LABEL_Y) >> 1;
			end
		end
	end

	// Heat value (3 BCD digits), scale 4. Results screen only.
	if (!glyph_hit && show_result &&
		pixel_y >= SCORE_VAL_Y && pixel_y < SCORE_VAL_Y + 48) begin
		gc = glyph_col(pixel_x, VALUE_X, VAL_STRIDE, VAL_GW, 4'd3);
		if (gc[8]) begin
			ci = gc[7:5];
			case (ci)
				3'd0: glyph = {1'b0, score_bcd[11:8]};
				3'd1: glyph = {1'b0, score_bcd[7:4]};
				default: glyph = {1'b0, score_bcd[3:0]};
			endcase
			glyph_hit = 1'b1;
			font_x    = gc[4:0] >> 2;
			font_y    = (pixel_y - SCORE_VAL_Y) >> 2;
		end
	end

	// Best value (3 BCD digits), scale 4
	if (!glyph_hit && pixel_y >= BEST_VAL_Y && pixel_y < BEST_VAL_Y + 48) begin
		gc = glyph_col(pixel_x, VALUE_X, VAL_STRIDE, VAL_GW, 4'd3);
		if (gc[8]) begin
			ci = gc[7:5];
			case (ci)
				3'd0: glyph = {1'b0, high_score_bcd[11:8]};
				3'd1: glyph = {1'b0, high_score_bcd[7:4]};
				default: glyph = {1'b0, high_score_bcd[3:0]};
			endcase
			glyph_hit = 1'b1;
			font_x    = gc[4:0] >> 2;
			font_y    = (pixel_y - BEST_VAL_Y) >> 2;
		end
	end
end

wire [8:0] font_addr = {glyph, font_y};
wire [5:0] font_row_bits;

rom #(
	.DATA_WIDTH(6),
	.ADDR_WIDTH(9),
	.DEPTH(512),
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

assign out_axis_tdata =
	(show_d && glyph_on)     ? (is_title_d ? COLOR_TITLE : COLOR_TEXT) :
	(show_d && dot_on_d)     ? (dot_sel_d ? COLOR_DOT_ON : COLOR_DOT_OFF) :
	(show_d && in_border_d)  ? COLOR_BORDER :
	(show_d && in_panel_d)   ? COLOR_PANEL :
							   bg_sel;

always @(posedge clk) begin
	if (!resetn) begin
		glyph_hit_d <= 0;
		is_title_d <= 0;
		font_x_d <= 0;
		show_d <= 0;
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
