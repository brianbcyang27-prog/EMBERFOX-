`timescale 1ns / 1ps
`include "game/game_defs.vh"

// ---------------------------------------------------------------------------
// EMBERFOX - game logic
//
// The coin game, plus a floor that fights back.
//
//   embers / shards   fall straight down, exactly as before -> CATCH them
//   ground obstacles  slide in from the right along the floor -> JUMP them
//
// So the fox now moves in two dimensions: left/right to line up under a
// falling ember, and up to clear an obstacle. Those two jobs pull against
// each other, and that tension is the game.
//
// Scoring is untouched: same 7 object types, same values, same 60 second
// clock, same high score.
//
// Everything below runs once per video frame, on `frame_tick`.
// ---------------------------------------------------------------------------

module game_ctrl #(
	// ---- falling objects (all unchanged from the coin game) --------------
	parameter MAX_OBJ = 6,
	parameter LANE_BITS = 4,
	parameter XOFF_BITS = 4,
	parameter OBJ_TYPE_BITS = 3,
	parameter OBJ_Y_BITS = 10,
	parameter FALL_SPEED = 2,
	parameter SPAWN_PERIOD_FRAMES = 24,

	// ---- ground obstacles -----------------------------------------------
	parameter MAX_OBS = 3,
	parameter OBS_X_BITS = 11,
	parameter OBS_SPEED_BASE = 3,     // px/frame at the start of a HARD run
	parameter OBS_PENALTY = 3,        // heat lost for tripping on a loss obstacle
	parameter OBS_BONUS = 1,          // heat gained for tripping on a gain obstacle
	parameter OBS_BURN_BONUS = 1,     // heat gained instead, while Ember burns

	// ---- moving and jumping ---------------------------------------------
	// Vertical numbers are 8.4 fixed point: 16 units = 1 screen pixel. Using
	// fractions lets gravity be gentler than "1 pixel per frame", which is the
	// difference between a floaty arc and a brick falling.
	parameter PLAYER_START_X = 288,
	parameter PLAYER_SPEED_START = 8,
	parameter GRAVITY        = 9,     // 0.56 px per frame, every frame
	parameter GRAVITY_DASH   = 7,     // gentler fall while Ember Dash is on
	parameter JUMP_V         = 176,   // 11.0 px/frame launch -> ~114 px peak
	parameter AIR_JUMP_V     = 140,   // 8.75 px/frame second jump
	parameter AIR_JUMPS_MAX  = 1,     // 1 = double jump

	// ---- scoring (unchanged from the coin game) --------------------------
	parameter TIMER_START = 60,
	parameter TIME_BONUS = 3,
	parameter FPS = 60,
	parameter SKILL_CHARGE_MAX = 5,
	parameter SKILL_ENABLE = 1,
	parameter SKILL_DURATION = 8
)(
	input clk,
	input resetn,
	input frame_tick,

	input btn_left,
	input btn_right,
	input btn_jump,

	output reg [9:0] player_x,
	output [9:0] player_y,
	output reg player_dir,
	output [1:0] player_frame,

	output [MAX_OBJ              -1:0] obj_valid_bus,
	output reg [MAX_OBJ*LANE_BITS    -1:0] obj_lane_bus,
	output reg [MAX_OBJ*XOFF_BITS    -1:0] obj_xoff_bus,
	output reg [MAX_OBJ*OBJ_Y_BITS   -1:0] obj_ypos_bus,
	output reg [MAX_OBJ*OBJ_TYPE_BITS-1:0] obj_type_bus,

	output [MAX_OBS            -1:0] obs_valid_bus,
	output [MAX_OBS            -1:0] obs_tall_bus,
	output [MAX_OBS            -1:0] obs_gain_bus,
	output reg [MAX_OBS*OBS_X_BITS-1:0] obs_xpos_bus,

	// start-menu display
	output [1:0] menu_mode,      // 0 = playing, 1 = game over, 2 = difficulty, 3 = skill
	output [2:0] title_id,       // which word the result panel shows
	output [1:0] menu_sel,       // which of the 3 options is highlighted

	output reg [7:0] timer,
	output reg [9:0] score,
	output [11:0] timer_bcd,
	output [11:0] score_bcd,
	output [11:0] high_score_bcd,
	output reg [2:0] skill_charge,
	output [7:0] skill_timer,
	output skill_on,
	output game_over
);
// State 0 was unused in the coin game; it is now the start menu.
localparam S_MENU_DIFF  = 0;
localparam S_PLAY       = 1;
localparam S_OVER       = 2;
localparam S_MENU_SKILL = 3;

localparam DIFF_EASY   = 0;
localparam DIFF_NORMAL = 1;
localparam DIFF_HARD   = 2;

