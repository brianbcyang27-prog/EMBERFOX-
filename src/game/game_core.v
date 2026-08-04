`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

// ---------------------------------------------------------------------------
// EMBERFOX - top of the game
//
// Wires the game logic to the four render layers and hands one finished pixel
// stream to the HDMI encoder. The layers form a chain: each takes the picture
// so far and paints its own stuff on top.
//
//     bg_layer      static landscape
//       -> obj_layer    obstacles, falling embers, the fox
//         -> ui_layer     timer / score / best / charge bar
//           -> res_overlay  the end-of-run panel
// ---------------------------------------------------------------------------

module game_core #(
	parameter SVO_MODE             =   "640x480V",
	parameter SVO_FRAMERATE        =   60,
	parameter SVO_BITS_PER_PIXEL   =   24,
	parameter SVO_BITS_PER_RED     =    8,
	parameter SVO_BITS_PER_GREEN   =    8,
	parameter SVO_BITS_PER_BLUE    =    8,
	parameter SVO_BITS_PER_ALPHA   =    0,
	parameter SKILL_ENABLE         =    1,
	parameter SKILL_DURATION       =    8
) (
	input clk,
	input resetn,

	// The board has three buttons. Signal names are kept so hdmi_coin.cst does
	// not have to change:
	//
	//   btn_left   pin 13   move left
	//   btn_right  pin 17   move right
	//   btn_start  pin 15 ) whichever of these two the third button is wired
	//   btn_skill  pin 18 ) to, it acts as JUMP
	//
	//   Ember Dash = LEFT + RIGHT together (see game_ctrl)
	//   play again = JUMP on the results screen
	//
	// An unused pin has PULL_MODE=UP and debounce treats it as active-low, so
	// it reads as "not pressed" forever. ORing the two spare pins together
	// means the third button works on either one.
	input btn_left,
	input btn_right,
	input btn_start,
	input btn_skill,

	output out_axis_tvalid,
	input out_axis_tready,
	output [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output [0:0] out_axis_tuser
);
// How many things can be on screen at once. Every extra one costs a full set
// of rectangle comparators in BOTH game_ctrl and obj_layer, so these are the
// main dials for logic usage on the FPGA.
localparam MAX_OBJ = 6;      // falling embers / shards
localparam MAX_OBS = 3;      // ground obstacles
localparam LANE_BITS = 4;
localparam XOFF_BITS = 4;
localparam OBJ_TYPE_BITS = 3;
localparam OBJ_Y_BITS = 10;
localparam OBS_X_BITS = 11;

wire btn_jump = btn_start || btn_skill;

wire bg_tvalid;
wire bg_tready;
wire [SVO_BITS_PER_PIXEL-1:0] bg_tdata;
wire [0:0] bg_tuser;

wire obj_tvalid;
wire obj_tready;
wire [SVO_BITS_PER_PIXEL-1:0] obj_tdata;
wire [0:0] obj_tuser;

wire ui_tvalid;
wire ui_tready;
wire [SVO_BITS_PER_PIXEL-1:0] ui_tdata;
wire [0:0] ui_tuser;

wire frame_tick;
wire [9:0] player_x;
wire [9:0] player_y;
wire player_dir;
wire [1:0] player_frame;
wire [MAX_OBJ              -1:0] obj_valid_bus;
wire [MAX_OBJ*LANE_BITS    -1:0] obj_lane_bus;
wire [MAX_OBJ*XOFF_BITS    -1:0] obj_xoff_bus;
wire [MAX_OBJ*OBJ_Y_BITS   -1:0] obj_ypos_bus;
wire [MAX_OBJ*OBJ_TYPE_BITS-1:0] obj_type_bus;
wire [MAX_OBS             -1:0] obs_valid_bus;
wire [MAX_OBS             -1:0] obs_tall_bus;
wire [MAX_OBS*OBS_X_BITS  -1:0] obs_xpos_bus;
wire [1:0] menu_mode;
wire [2:0] title_id;
wire [1:0] menu_sel;
wire [7:0] timer;
wire [9:0] score;
wire [11:0] timer_bcd;
wire [11:0] score_bcd;
wire [11:0] high_score_bcd;
wire [2:0] skill_charge;
wire [7:0] skill_timer;
wire skill_on;
wire game_over;

// The very first pixel of a frame is the game's clock: one tick = one step.
assign frame_tick = bg_tvalid && bg_tready && bg_tuser[0];

game_ctrl #(
	.MAX_OBJ(MAX_OBJ),
	.LANE_BITS(LANE_BITS),
	.XOFF_BITS(XOFF_BITS),
	.OBJ_TYPE_BITS(OBJ_TYPE_BITS),
	.OBJ_Y_BITS(OBJ_Y_BITS),
	.MAX_OBS(MAX_OBS),
	.OBS_X_BITS(OBS_X_BITS),
	.SKILL_ENABLE(SKILL_ENABLE),
	.SKILL_DURATION(SKILL_DURATION)
) u_game_ctrl (
	.clk(clk),
	.resetn(resetn),
	.frame_tick(frame_tick),

	.btn_left(btn_left),
	.btn_right(btn_right),
	.btn_jump(btn_jump),

	.player_x(player_x),
	.player_y(player_y),
	.player_dir(player_dir),
	.player_frame(player_frame),

	.obj_valid_bus(obj_valid_bus),
	.obj_lane_bus(obj_lane_bus),
	.obj_xoff_bus(obj_xoff_bus),
	.obj_ypos_bus(obj_ypos_bus),
	.obj_type_bus(obj_type_bus),

	.obs_valid_bus(obs_valid_bus),
	.obs_tall_bus(obs_tall_bus),
	.obs_xpos_bus(obs_xpos_bus),

	.menu_mode(menu_mode),
	.title_id(title_id),
	.menu_sel(menu_sel),

	.timer(timer),
	.score(score),
	.timer_bcd(timer_bcd),
	.score_bcd(score_bcd),
	.high_score_bcd(high_score_bcd),
	.skill_charge(skill_charge),
	.skill_timer(skill_timer),
	.skill_on(skill_on),
	.game_over(game_over)
);

bg_layer #(
	`SVO_PASS_PARAMS,
	.BG_TILE_FILE("src/assets/background.mem")
) u_bg_layer (
	.clk(clk),
	.resetn(resetn),

	.out_axis_tvalid(bg_tvalid),
	.out_axis_tready(bg_tready),
	.out_axis_tdata(bg_tdata),
	.out_axis_tuser(bg_tuser)
);

