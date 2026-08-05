`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"
`include "game/game_defs.vh"

// ---------------------------------------------------------------------------
// EMBERFOX - sprite layer
//
// Draw order:  background -> ground obstacles -> falling objects -> fox
//
// There is no frame buffer. For every single pixel the video output asks for,
// this block works out "is anything drawn here?" using rectangle tests, reads
// one byte of sprite art, and either shows it or lets the background through.
//
// Sprite ROM reads take one clock, so every decision made about a pixel is
// held in a register for one cycle to line up with the art arriving.
// ---------------------------------------------------------------------------

module obj_layer #(
	`SVO_DEFAULT_PARAMS,
	parameter MAX_OBJ       = 6,
	parameter LANE_BITS     = 4,
	parameter XOFF_BITS     = 4,
	parameter OBJ_TYPE_BITS = 3,
	parameter OBJ_Y_BITS    = 10,
	parameter MAX_OBS       = 3,
	parameter OBS_X_BITS    = 11
) (
	input clk,
	input resetn,

	// game state
	input [9:0] player_x,
	input [9:0] player_y,
	input       player_dir,
	input [1:0] player_frame,
	input       skill_on,

	input [MAX_OBJ              -1:0] obj_valid_bus,
	input [MAX_OBJ*LANE_BITS    -1:0] obj_lane_bus,
	input [MAX_OBJ*XOFF_BITS    -1:0] obj_xoff_bus,
	input [MAX_OBJ*OBJ_Y_BITS   -1:0] obj_ypos_bus,
	input [MAX_OBJ*OBJ_TYPE_BITS-1:0] obj_type_bus,

input [MAX_OBS            -1:0] obs_valid_bus,
input [MAX_OBS            -1:0] obs_tall_bus,
input [MAX_OBS*3          -1:0] obs_btn_bus,
input [MAX_OBS*OBS_X_BITS -1:0] obs_xpos_bus,

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

// 2-frame walk sheet: {frame(1), src_y(5), src_x(5)}.
// The air poses (player_frame 2/3) share frame bit 0, so jumping keeps
// showing the walk frames instead of reading past the end of the ROM.
localparam PLAYER_SRC_BITS   = 5;
localparam PLAYER_ADDR_WIDTH = 11;
localparam PLAYER_DEPTH      = 2048;
// 2-frame fire sheet: {frame(1), src_y(5), src_x(5)}
localparam SKILL_ADDR_WIDTH  = 11;
localparam SKILL_DEPTH       = 2048;

localparam OBJ_ATLAS_ADDR_WIDTH = 12;      // {type(4), src_y(4), src_x(4)}
localparam OBJ_ATLAS_DEPTH = 4096;         // 16 type slots x 256
localparam [7:0] TRANSPARENT_VAL = 8'h00;

reg [`SVO_XYBITS-1:0] hcursor;
reg [`SVO_XYBITS-1:0] vcursor;

reg atlas_hit_d;
reg hit_player_d;
reg skill_on_d;
reg [SVO_BITS_PER_PIXEL-1:0] bg_rgb_d;
reg [0:0] tuser_d;
reg tvalid_d;

wire fire = in_axis_tvalid && in_axis_tready;
wire [`SVO_XYBITS-1:0] pixel_x = in_axis_tuser[0] ? 0 : hcursor;
wire [`SVO_XYBITS-1:0] pixel_y = in_axis_tuser[0] ? 0 : vcursor;


function [9:0] obj_x;
	input [LANE_BITS-1:0] lane;
	input [XOFF_BITS-1:0] xoff;
	begin obj_x = `GAME_X0 + ({6'd0, lane} << 5) + {6'd0, xoff}; end
endfunction

// ---------------------------------------------------------------------------
// Ground obstacles
//
// They only ever move sideways, so the vertical test is one comparison for the
// whole screen instead of one per obstacle. Obstacles are stored biased (see
// game_defs.vh), so we bias the pixel once rather than un-biasing each one.
// ---------------------------------------------------------------------------
// Both heights end on the floor line, so the two vertical bands are shared by
// every obstacle - only the pick between them is per-obstacle.
wire in_obs_band_short = pixel_y >= `OBS_Y      && pixel_y < `UI_TOP;
wire in_obs_band_tall  = pixel_y >= `OBS_TALL_Y && pixel_y < `UI_TOP;
wire [OBS_X_BITS-1:0] pixel_x_biased = pixel_x[9:0] + `OBS_X_BIAS;

// The tall obstacle is the SAME 16x16 sprite stretched 4x vertically instead
// of 2x, so a second obstacle shape costs no extra ROM at all.
wire [5:0] obs_local_y_short = pixel_y[9:0] - `OBS_Y;
wire [5:0] obs_local_y_tall  = pixel_y[9:0] - `OBS_TALL_Y;

integer obs_i;
reg obs_hit;
reg obs_hit_tall;
reg [2:0] obs_btn_d;
reg [4:0] obs_local_x;
reg [OBS_X_BITS-1:0] scan_obs_x;
reg [10:0] scan_obs_lx;

always @(*) begin
	obs_hit = 0;
	obs_hit_tall = 0;
	obs_btn_d = 0;
	obs_local_x = 0;
	scan_obs_x = 0;
	scan_obs_lx = 0;

	for (obs_i = 0; obs_i < MAX_OBS; obs_i = obs_i + 1) begin
		scan_obs_x = obs_xpos_bus[obs_i*OBS_X_BITS +: OBS_X_BITS];

		if (!obs_hit && obs_valid_bus[obs_i] &&
			(obs_tall_bus[obs_i] ? in_obs_band_tall : in_obs_band_short) &&
			pixel_x_biased >= scan_obs_x &&
			pixel_x_biased <  scan_obs_x + `OBS_W) begin
			scan_obs_lx = pixel_x_biased - scan_obs_x;
			obs_hit = 1;
			obs_hit_tall = obs_tall_bus[obs_i];
			obs_btn_d = obs_btn_bus[obs_i*3 +: 3];
			obs_local_x = scan_obs_lx[4:0];
		end
	end
end

// 64 px tall -> 16 source rows means >>2; 32 px tall means >>1.
wire [3:0] obs_src_y = obs_hit_tall ? obs_local_y_tall[5:2] : obs_local_y_short[4:1];

// ---------------------------------------------------------------------------
// Falling objects
//
// This loop is unrolled by the synthesiser into MAX_OBJ parallel rectangle
// tests. It is the most expensive thing in the design, which is why MAX_OBJ
// is kept small.
// ---------------------------------------------------------------------------
integer obj_i;
reg obj_hit;
reg [OBJ_TYPE_BITS-1:0] obj_type_now;
reg [4:0] obj_local_x;
reg [4:0] obj_local_y;
reg [9:0] scan_obj_x;
reg [9:0] scan_obj_ypos;
reg [9:0] scan_local_x;
reg [9:0] scan_local_y;

always @(*) begin
	obj_hit = 0;
	obj_type_now = 0;
	obj_local_x = 0;
	obj_local_y = 0;
	scan_obj_x = 0;
	scan_obj_ypos = 0;
	scan_local_x = 0;
	scan_local_y = 0;

	for (obj_i = 0; obj_i < MAX_OBJ; obj_i = obj_i + 1) begin
		scan_obj_x = obj_x(
			obj_lane_bus[obj_i*LANE_BITS +: LANE_BITS],
			obj_xoff_bus[obj_i*XOFF_BITS +: XOFF_BITS]
		);
		scan_obj_ypos = obj_ypos_bus[obj_i*OBJ_Y_BITS +: OBJ_Y_BITS];

		// AABB hit test
if (!obj_hit && obj_valid_bus[obj_i] &&
			pixel_x >= scan_obj_x && pixel_x < scan_obj_x + `OBJ_W &&
			pixel_y >= scan_obj_ypos && pixel_y < scan_obj_ypos + `OBJ_H) begin
		scan_local_x = pixel_x - scan_obj_x;
			scan_local_y = pixel_y - scan_obj_ypos;
			obj_hit = 1;
			obj_type_now = obj_type_bus[obj_i*OBJ_TYPE_BITS +: OBJ_TYPE_BITS];
			obj_local_x = scan_local_x[4:0];
			obj_local_y = scan_local_y[4:0];
		end
	end
end

// ---------------------------------------------------------------------------
// One atlas ROM serves both. Falling objects use slots 0-6; ground obstacles
// use the button sprites in slots 7-11, chosen per-obstacle by obs_btn (0-4).
// A falling object wins if both land on the same pixel (it is in front).
// 16x16 art shown at 32x32: dropping the bottom bit repeats every pixel twice.
// ---------------------------------------------------------------------------
wire atlas_hit = obj_hit || obs_hit;
wire [3:0] atlas_type = obj_hit ? {1'b0, obj_type_now}
								: (4'd7 + {1'b0, obs_btn_d});
wire [4:0] atlas_local_x = obj_hit ? obj_local_x : obs_local_x;

wire [3:0] atlas_src_x = atlas_local_x[4:1];
wire [3:0] atlas_src_y = obj_hit ? obj_local_y[4:1] : obs_src_y;
wire [OBJ_ATLAS_ADDR_WIDTH-1:0] obj_atlas_addr = {atlas_type, atlas_src_y, atlas_src_x};
wire [7:0] obj_rgb;

// ---------------------------------------------------------------------------
// The fox
// ---------------------------------------------------------------------------
wire hit_player = pixel_x >= player_x && pixel_x < player_x + `PLAYER_W &&
				  pixel_y >= player_y && pixel_y < player_y + `PLAYER_H;

// 32x32 art shown at 64x64
wire [9:0] player_rel_x = pixel_x[9:0] - player_x;
wire [9:0] player_rel_y = pixel_y[9:0] - player_y;
wire [PLAYER_SRC_BITS-1:0] player_src_x = player_rel_x[5:1];
wire [PLAYER_SRC_BITS-1:0] player_src_y = player_rel_y[5:1];
// The art faces right; facing left just reads the row backwards.
wire [PLAYER_SRC_BITS-1:0] player_addr_x = player_dir ? player_src_x
													  : (5'd31 - player_src_x);

// Walk sheet holds the 2 walk poses; the air frames (2/3) reuse frame bit 0.
wire [PLAYER_ADDR_WIDTH-1:0] player_addr = {player_frame[0], player_src_y, player_addr_x};
// Fire sheet holds only the 2 walk poses too, so it uses the same frame bit.
wire [SKILL_ADDR_WIDTH-1:0] skill_addr = {player_frame[0], player_src_y, player_addr_x};

wire [7:0] player_normal_rgb;
wire [7:0] player_skill_rgb;
wire [7:0] player_rgb = skill_on_d ? player_skill_rgb : player_normal_rgb;

function [23:0] rgb323_to_bgr888;
	input [7:0] c;                 // [7:5]=R3 [4:3]=G2 [2:0]=B3
	reg [7:0] r;
	reg [7:0] g;
	reg [7:0] b;
	begin
		r = {c[7:5], c[7:5], c[7:6]};
		g = {c[4:3], c[4:3], c[4:3], c[4:3]};
		b = {c[2:0], c[2:0], c[2:1]};
		rgb323_to_bgr888 = {b, g, r};
	end
endfunction

// If an obstacle or object covers this pixel show it, else the background
wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_obj =
	atlas_hit_d && obj_rgb != TRANSPARENT_VAL ?
	rgb323_to_bgr888(obj_rgb) : bg_rgb_d;

// The fox is drawn last, so it is always in front
wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_player =
	hit_player_d && player_rgb != TRANSPARENT_VAL ?
	rgb323_to_bgr888(player_rgb) : pxl_after_obj;

assign in_axis_tready  = out_axis_tready;
assign out_axis_tvalid = tvalid_d;
assign out_axis_tdata  = pxl_after_player;
assign out_axis_tuser  = tuser_d;

always @(posedge clk) begin
	if (!resetn) begin
		atlas_hit_d <= 0;
		hit_player_d <= 0;
		skill_on_d <= 0;
		bg_rgb_d <= 0;
		tuser_d <= 0;
		tvalid_d <= 0;
	end else if (out_axis_tready) begin
		tvalid_d <= in_axis_tvalid;
		if (fire) begin
			atlas_hit_d <= atlas_hit;
			hit_player_d <= hit_player;
			skill_on_d <= skill_on;
			bg_rgb_d <= in_axis_tdata;
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

// Single atlas ROM (RGB323): 16 slots x 256 entries, addressed by
// {type, src_y, src_x}. Slots 0-6 are the falling objects, 7-11 the buttons
// that slide along the ground.
rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(OBJ_ATLAS_ADDR_WIDTH),
	.DEPTH(OBJ_ATLAS_DEPTH),
	.INIT_FILE("src/assets/obj_atlas.mem")
) u_obj_atlas_rom (
	.clk(clk),
	.addr(obj_atlas_addr),
	.data(obj_rgb)
);

rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(PLAYER_ADDR_WIDTH),
	.DEPTH(PLAYER_DEPTH),
	.INIT_FILE("src/assets/player_right_32.mem")
) u_player_walk_rom (
	.clk(clk),
	.addr(player_addr),
	.data(player_normal_rgb)
);

rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(SKILL_ADDR_WIDTH),
	.DEPTH(SKILL_DEPTH),
	.INIT_FILE("src/assets/player_skill_32.mem")
) u_player_skill_rom (
	.clk(clk),
	.addr(skill_addr),
	.data(player_skill_rgb)
);

endmodule