localparam SKILL_EMBER = 0;
localparam SKILL_TIME  = 1;
localparam SKILL_LURE  = 2;

// title_id -> the word the panel shows (see res_overlay)
localparam TITLE_TIMEUP = 0;
localparam TITLE_EASY   = 1;
localparam TITLE_NORMAL = 2;
localparam TITLE_HARD   = 3;
localparam TITLE_EMBER  = 4;
localparam TITLE_TIME   = 5;
localparam TITLE_LURE   = 6;

localparam TYPE_COIN_1 = 0;
localparam TYPE_COIN_3 = 1;
localparam TYPE_COIN_5 = 2;
localparam TYPE_MINUS3 = 3;
localparam TYPE_MINUS5 = 4;
localparam TYPE_TIME = 5;
localparam TYPE_CHARGE = 6;

localparam [9:0] SCREEN_W = 640;
localparam [9:0] OBJ_GROUND_Y = `UI_TOP - `OBJ_H;
localparam [9:0] PLAYER_MAX_X = SCREEN_W - `PLAYER_W;

// ===========================================================================
// Storage
//
// Both kinds of thing use "slots with a valid bit": a slot is either in use or
// it is not, and killing something is just clearing its bit. Nothing has to
// shuffle down to fill a gap, which keeps the logic small - and it means
// several things can be removed in the same frame without any special case.
// ===========================================================================
reg [MAX_OBJ-1:0]       obj_valid;
reg [LANE_BITS    -1:0] obj_lane [0:MAX_OBJ-1];
reg [XOFF_BITS    -1:0] obj_xoff [0:MAX_OBJ-1];
reg [OBJ_TYPE_BITS-1:0] obj_type [0:MAX_OBJ-1];
reg [OBJ_Y_BITS   -1:0] obj_ypos [0:MAX_OBJ-1];

reg [MAX_OBS-1:0]      obs_valid;
reg [MAX_OBS-1:0]      obs_tall;      // 1 = the 64 px version
reg [MAX_OBS-1:0]      obs_gain;      // 1 = pays points, 0 = costs points
reg [OBS_X_BITS-1:0]   obs_xpos [0:MAX_OBS-1];

reg [1:0] state;
reg [1:0] diff_sel;
reg [1:0] skill_sel;
reg [7:0] frame_cnt;
reg [7:0] spawn_cnt;
reg [7:0] obs_cnt;
reg btn_start_q;
reg btn_jump_q;
reg btn_move_q;
reg restart_armed;

assign obj_valid_bus = obj_valid;
assign obs_valid_bus = obs_valid;
assign obs_tall_bus = obs_tall;
assign obs_gain_bus = obs_gain;
assign game_over = state == S_OVER;

wire in_menu = (state == S_MENU_DIFF) || (state == S_MENU_SKILL);

// ---------------------------------------------------------------------------
// What the result panel shows
// ---------------------------------------------------------------------------
assign menu_mode = (state == S_OVER)       ? 2'd1 :
				   (state == S_MENU_DIFF)  ? 2'd2 :
				   (state == S_MENU_SKILL) ? 2'd3 : 2'd0;

assign menu_sel = (state == S_MENU_SKILL) ? skill_sel : diff_sel;

assign title_id =
	(state == S_MENU_DIFF)  ? (diff_sel == DIFF_EASY   ? TITLE_EASY  :
							   diff_sel == DIFF_NORMAL ? TITLE_NORMAL : TITLE_HARD) :
	(state == S_MENU_SKILL) ? (skill_sel == SKILL_EMBER ? TITLE_EMBER :
							   skill_sel == SKILL_TIME  ? TITLE_TIME  : TITLE_LURE) :
							  TITLE_TIMEUP;

// ---------------------------------------------------------------------------
// Buttons
//
// Only three of them: LEFT, JUMP, RIGHT. Everything else is folded in:
//
//   in a run     LEFT / RIGHT move, JUMP jumps
//                LEFT + RIGHT together = use the skill. Holding both already
//                cancels out as movement (see the mover), so it was free.
//   in the menu  LEFT / RIGHT change the option, JUMP confirms it
//   results      JUMP = back to the menu
//
// `restart_armed` is why the run does not leave the results screen the instant
// it ends: if the clock runs out while the player is holding jump - mid-leap,
// which happens constantly - the button is already down. So the player has to
// LET GO once before jump counts.
// ---------------------------------------------------------------------------
wire skill_btn = btn_left && btn_right;
wire restart_press = btn_jump && game_over && restart_armed;

wire btn_start_rise = restart_press && !btn_start_q;
wire btn_jump_rise  = btn_jump && !btn_jump_q;
wire skill_btn_active = skill_btn && state == S_PLAY;
wire skill_start;

// Menu navigation: one step per press, so holding the button does not scroll.
// Exactly one of left/right must be down - holding both means nothing here.
wire menu_left  = btn_left && !btn_right;
wire menu_right = btn_right && !btn_left;
wire menu_move_rise = (menu_left || menu_right) && !btn_move_q;

always @(posedge clk) begin
	if (!resetn)
		restart_armed <= 1'b0;
	else if (!game_over)
		restart_armed <= 1'b0;      // during a run this means nothing
	else if (!btn_jump)
		restart_armed <= 1'b1;      // let go on the results screen -> armed
end

wire game_step = frame_tick && state == S_PLAY;
wire timer_tick = frame_cnt == FPS - 1;
wire sec_tick = game_step && timer_tick;

// ===========================================================================
// Ember Dash (the skill)
//
// skill_slot is unchanged - it still owns the button edge, the charge check
// and the countdown. Only the EFFECT is new. While skill_on is high:
//
//   1. frost shards and ground obstacles burn away and pay points
//      instead of costing them
//   2. gravity weakens, so jumps float and obstacles are easy to clear
//   3. the fox is drawn on fire
// ===========================================================================
skill_slot #(
	.ENABLE(SKILL_ENABLE),
	.DURATION(SKILL_DURATION),
	.CHARGE_MAX(SKILL_CHARGE_MAX)
) u_skill_slot (
	.clk(clk),
	.resetn(resetn),
	.sec_tick(sec_tick),
	.restart(btn_start_rise),
	.btn_skill(skill_btn_active),
	.skill_charge(skill_charge),
	.skill_timer(skill_timer),
	.skill_on(skill_on),
	.skill_start(skill_start)
);

// ===========================================================================
// Difficulty ramp
//
// The falling objects behave exactly as they always did. It is the FLOOR that
// gets meaner: obstacles arrive faster and closer together as the clock runs
// down. `elapsed` is guarded because a +time pickup can push `timer` back
// above its starting value.
// ===========================================================================
wire [7:0] elapsed = (timer >= TIMER_START) ? 8'd0 : (TIMER_START - timer);
wire [1:0] speed_level = elapsed[5:4];        // 0,1,2,3 over a 60 second run

reg [3:0] obs_speed_raw;
reg [7:0] obs_period;

// The difficulty chosen on the start menu sets how fast the floor comes at you
// and how often. HARD is the original tuning; EASY halves the ramp, slows the
// obstacles, spreads them out, and never sends a tall one.
always @(*) begin
	case (diff_sel)
		DIFF_EASY: begin
			// Flat: no ramp at all, and obstacles are far enough apart that
			// there is always time to line up under a falling ember.
			obs_speed_raw = 4'd2;
			obs_period    = 8'd190;
		end
		DIFF_NORMAL: begin
			obs_speed_raw = 4'd2 + {1'b0, speed_level[1]};   // 2,2,3,3
			case (speed_level)
				2'd0:    obs_period = 8'd160;
				2'd1:    obs_period = 8'd150;
				2'd2:    obs_period = 8'd140;
				default: obs_period = 8'd130;
			endcase
		end
		default: begin                                       // HARD
			obs_speed_raw = OBS_SPEED_BASE + {1'b0, speed_level[1]};  // 3,3,4,4
			case (speed_level)
				2'd0:    obs_period = 8'd130;
				2'd1:    obs_period = 8'd118;
				2'd2:    obs_period = 8'd106;
				default: obs_period = 8'd96;
			endcase
		end
	endcase
end

// ===========================================================================
// The three skills
//
// One of these is picked on the second menu page, and `skill_slot` decides
// WHEN it is running. Each effect is a mux on something that already existed.
//
//   EMBER  frost burns: shards and obstacles pay +1 instead of costing points,
//          and gravity weakens so jumps float
//   TIME   the world crawls: obstacles and falling objects move at half speed
//   LURE   the fox pulls embers in: the catch box reaches LURE_PAD further
//          out on both sides (the sprite does not change size)
// ===========================================================================
wire skill_ember = skill_on && (skill_sel == SKILL_EMBER);
wire skill_time  = skill_on && (skill_sel == SKILL_TIME);
wire skill_lure  = skill_on && (skill_sel == SKILL_LURE);

// TIME halves both speeds. Nothing may reach 0 or it would park on screen
// forever, so both results are floored at 1.
localparam [3:0] FALL_SPEED_NORM = FALL_SPEED;
localparam [3:0] FALL_SPEED_SLOW = (FALL_SPEED > 1) ? (FALL_SPEED >> 1) : 1;

wire [3:0] obs_speed  = skill_time ? ((obs_speed_raw >> 1) | 4'd1) : obs_speed_raw;
wire [3:0] fall_speed = skill_time ? FALL_SPEED_SLOW : FALL_SPEED_NORM;

// ===========================================================================
// Falling object spawning (unchanged from the coin game)
// ===========================================================================
wire [10:0] spawn_data;
wire spawn_fifo_empty;

wire [LANE_BITS-1:0] spawn_lane_raw = spawn_data[10:7];
wire [XOFF_BITS-1:0] spawn_xoff_raw = spawn_data[6:3];
wire [OBJ_TYPE_BITS-1:0] spawn_type_raw = spawn_data[2:0];
wire [LANE_BITS-1:0] spawn_lane;
wire [XOFF_BITS-1:0] spawn_xoff;
wire [OBJ_TYPE_BITS-1:0] spawn_type;

// Find a free slot. This is a priority encoder: the lowest empty slot wins.
integer f;
reg obj_free_found;
reg [2:0] obj_free_idx;
reg obs_free_found;
reg [1:0] obs_free_idx;

always @(*) begin
	obj_free_found = 1'b0;
	obj_free_idx = 3'd0;
	for (f = 0; f < MAX_OBJ; f = f + 1)
		if (!obj_free_found && !obj_valid[f]) begin
			obj_free_found = 1'b1;
			obj_free_idx = f[2:0];
		end

	obs_free_found = 1'b0;
	obs_free_idx = 2'd0;
	for (f = 0; f < MAX_OBS; f = f + 1)
		if (!obs_free_found && !obs_valid[f]) begin
			obs_free_found = 1'b1;
			obs_free_idx = f[1:0];
		end
end

wire spawn_pop = game_step && spawn_cnt == 0 && !spawn_fifo_empty && obj_free_found;
wire obs_spawn = game_step && obs_cnt == 0 && obs_free_found;

spawn_queue u_spawn_queue (
	.clk(clk),
	.resetn(resetn),
	.enable(state == S_PLAY),
	.pop(spawn_pop),
	.spawn_data(spawn_data),
	.empty(spawn_fifo_empty)
);

spawn_postprocess #(
	.LANE_BITS(LANE_BITS),
	.XOFF_BITS(XOFF_BITS),
	.OBJ_TYPE_BITS(OBJ_TYPE_BITS)
) u_spawn_postprocess (
	.clk(clk),
	.resetn(resetn),
	.fire(spawn_pop),
	.raw_lane(spawn_lane_raw),
	.raw_xoff(spawn_xoff_raw),
	.raw_type(spawn_type_raw),
	.out_lane(spawn_lane),
	.out_xoff(spawn_xoff),
	.out_type(spawn_type)
);

// ===========================================================================
// Vertical physics
// ===========================================================================
localparam [12:0] GROUND_FX = `GROUND_Y << 4;   // 5632 = standing on the floor
localparam [12:0] CEIL_FX   = `PLAY_TOP << 4;   //  256 = top of the play field

reg [12:0] player_y_fx;          // unsigned 8.4 position
reg signed [11:0] player_vy;     // signed   8.4 velocity, negative = going up
reg [1:0] air_jumps;
reg [3:0] anim_cnt;

wire on_ground = (player_y_fx == GROUND_FX);
// Ember weakens gravity. Deliberately NOT halved: float too well and the fox
// sails over the falling embers instead of catching them.
wire [4:0] gravity_eff = skill_ember ? GRAVITY_DASH : GRAVITY;

reg signed [11:0] vy_next;
reg signed [14:0] y_raw;
reg [12:0] y_commit;
reg signed [11:0] vy_commit;
reg [1:0] air_jumps_next;

always @(*) begin
	// 1. default: gravity pulls the fox down a little harder every frame
	vy_next = player_vy + $signed({7'd0, gravity_eff});

	// 2. a jump press overrides that
	if (btn_jump_rise && on_ground)
		vy_next = -JUMP_V;
	else if (btn_jump_rise && air_jumps != 0)
		vy_next = -AIR_JUMP_V;
	// 3. let go of jump while still rising -> cut the climb in half. This is
	//    what makes a tap a small hop and a hold a full jump, so one button
	//    covers both "nip over an obstacle" and "get up there".
	else if (!btn_jump && vy_next < 0)
		vy_next = vy_next >>> 1;

	// 4. move, then clamp against the floor and the ceiling
	y_raw = $signed({2'b00, player_y_fx}) + vy_next;

	if (y_raw >= $signed({2'b00, GROUND_FX})) begin
		y_commit  = GROUND_FX;      // landed
		vy_commit = 0;
	end else if (y_raw <= $signed({2'b00, CEIL_FX})) begin
		y_commit  = CEIL_FX;        // bonked the top of the screen
		vy_commit = 0;
	end else begin
		y_commit  = y_raw[12:0];
		vy_commit = vy_next;
	end

	// 5. air jumps refill the moment the fox is back on the floor
	if (btn_jump_rise && !on_ground && air_jumps != 0)
		air_jumps_next = air_jumps - 1'b1;
	else if (y_commit == GROUND_FX)
		air_jumps_next = AIR_JUMPS_MAX;
	else
		air_jumps_next = air_jumps;
end

assign player_y = {1'b0, player_y_fx[12:4]};   // drop the fractional bits

// Sprite frame: 0/1 = walk cycle, 2 = rising, 3 = falling.
assign player_frame = !on_ground ? (player_vy[11] ? 2'd2 : 2'd3)
								 : {1'b0, player_x[6]};

wire can_left = player_x > PLAYER_SPEED_START;
wire can_right = player_x + PLAYER_SPEED_START < PLAYER_MAX_X;

// ===========================================================================
// Collision 1: catching a falling object
// ===========================================================================
// ---------------------------------------------------------------------------
// The fox's four hitbox edges are REGISTERED.
//
// They only change once per frame (the fox only moves on frame_tick), but the
// adders and the Lure mux that build them used to sit at the head of the
// slowest path in the design: hitbox -> six rectangle tests -> which object
// -> what it is worth -> new score. Latching them takes all of that out of
// the path for free, and the values are identical when the next frame reads
// them.
//
// Lure widens the catch box without changing the drawn sprite. The left edge
// is clamped so it cannot wrap when the fox is against the left wall.
// ---------------------------------------------------------------------------
wire [10:0] lure_l_raw = (skill_lure && player_x > `LURE_PAD) ? (player_x - `LURE_PAD)
						 : (skill_lure ? 11'd0 : {1'b0, player_x});
wire [10:0] lure_r_raw = skill_lure ? (player_x + `PLAYER_W + `LURE_PAD)
									: (player_x + `PLAYER_W);