obj_layer #(
	`SVO_PASS_PARAMS,
	.MAX_OBJ(MAX_OBJ),
	.LANE_BITS(LANE_BITS),
	.XOFF_BITS(XOFF_BITS),
	.OBJ_TYPE_BITS(OBJ_TYPE_BITS),
	.OBJ_Y_BITS(OBJ_Y_BITS),
	.MAX_OBS(MAX_OBS),
	.OBS_X_BITS(OBS_X_BITS)
) u_obj_layer (
	.clk(clk),
	.resetn(resetn),

	.player_x(player_x),
	.player_y(player_y),
	.player_dir(player_dir),
	.player_frame(player_frame),
	.skill_on(skill_on),

	.obj_valid_bus(obj_valid_bus),
	.obj_lane_bus(obj_lane_bus),
	.obj_xoff_bus(obj_xoff_bus),
	.obj_ypos_bus(obj_ypos_bus),
	.obj_type_bus(obj_type_bus),

	.obs_valid_bus(obs_valid_bus),
	.obs_tall_bus(obs_tall_bus),
	.obs_xpos_bus(obs_xpos_bus),

	.in_axis_tvalid(bg_tvalid),
	.in_axis_tready(bg_tready),
	.in_axis_tdata(bg_tdata),
	.in_axis_tuser(bg_tuser),

	.out_axis_tvalid(obj_tvalid),
	.out_axis_tready(obj_tready),
	.out_axis_tdata(obj_tdata),
	.out_axis_tuser(obj_tuser)
);

ui_layer #(
	`SVO_PASS_PARAMS,
	.SKILL_ENABLE(SKILL_ENABLE)
) u_ui_layer (
	.clk(clk),
	.resetn(resetn),

	.timer_bcd(timer_bcd),
	.score_bcd(score_bcd),
	.high_score_bcd(high_score_bcd),
	.skill_charge(skill_charge),
	.skill_timer(skill_timer),
	.game_over(game_over),
	.btn_left(btn_left),
	.btn_right(btn_right),

	.in_axis_tvalid(obj_tvalid),
	.in_axis_tready(obj_tready),
	.in_axis_tdata(obj_tdata),
	.in_axis_tuser(obj_tuser),

	.out_axis_tvalid(ui_tvalid),
	.out_axis_tready(ui_tready),
	.out_axis_tdata(ui_tdata),
	.out_axis_tuser(ui_tuser)
);

res_overlay #(
	`SVO_PASS_PARAMS
) u_res_overlay (
	.clk(clk),
	.resetn(resetn),

	.mode(menu_mode),
	.title_id(title_id),
	.menu_sel(menu_sel),
	.score_bcd(score_bcd),
	.high_score_bcd(high_score_bcd),

	.in_axis_tvalid(ui_tvalid),
	.in_axis_tready(ui_tready),
	.in_axis_tdata(ui_tdata),
	.in_axis_tuser(ui_tuser),

	.out_axis_tvalid(out_axis_tvalid),
	.out_axis_tready(out_axis_tready),
	.out_axis_tdata(out_axis_tdata),
	.out_axis_tuser(out_axis_tuser)
);
endmodule