reg [10:0] hit_player_l;
reg [10:0] hit_player_r;
reg [10:0] hit_player_t;
reg [10:0] hit_player_b;

always @(posedge clk) begin
	if (!resetn) begin
		hit_player_l <= 0;
		hit_player_r <= 0;
		hit_player_t <= 0;
		hit_player_b <= 0;
	end else begin
		hit_player_l <= lure_l_raw;
		hit_player_r <= lure_r_raw;
		hit_player_t <= player_y + `PLAYER_PAD_T;
		hit_player_b <= player_y + `PLAYER_H;
	end
end

function [9:0] obj_x;
	input [LANE_BITS-1:0] lane;
	input [XOFF_BITS-1:0] xoff;
	begin obj_x = `GAME_X0 + ({6'd0, lane} << 5) + {6'd0, xoff}; end
endfunction

integer hit_i;
reg hit_valid;
reg [2:0] hit_idx;
reg [9:0] hit_obj_x;

always @(*) begin
	hit_valid = 0;
	hit_idx = 0;
	hit_obj_x = 0;

	for (hit_i = 0; hit_i < MAX_OBJ; hit_i = hit_i + 1) begin
		hit_obj_x = obj_x(obj_lane[hit_i], obj_xoff[hit_i]);

		if (!hit_valid && obj_valid[hit_i] &&
			hit_player_l < hit_obj_x + `OBJ_W &&
			hit_player_r > hit_obj_x &&
			hit_player_t < obj_ypos[hit_i] + `OBJ_H &&
			hit_player_b > obj_ypos[hit_i]) begin
			hit_valid = 1;
			hit_idx = hit_i[2:0];
		end
	end
end

// ===========================================================================
// Collision 2: tripping on a ground obstacle
//
// Obstacles never move vertically, so their top and bottom edges are
// CONSTANTS. Only the fox's own height varies, which makes this test far
// cheaper than the falling-object one above.
// ===========================================================================
// Registered for the same reason as the catch box above. Lure does not apply
// here - it helps you collect, it does not make you trip more.
reg [10:0] trip_l;
reg [10:0] trip_r;

always @(posedge clk) begin
	if (!resetn) begin
		trip_l <= 0;
		trip_r <= 0;
	end else begin
		trip_l <= player_x + `PLAYER_PAD_X;
		trip_r <= player_x + `PLAYER_W - `PLAYER_PAD_X;
	end
end

// Both obstacle heights end at the floor, so "am I high enough?" is two shared
// comparisons rather than one per obstacle - only the pick between them is
// per-obstacle.
wire feet_below_short = hit_player_b > `OBS_Y;
wire feet_below_tall  = hit_player_b > `OBS_TALL_Y;

integer obs_i;
reg obs_hit_valid;
reg [1:0] obs_hit_idx;
reg [10:0] trip_obs_x;

always @(*) begin
	obs_hit_valid = 0;
	obs_hit_idx = 0;
	trip_obs_x = 0;

	for (obs_i = 0; obs_i < MAX_OBS; obs_i = obs_i + 1) begin
		// un-bias into screen space for the comparison
		trip_obs_x = obs_xpos[obs_i] - `OBS_X_BIAS;

		if (!obs_hit_valid && obs_valid[obs_i] &&
			(obs_tall[obs_i] ? feet_below_tall : feet_below_short) &&
			trip_l < trip_obs_x + `OBS_W &&
			trip_r > trip_obs_x) begin
			obs_hit_valid = 1;
			obs_hit_idx = obs_i[1:0];
		end
	end
end

// ===========================================================================
// What a collision does to the score
//
// Both kinds of collision can land on the same frame, so the two point
// changes are added together before the result is clamped once.
// ===========================================================================
reg [9:0] next_score;
reg [7:0] next_timer;
reg [2:0] next_charge;
reg signed [7:0] score_delta;
reg signed [7:0] score_delta_eff;
reg signed [11:0] score_sum;

wire any_hit = hit_valid || obs_hit_valid;
reg [9:0] high_score;

wire hit_is_hazard = (obj_type[hit_idx] == TYPE_MINUS3) ||
					 (obj_type[hit_idx] == TYPE_MINUS5);

always @(*) begin
	next_score = score;
	next_timer = timer;
	next_charge = skill_charge;
	score_delta = 0;
	score_delta_eff = 0;
	score_sum = 0;

	// --- caught a falling object ---
	if (hit_valid) begin
		case (obj_type[hit_idx])
			TYPE_COIN_1: score_delta = 1;
			TYPE_COIN_3: score_delta = 3;
			TYPE_COIN_5: score_delta = 5;
			TYPE_MINUS3: score_delta = -3;
			TYPE_MINUS5: score_delta = -5;
			TYPE_TIME: next_timer = timer + TIME_BONUS;
			TYPE_CHARGE:
				if (skill_charge < SKILL_CHARGE_MAX)
					next_charge = skill_charge + 1;
			default: begin
				next_timer = timer;
				next_charge = skill_charge;
			end
		endcase

		// EMBER: a burning fox destroys frost instead of being hurt by it
		if (skill_ember && hit_is_hazard)
			score_delta_eff = OBS_BURN_BONUS;
		else
			score_delta_eff = score_delta;
	end

	// --- tripped on a ground obstacle ---
	if (obs_hit_valid) begin
		if (obs_gain[obs_hit_idx])
			score_delta_eff = score_delta_eff + OBS_BONUS;
		else if (skill_ember)
			score_delta_eff = score_delta_eff + OBS_BURN_BONUS;
		else
			score_delta_eff = score_delta_eff - OBS_PENALTY;
	end

	score_sum = $signed({2'b00, score}) + score_delta_eff;
	if (score_sum < 0)
		next_score = 0;
	else if (score_sum > 999)
		next_score = 10'd999;
	else
		next_score = score_sum[9:0];
end

wire game_ending = sec_tick && next_timer <= 1;
// Compare in BINARY, not BCD. Going through the converter first would drag a
// whole double-dabble chain into the collision path (see below).
wire new_high_score = next_score > high_score;
wire high_score_will_update = game_ending && new_high_score;

// ---------------------------------------------------------------------------
// The BCD converters read REGISTERS, never live collision results.
//
// bin2bcd is a double-dabble: a long ripple of compare-and-add-3 stages. An
// earlier version fed it `final_score`, i.e. the score including this instant's
// collision. That put the whole chain
//
//     player_y -> collision -> which object -> what it is worth
//              -> new score -> double dabble -> BCD
//
// into a single clock, and it was by far the slowest path in the design
// (-14.5 ns of setup slack; it did not meet timing at all).
//
// Reading `score` instead costs nothing visually: `score` is updated on
// frame_tick, which is the FIRST pixel of the frame, and the UI does not draw
// the digits until hundreds of clocks later in that same frame. The displayed
// number is identical - it just is not required to settle instantly.
// ---------------------------------------------------------------------------
bin2bcd #(
	.BIN_BITS(10)
) u_score_bcd (
	.bin(score),
	.bcd(score_bcd)
);

bin2bcd #(
	.BIN_BITS(10)
) u_high_score_bcd (
	.bin(high_score),
	.bcd(high_score_bcd)
);

bin2bcd #(
	.BIN_BITS(8)
) u_timer_bcd (
	.bin(timer),
	.bcd(timer_bcd)
);

// ===========================================================================
// Pack everything into flat buses for the render layer
// ===========================================================================
integer pack_i;

always @(*) begin
	obj_lane_bus = 0;
	obj_xoff_bus = 0;
	obj_ypos_bus = 0;
	obj_type_bus = 0;
	obs_xpos_bus = 0;

	for (pack_i = 0; pack_i < MAX_OBJ; pack_i = pack_i + 1) begin
		obj_lane_bus[pack_i*LANE_BITS     +: LANE_BITS]     = obj_lane[pack_i];
		obj_xoff_bus[pack_i*XOFF_BITS     +: XOFF_BITS]     = obj_xoff[pack_i];
		obj_ypos_bus[pack_i*OBJ_Y_BITS    +: OBJ_Y_BITS]    = obj_ypos[pack_i];
		obj_type_bus[pack_i*OBJ_TYPE_BITS +: OBJ_TYPE_BITS] = obj_type[pack_i];
	end

	for (pack_i = 0; pack_i < MAX_OBS; pack_i = pack_i + 1)
		obs_xpos_bus[pack_i*OBS_X_BITS +: OBS_X_BITS] = obs_xpos[pack_i];
end

// ===========================================================================
// The one clocked block: everything advances once per frame
// ===========================================================================
integer i;

always @(posedge clk) begin
	if (!resetn) begin
		player_x <= PLAYER_START_X;
		player_dir <= 1;
		player_y_fx <= GROUND_FX;
		player_vy <= 0;
		air_jumps <= AIR_JUMPS_MAX;
		obj_valid <= 0;
		obs_valid <= 0;
		obs_tall <= 0;
		obs_gain <= 0;
		timer <= TIMER_START;
		score <= 0;
		high_score <= 0;
		skill_charge <= 0;
		// Reset lands on the start menu, not straight into a run.
		state <= S_MENU_DIFF;
		diff_sel <= DIFF_NORMAL;
		skill_sel <= SKILL_EMBER;
		frame_cnt <= 0;
		anim_cnt <= 0;
		spawn_cnt <= SPAWN_PERIOD_FRAMES;
		obs_cnt <= 8'd95;
		btn_start_q <= 0;
		btn_jump_q <= 0;
		btn_move_q <= 0;

		for (i = 0; i < MAX_OBJ; i = i + 1) begin
			obj_lane[i] <= 0;
			obj_xoff[i] <= 0;
			obj_ypos[i] <= 0;
			obj_type[i] <= 0;
		end
		for (i = 0; i < MAX_OBS; i = i + 1)
			obs_xpos[i] <= 0;
	end else begin
		btn_start_q <= restart_press;

		// Sample the buttons once per FRAME, not once per clock. The game only
		// advances on frame_tick, so a one-clock-wide rising edge would almost
		// always land between two frames and be lost - about 9 out of 10
		// presses. This is done for every state so the menu gets edges too.
		if (frame_tick) begin
			btn_jump_q <= btn_jump;
			btn_move_q <= menu_left || menu_right;
		end

		if (btn_start_rise) begin
			// Results screen -> back to the start menu, so the difficulty and
			// skill can be changed before the next run. The high score is kept.
			state <= S_MENU_DIFF;
			obj_valid <= 0;
			obs_valid <= 0;
			obs_tall <= 0;
			obs_gain <= 0;
			// The jump button that got us here is still held down. Pretend it
			// was already down last frame so it does not immediately confirm
			// the menu as well.
			btn_jump_q <= 1'b1;
		end else if (frame_tick && in_menu) begin
			// ---------------------------------------------------------------
			// Start menu: LEFT / RIGHT pick, JUMP confirms.
			//
			// Page 1 chooses the difficulty, page 2 chooses the skill, then
			// the run begins. One step per press (menu_move_rise), so holding
			// the button does not race through the options.
			// ---------------------------------------------------------------
			if (menu_move_rise) begin
				if (state == S_MENU_DIFF)
					diff_sel <= menu_left ? (diff_sel == 2'd0 ? 2'd2 : diff_sel - 1'b1)
										  : (diff_sel == 2'd2 ? 2'd0 : diff_sel + 1'b1);
				else
					skill_sel <= menu_left ? (skill_sel == 2'd0 ? 2'd2 : skill_sel - 1'b1)
										   : (skill_sel == 2'd2 ? 2'd0 : skill_sel + 1'b1);
			end else if (btn_jump_rise) begin
				if (state == S_MENU_DIFF) begin
					state <= S_MENU_SKILL;
				end else begin
					// ---- start the run ----
					player_x <= PLAYER_START_X;
					player_dir <= 1;
					player_y_fx <= GROUND_FX;
					player_vy <= 0;
					air_jumps <= AIR_JUMPS_MAX;
				obj_valid <= 0;
				obs_valid <= 0;
				obs_tall <= 0;
				obs_gain <= 0;
				timer <= TIMER_START;
				score <= 0;
				skill_charge <= 0;
					state <= S_PLAY;
					frame_cnt <= 0;
					anim_cnt <= 0;
					spawn_cnt <= SPAWN_PERIOD_FRAMES;
					obs_cnt <= 8'd120;
				end
			end
		end else begin
			if (game_step) begin

				anim_cnt <= anim_cnt + 1'b1;

				// ---- move sideways (unchanged from the coin game) ----
				// Holding both cancels out, which is what frees LEFT+RIGHT to
				// mean "use the skill".
				if (btn_left && !btn_right) begin
					if (can_left)
						player_x <= player_x - PLAYER_SPEED_START;
					else
						player_x <= 0;
					player_dir <= 0;
				end else if (btn_right && !btn_left) begin
					if (can_right)
						player_x <= player_x + PLAYER_SPEED_START;
					else
						player_x <= PLAYER_MAX_X;
					player_dir <= 1;
				end

				// ---- jump / fall ----
				player_y_fx <= y_commit;
				player_vy <= vy_commit;
				air_jumps <= air_jumps_next;

				// ---- pickup / trip effect ----
				if (any_hit) begin
					score <= next_score;
					timer <= next_timer;
					skill_charge <= next_charge;
				end

				// ---- falling objects: fall, be caught, or hit the floor ----
				for (i = 0; i < MAX_OBJ; i = i + 1) begin
					if (obj_valid[i]) begin
						if (hit_valid && i == hit_idx)
							obj_valid[i] <= 1'b0;                  // caught
						else if (obj_ypos[i] >= OBJ_GROUND_Y)
							obj_valid[i] <= 1'b0;                  // missed
						else
							obj_ypos[i] <= obj_ypos[i] + {6'd0, fall_speed};
					end
				end

				if (spawn_pop) begin
					obj_valid[obj_free_idx] <= 1'b1;
					obj_lane[obj_free_idx] <= spawn_lane;
					obj_xoff[obj_free_idx] <= spawn_xoff;
					obj_type[obj_free_idx] <= spawn_type;
					obj_ypos[obj_free_idx] <= 0;
				end

				// ---- ground obstacles: slide left, be jumped, or exit ----
				// No underflow guard is needed: a slot is killed once it is at
				// or below OBS_KILL_X (32), and the speed never exceeds 7, so
				// anything still alive is above 32 and stays positive.
				for (i = 0; i < MAX_OBS; i = i + 1) begin
					if (obs_valid[i]) begin
						if (obs_hit_valid && i == obs_hit_idx)
							obs_valid[i] <= 1'b0;                  // shattered
						else if (obs_xpos[i] <= `OBS_KILL_X)
							obs_valid[i] <= 1'b0;                  // left the screen
						else
							obs_xpos[i] <= obs_xpos[i] - {7'd0, obs_speed};
					end
				end

				if (obs_spawn) begin
					obs_valid[obs_free_idx] <= 1'b1;
					obs_xpos[obs_free_idx] <= `OBS_SPAWN_X;
					// The bits come from the head of the spawn FIFO, which is
					// already random and already changing - no second LFSR.
					obs_tall[obs_free_idx] <= (diff_sel == DIFF_HARD) && spawn_data[10];
					obs_gain[obs_free_idx] <= spawn_data[9];
				end

				// ---- spawn countdowns ----
				if (spawn_pop)
					spawn_cnt <= SPAWN_PERIOD_FRAMES - 1;
				else if (spawn_cnt != 0)
					spawn_cnt <= spawn_cnt - 1'b1;

				if (obs_spawn)
					obs_cnt <= obs_period - 1'b1;
				else if (obs_cnt != 0)
					obs_cnt <= obs_cnt - 1'b1;

				// ---- one second of the clock ----
				if (timer_tick) begin
					frame_cnt <= 0;

					if (next_timer > 1) begin
						timer <= next_timer - 1'b1;
					end else begin
						timer <= 0;
						state <= S_OVER;
						if (high_score_will_update) begin
							high_score <= next_score;
						end
					end
				end else begin
					frame_cnt <= frame_cnt + 1'b1;
				end
			end
		end

		if (SKILL_ENABLE && skill_start)
			skill_charge <= 0;
	end
end
endmodule
