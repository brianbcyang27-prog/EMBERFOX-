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
// Scoring keeps the same 7 object types and values. The clock runs 90 seconds
// on every difficulty (so one BEST score stays comparable), and the fox can
// triple-jump.
//
// Every run opens with a short teaching window: hazard-free falling objects
// for a few seconds, and on EASY / NORMAL the whole first ramp tier (24 s)
// never sends a ridge that costs points.
//
// ---------------------------------------------------------------------------
// Can this actually be jumped?
//
// A ridge does not move vertically, so clearing one is a race between two
// durations:
//
//     sweep   how long the ridge overlaps the fox        (OBS_W + 24) / speed
//     hang    how long a jump holds the feet above it
//
// With GRAVITY = 7 and JUMP_V = 176 a full jump is airborne for 50 frames and
// spends 44 of them above a short ridge and 37 above a tall one. So:
//
//     speed 1  ->  sweep 56 frames   IMPOSSIBLE, the ridge is still under the
//                                    fox when the jump ends
//     speed 2  ->  sweep 28 frames   clears, comfortably
//     speed 3  ->  sweep 19 frames   clears, easily
//
// That is the single most important number in this file, and it is why EASY
// does NOT use the slowest ridges. A slow ridge is a HARDER ridge: it lingers
// under the fox for longer than any jump can last. EASY instead keeps the
// speed at 2 and buys its easiness with a huge gap between ridges, no tall
// ones, and a much gentler falling-object mix (see spawn_postprocess).
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
	// Speed, spacing and tall-ridge permission all come from the difficulty
	// table further down; only the shared constants live here.
	//
	// Ridges no longer touch the score at all. They are the HEALTH half of the
	// game: a loss ridge costs one HP, a gain ridge returns one. That split -
	// falling things move the score, ground things move your health - is what
	// makes both bars worth watching, and it takes the ridge penalty out of
	// the score arithmetic entirely.
	parameter MAX_OBS = 3,
	parameter OBS_X_BITS = 11,
	parameter HP_MAX = 5,             // full health, and the number of bar segments
	parameter OBS_BURN_BONUS = 1,     // heat a frost shard pays while Ember burns

	// ---- moving and jumping ---------------------------------------------
	// Vertical numbers are 8.4 fixed point: 16 units = 1 screen pixel. Using
	// fractions lets gravity be gentler than "1 pixel per frame", which is the
	// difference between a floaty arc and a brick falling.
	parameter PLAYER_START_X = 288,
	parameter PLAYER_SPEED_START = 8,
	parameter PLAYER_SPEED_EMBER = 12,  // Ember also makes the fox quicker
	parameter GRAVITY        = 7,     // 0.44 px per frame, every frame
	parameter GRAVITY_EMBER  = 5,     // gentler fall while Ember burns
	parameter JUMP_V         = 176,   // 11.0 px/frame launch -> ~138 px peak
	parameter AIR_JUMP_V     = 140,   // 8.75 px/frame second jump
	parameter AIR_JUMPS_MAX  = 2,     // 2 = triple jump

	// ---- scoring (unchanged from the coin game) --------------------------
	parameter TIMER_START = 90,
	parameter TIME_BONUS = 3,
	parameter FPS = 60,
	parameter GOLD_MULT = 3,          // Gold Rush multiplier on every catch
	parameter GOLD_SHARD = 3,         // what a frost shard pays during Gold Rush
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
	output reg [MAX_OBS*3      -1:0] obs_btn_bus,
	output reg [MAX_OBS*OBS_X_BITS-1:0] obs_xpos_bus,

	// start-menu display
	output [2:0] menu_mode,      // 0 = playing, 1 = game over, 2 = difficulty, 3 = skill, 4 = how-to, 5 = countdown
	output [2:0] title_id,       // which word the result panel shows
	output [1:0] menu_sel,       // which of the 3 options is highlighted
	output reg [2:0] count_val,  // 3..1 during the pre-game countdown

	output reg [7:0] timer,
	output reg [9:0] score,
	output [11:0] timer_bcd,
	output [11:0] score_bcd,
	output [11:0] high_score_bcd,
	output reg [2:0] skill_charge,
	output [7:0] skill_timer,
	output skill_on,
	output reg [1:0] skill_sel,  // which skill is equipped (colours the UI)
	output game_over,

	// Health, 0..HP_MAX. Drives the bar in the bottom-right of the UI, where
	// the best score used to be - the best score is still on the results panel,
	// and a bar you must watch is worth more screen space mid-run than a number
	// you cannot change.
	output reg [2:0] hp,

	// The multiplier the UI shows. Normally the combo streak (1..3); while
	// Gold Rush is running it is pinned to GOLD_MULT, so the same digit that
	// already existed tells the player the skill is paying out.
	output [2:0] score_mult,

	// One frame of "that hurt": drives a red flash on the score digits. This
	// replaces a screen-shake output that was declared 1 bit wide while being
	// assigned a 10 bit value, so every offset it produced truncated to 0 and
	// nothing ever moved.
	output hurt,

	// Results-screen reveal: 0 = score only, 1 = best score has popped in,
	// 2 = PLAY AGAIN / LEAVE choice is up. Drives res_overlay.
	output reg [1:0] over_phase
);
// State 0 was unused in the coin game; it is now the start menu.
localparam S_MENU_DIFF  = 0;
localparam S_PLAY       = 1;
localparam S_OVER       = 2;
localparam S_MENU_SKILL = 3;
localparam S_HOWTO      = 4;     // full-screen how-to page (JUMP to begin the menu; shown once at power-on)
localparam S_COUNT      = 5;     // pre-game countdown 5..1, then S_PLAY

localparam DIFF_EASY   = 0;
localparam DIFF_NORMAL = 1;
localparam DIFF_HARD   = 2;

localparam SKILL_EMBER = 0;
localparam SKILL_GOLD  = 1;
localparam SKILL_LURE  = 2;

// title_id -> the word the panel shows (see res_overlay)
localparam TITLE_TIMEUP = 0;
localparam TITLE_EASY   = 1;
localparam TITLE_NORMAL = 2;
localparam TITLE_HARD   = 3;
localparam TITLE_EMBER  = 4;
localparam TITLE_GOLD   = 5;
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
(* ramstyle = "distributed" *) reg [LANE_BITS    -1:0] obj_lane [0:MAX_OBJ-1];
(* ramstyle = "distributed" *) reg [XOFF_BITS    -1:0] obj_xoff [0:MAX_OBJ-1];
(* ramstyle = "distributed" *) reg [OBJ_TYPE_BITS-1:0] obj_type [0:MAX_OBJ-1];
(* ramstyle = "distributed" *) reg [OBJ_Y_BITS   -1:0] obj_ypos [0:MAX_OBJ-1];

reg [MAX_OBS-1:0]      obs_valid;
reg [MAX_OBS-1:0]      obs_tall;      // 1 = the 64 px version
reg [MAX_OBS-1:0]      obs_gain;      // 1 = pays points, 0 = costs points
(* ramstyle = "distributed" *) reg [2:0] obs_btn [0:MAX_OBS-1];      // 0..4 = button sprite, atlas slots 7..11
(* ramstyle = "distributed" *) reg [OBS_X_BITS-1:0]   obs_xpos [0:MAX_OBS-1];

reg [2:0] state;
reg [1:0] diff_sel;
reg [7:0] frame_cnt;
reg [7:0] spawn_cnt;
reg [7:0] obs_cnt;
reg [7:0] count_frames;  // 0..FPS-1, one second of the countdown
reg [11:0] warmup_cnt;   // frames since the run began; < warmup_frames = teaching
reg btn_jump_q;
reg btn_move_q;

// Combo multiplier: increments on consecutive catches, resets on trip or on
// letting a *valuable* ember hit the floor. Missing a frost shard is correct
// play, so it deliberately does not break the streak.
reg [3:0] combo_cnt;      // 0..15
reg [2:0] combo_mult;     // 1..3 (1x, 2x, 3x)

// "That hurt" flash: 8 frames of red score digits after losing heat.
reg [3:0] hurt_cnt;

// Results-screen reveal. over_cnt counts frames since the run ended; the
// phase triggers are bit-tests, not compares, to keep the gate count down:
// bit6 (frame 64) = the best score pops in, bit7 (frame 128) = the
// PLAY AGAIN / LEAVE choice appears. over_sel is the choice: 0 = play again
// (default), 1 = leave to the menu.
reg [6:0] over_cnt;
reg over_sel;

assign obj_valid_bus = obj_valid;
assign obs_valid_bus = obs_valid;
assign obs_tall_bus = obs_tall;
assign game_over = state == S_OVER;
assign hurt = hurt_cnt != 0;

wire in_menu = (state == S_MENU_DIFF) || (state == S_MENU_SKILL) || (state == S_HOWTO);

// ---------------------------------------------------------------------------
// What the result panel shows
// ---------------------------------------------------------------------------
assign menu_mode = (state == S_OVER)       ? 3'd1 :
				   (state == S_MENU_DIFF)  ? 3'd2 :
				   (state == S_MENU_SKILL) ? 3'd3 :
				   (state == S_HOWTO)      ? 3'd4 :
				   (state == S_COUNT)      ? 3'd5 : 3'd0;

assign menu_sel = (state == S_MENU_SKILL) ? skill_sel :
				  (state == S_OVER)       ? {1'b0, over_sel} :
											 diff_sel;

assign title_id =
	(state == S_MENU_DIFF)  ? (diff_sel == DIFF_EASY   ? TITLE_EASY  :
							   diff_sel == DIFF_NORMAL ? TITLE_NORMAL : TITLE_HARD) :
	(state == S_MENU_SKILL) ? (skill_sel == SKILL_EMBER ? TITLE_EMBER :
							   skill_sel == SKILL_GOLD  ? TITLE_GOLD  : TITLE_LURE) :
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
//   results      once the choice appears, LEFT / RIGHT pick PLAY AGAIN or
//                LEAVE and JUMP confirms. The choice is gated on over_phase,
//                and btn_jump_rise is a one-shot per press, so the jump that
//                ended the run can never confirm the results screen early.
// ---------------------------------------------------------------------------
wire skill_btn = btn_left && btn_right;
wire btn_jump_rise  = btn_jump && !btn_jump_q;
wire skill_btn_active = skill_btn && state == S_PLAY;
wire skill_start;

// Menu navigation: one step per press, so holding the button does not scroll.
// Exactly one of left/right must be down - holding both means nothing here.
wire menu_left  = btn_left && !btn_right;
wire menu_right = btn_right && !btn_left;
wire menu_move_rise = (menu_left || menu_right) && !btn_move_q;

wire game_step = frame_tick && state == S_PLAY;

// Stop the skill timer the first frame the run ends (one pulse, because
// The countdown start clears the charge on the next run; the restart pulses
// on every results-screen frame keep the dash timer pinned at 0 so a dash
// that was active when time ran out cannot linger behind the panel.
wire skill_restart = game_over && frame_tick;
wire timer_tick = frame_cnt == FPS - 1;
wire sec_tick = game_step && timer_tick;

// True while the run's opening teaching window is still open. The length of
// that window is itself a difficulty setting - see the table below.
wire warmup = warmup_cnt < warmup_frames;

// ===========================================================================
// The skill slot
//
// skill_slot is unchanged - it still owns the button edge, the charge check
// and the countdown. WHICH skill runs is picked on the second menu page, and
// each effect is muxed onto something that already existed. See "the three
// skills" below.
// ===========================================================================
skill_slot #(
	.ENABLE(SKILL_ENABLE),
	.DURATION(SKILL_DURATION),
	.CHARGE_MAX(SKILL_CHARGE_MAX)
) u_skill_slot (
	.clk(clk),
	.resetn(resetn),
	.sec_tick(sec_tick),
	.restart(skill_restart),
	.btn_skill(skill_btn_active),
	.skill_charge(skill_charge),
	.skill_timer(skill_timer),
	.skill_on(skill_on),
	.skill_start(skill_start)
);

// ===========================================================================
// Difficulty
//
// This block is the whole of what EASY / NORMAL / HARD mean. Before, it set
// only the ridge speed and spacing, so the falling half of the game - which
// is where nearly all the score comes from - played identically on all three
// and the menu was close to decorative. It now drives eight things:
//
//                        EASY        NORMAL          HARD
//   ridge speed          2 flat      2 -> 3          3 -> 4
//   ridge gap (frames)   240         180 -> 140      150 -> 105
//   tall ridges          no          no              yes
//   fall speed           2           2               3
//   falling gap          30          24              20
//   trip penalty         -1          -2              -3
//   teaching window      8 s         5 s             3 s
//
// plus the hazard mix, which lives in spawn_postprocess because that is where
// the object type is decided.
//
// Note the ridge speeds: EASY is 2, not 1. A ridge slower than 2 px/frame
// takes longer to slide past the fox than a jump lasts, so "slow" would make
// it unjumpable - see the header comment.
//
// `elapsed` is guarded because a +time pickup can push `timer` back above its
// starting value.
// ===========================================================================
wire [7:0] elapsed = (timer >= TIMER_START) ? 8'd0 : (TIMER_START - timer);
// Four 24-second tiers over the 90 second run, so the ramp never resets.
wire [1:0] speed_level = (elapsed >= 8'd72) ? 2'd3 :
                         (elapsed >= 8'd48) ? 2'd2 :
                         (elapsed >= 8'd24) ? 2'd1 : 2'd0;

reg [3:0] obs_speed;
reg [7:0] obs_period;
reg [3:0] fall_speed;
reg [7:0] fall_period;
reg [2:0] hp_start;          // health at the start of a run
reg [11:0] warmup_frames;
reg        allow_tall;

always @(*) begin
	case (diff_sel)
		DIFF_EASY: begin
			// No ramp at all. The ridges still move at a jumpable 2 px/frame;
			// what makes EASY easy is that they are 4 seconds apart, never
			// tall, and you start with a full 5 HP.
			obs_speed     = 4'd2;
			obs_period    = 8'd240;
			fall_speed    = 4'd2;
			fall_period   = 8'd30;
			hp_start      = 3'd5;      // full bar
			warmup_frames = 12'd480;    // 8 s
			allow_tall    = 1'b0;
		end
		DIFF_NORMAL: begin
			obs_speed     = 4'd2 + {3'd0, speed_level[1]};   // 2,2,3,3
			case (speed_level)
				2'd0:    obs_period = 8'd180;
				2'd1:    obs_period = 8'd165;
				2'd2:    obs_period = 8'd150;
				default: obs_period = 8'd140;
			endcase
			fall_speed    = 4'd2;
			fall_period   = 8'd24;
			hp_start      = 3'd4;
			warmup_frames = 12'd300;    // 5 s
			allow_tall    = 1'b0;
		end
		default: begin                                       // HARD
			obs_speed     = 4'd3 + {3'd0, speed_level[1]};   // 3,3,4,4
			case (speed_level)
				2'd0:    obs_period = 8'd150;
				2'd1:    obs_period = 8'd135;
				2'd2:    obs_period = 8'd120;
				default: obs_period = 8'd105;
			endcase
			fall_speed    = 4'd3;
			fall_period   = 8'd20;
			hp_start      = 3'd3;      // three mistakes and the run is over
			warmup_frames = 12'd180;    // 3 s
			allow_tall    = 1'b1;
		end
	endcase
end

// ===========================================================================
// The three skills
//
// One of these is picked on the second menu page, and `skill_slot` decides
// WHEN it is running. Each effect is a mux on something that already existed.
//
// The old set was three flavours of "things move at a different speed", which
// is why firing a skill felt like nothing was happening: the world got slower
// or the fox floated, and the score did not change. Two of the three are now
// real buffs, one on the fox and one on what falls.
//
//   EMBER  a buff on the FOX. Frost cannot hurt it: falling shards and loss
//          ridges pay +1 instead of costing heat. It also moves half again as
//          fast and jumps higher. For 8 seconds you can walk through anything.
//
//   GOLD   a buff on the FALLING SCORE. Every ember is worth GOLD_MULT times
//          its face value - a +5 pays 15 - and frost shards stop being a
//          hazard at all, paying GOLD_SHARD instead. The multiplier digit in
//          the UI switches to x3 so the payout is visible, not just felt.
//
//   LURE   a buff on the FOX's reach. The catch box grows LURE_PAD to the left
//          and right and loses its top padding, so embers are collected from
//          well outside the sprite and from above the fox's head.
// ===========================================================================
wire skill_ember = skill_on && (skill_sel == SKILL_EMBER);
wire skill_gold  = skill_on && (skill_sel == SKILL_GOLD);
wire skill_lure  = skill_on && (skill_sel == SKILL_LURE);

// The multiplier that actually multiplies. Gold pins it to GOLD_MULT rather
// than stacking with the combo streak: stacked, a +5 during a 3x combo would
// pay 45 and one skill use would out-score the rest of the run.
assign score_mult = skill_gold ? GOLD_MULT[2:0] : combo_mult;

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
	.warmup(warmup),
	.diff(diff_sel),
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
wire [4:0] gravity_eff = skill_ember ? GRAVITY_EMBER : GRAVITY;

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

// Ember also speeds the fox up - the "buff on the character" half of it.
wire [4:0] move_speed = skill_ember ? PLAYER_SPEED_EMBER[4:0] : PLAYER_SPEED_START[4:0];
wire can_left = player_x > {5'd0, move_speed};
wire can_right = player_x + {5'd0, move_speed} < PLAYER_MAX_X;

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
// Lure widens the catch box without changing the drawn sprite, and also drops
// the top padding so embers can be taken from above the fox's head. The left
// edge is clamped so it cannot wrap when the fox is against the left wall.
//
// hit_player_b is NOT widened: it is shared with the obstacle test below, and
// Lure is a collecting skill, not a "trip on more things" skill.
// ---------------------------------------------------------------------------
wire [10:0] lure_l_raw = (skill_lure && player_x > `LURE_PAD) ? (player_x - `LURE_PAD)
						 : (skill_lure ? 11'd0 : {1'b0, player_x});
wire [10:0] lure_r_raw = skill_lure ? (player_x + `PLAYER_W + `LURE_PAD)
									: (player_x + `PLAYER_W);
wire [10:0] lure_t_raw = skill_lure ? {1'b0, player_y}
									: (player_y + `PLAYER_PAD_T);

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
		hit_player_t <= lure_t_raw;
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

// Everything that can move the score this frame.
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
			// Clamped at 99: the display is two digits (bin2bcd7), and the
			// converter only sees timer[6:0], so an unclamped clock would
			// read 100 as "00" and then count down from a wrapped value.
			// Four sunstones from a 90 second start is enough to hit it.
			TYPE_TIME: next_timer = (timer >= 8'd99 - TIME_BONUS) ? 8'd99
																  : timer + TIME_BONUS;
			TYPE_CHARGE:
				if (skill_charge < SKILL_CHARGE_MAX)
					next_charge = skill_charge + 1;
			default: begin
				next_timer = timer;
				next_charge = skill_charge;
			end
		endcase

		// Frost is only a hazard if nothing is protecting the fox. EMBER burns
		// it for a token +1; GOLD transmutes it into real heat.
		if (hit_is_hazard && skill_gold)
			score_delta_eff = GOLD_SHARD;
		else if (hit_is_hazard && skill_ember)
			score_delta_eff = OBS_BURN_BONUS;
		else
			score_delta_eff = score_delta;

		// The multiplier applies to gains only, so a shard never gets worse.
		if (score_delta > 0)
			score_delta_eff = score_delta_eff * score_mult;
	end

	// Ridges are deliberately absent here. They move HP, not heat - see
	// ridge_hurt / ridge_heal below. Keeping them out of this block also keeps
	// two adders and a 3-way penalty mux off the score path, which is the
	// slowest path in the design.

	score_sum = $signed({2'b00, score}) + score_delta_eff;
	if (score_sum < 0)
		next_score = 0;
	else if (score_sum > 999)
		next_score = 10'd999;
	else
		next_score = score_sum[9:0];
end

// ===========================================================================
// Health
//
// Ground ridges are the only thing that moves HP, and the fox has exactly
// hp_start of them to spare. EMBER makes it immune: while the skill runs a
// loss ridge still shatters, it simply costs nothing.
//
// hp_empty has to look at hp == 1 rather than hp == 0, because `hp` is updated
// with a non-blocking assignment - the decrement that empties the bar has not
// landed yet on the frame the run needs to end.
// ===========================================================================
// EVERY ridge costs a point of health. There is no such thing as a friendly
// one: nothing on the floor gives HP back, so the bar only ever falls and the
// only way to keep it is to jump. The `obs_gain` flag that used to make some
// ridges heal is gone entirely, along with the sprite variants that advertised
// them - see the obs_btn note at the spawn site.
wire ridge_hurt = obs_hit_valid && !skill_ember;
wire hp_empty   = ridge_hurt && (hp <= 3'd1);

// Anything that hurt this frame, for the UI flash: a ridge taking health, or
// frost taking heat.
wire took_damage = ridge_hurt ||
				   (hit_valid && hit_is_hazard && !skill_ember && !skill_gold);

// Compare in BINARY, not BCD. Going through the converter first would drag a
// whole double-dabble chain into the collision path (see below).
//
// It compares two REGISTERS. The earlier version compared `next_score` - this
// instant's collision result - which put the entire chain
//
//     obj_ypos -> collision -> which object -> what it is worth
//              -> clamp -> compare -> high_score
//
// into one clock and made it the worst path in the whole design. Latching the
// best score during S_OVER instead is a plain register-to-register compare;
// `score` is frozen the moment the run ends, so writing it on every results
// frame is idempotent and needs no edge detect.
wire new_high_score = score > high_score;

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

// bin2bcd7 produces TWO digits. The hundreds nibble has to be driven
// explicitly: leaving it open made GowinSynthesis report
// "output port timer_bcd[11:8] has no driver, assigning undriven bits to Z",
// and ui_layer reads exactly those bits - both as the timer's leading digit
// and as the "under ten seconds" test. The clock is clamped to 99 below, so
// the hundreds digit is always zero.
bin2bcd7 #(
	.BIN_BITS(7)
) u_timer_bcd (
	.bin(timer[6:0]),
	.bcd(timer_bcd[7:0])
);

assign timer_bcd[11:8] = 4'd0;

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
	obs_btn_bus = 0;

	for (pack_i = 0; pack_i < MAX_OBJ; pack_i = pack_i + 1) begin
		obj_lane_bus[pack_i*LANE_BITS     +: LANE_BITS]     = obj_lane[pack_i];
		obj_xoff_bus[pack_i*XOFF_BITS     +: XOFF_BITS]     = obj_xoff[pack_i];
		obj_ypos_bus[pack_i*OBJ_Y_BITS    +: OBJ_Y_BITS]    = obj_ypos[pack_i];
		obj_type_bus[pack_i*OBJ_TYPE_BITS +: OBJ_TYPE_BITS] = obj_type[pack_i];
	end

	for (pack_i = 0; pack_i < MAX_OBS; pack_i = pack_i + 1) begin
		obs_xpos_bus[pack_i*OBS_X_BITS +: OBS_X_BITS] = obs_xpos[pack_i];
		obs_btn_bus[pack_i*3           +: 3]          = obs_btn[pack_i];
	end
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
		// Reset lands on the full-screen how-to page. It only appears once:
		// play-again from the results screen restarts from the menu.
		state <= S_HOWTO;
		diff_sel <= DIFF_NORMAL;
		skill_sel <= SKILL_EMBER;
		frame_cnt <= 0;
		anim_cnt <= 0;
		spawn_cnt <= SPAWN_PERIOD_FRAMES;
		obs_cnt <= 8'd180;
		count_val <= 3;
		count_frames <= 0;
		warmup_cnt <= 0;
		btn_jump_q <= 0;
		btn_move_q <= 0;
		over_cnt <= 0;
		over_phase <= 0;
		over_sel <= 0;
		// These used to be initialised only when a run started. On the board
		// that happened to work because the fabric powers registers up at 0,
		// but a combo_mult of 0 would have multiplied every catch by zero.
		combo_cnt <= 0;
		combo_mult <= 3'd1;
		hurt_cnt <= 0;
		hp <= HP_MAX[2:0];

		for (i = 0; i < MAX_OBJ; i = i + 1) begin
			obj_lane[i] <= 0;
			obj_xoff[i] <= 0;
			obj_ypos[i] <= 0;
			obj_type[i] <= 0;
		end
		for (i = 0; i < MAX_OBS; i = i + 1) begin
			obs_xpos[i] <= 0;
			obs_btn[i] <= 0;
		end
	end else begin
		// Sample the buttons once per FRAME, not once per clock. The game only
		// advances on frame_tick, so a one-clock-wide rising edge would almost
		// always land between two frames and be lost - about 9 out of 10
		// presses. This is done for every state so the menu gets edges too.
		if (frame_tick) begin
			btn_jump_q <= btn_jump;
			btn_move_q <= menu_left || menu_right;
		end

		if (frame_tick && in_menu) begin
			// ---------------------------------------------------------------
			// Start sequence: full-screen how-to page, then the menus.
			// LEFT / RIGHT pick, JUMP confirms.
			//
			// Power-on shows the how-to page first (JUMP = "got it", then
			// page 1 difficulty, page 2 skill, then the countdown). Play-again
			// from the results screen goes straight to the countdown, so the
			// instructions never repeat.
			// One step per press (menu_move_rise), so holding the button does
			// not race through the options.
			// ---------------------------------------------------------------
			if (menu_move_rise) begin
				if (state == S_MENU_DIFF)
					diff_sel <= menu_left ? (diff_sel == 2'd0 ? 2'd2 : diff_sel - 1'b1)
										  : (diff_sel == 2'd2 ? 2'd0 : diff_sel + 1'b1);
				else if (state == S_MENU_SKILL)
					skill_sel <= menu_left ? (skill_sel == 2'd0 ? 2'd2 : skill_sel - 1'b1)
										   : (skill_sel == 2'd2 ? 2'd0 : skill_sel + 1'b1);
			end else if (btn_jump_rise) begin
				if (state == S_HOWTO) begin
					// ---- how-to page -> the start menu ----
					state <= S_MENU_DIFF;
				end else if (state == S_MENU_DIFF) begin
					state <= S_MENU_SKILL;
				end else begin
					// ---- skill menu -> start the countdown ----
					count_val <= 3;
					count_frames <= 0;
					state <= S_COUNT;
				end
			end
		end else begin
			if (game_step) begin

				anim_cnt <= anim_cnt + 1'b1;

				if (warmup)
					warmup_cnt <= warmup_cnt + 1'b1;

				// ---- move sideways ----
				// Holding both cancels out, which is what frees LEFT+RIGHT to
				// mean "use the skill".
				if (btn_left && !btn_right) begin
					if (can_left)
						player_x <= player_x - {5'd0, move_speed};
					else
						player_x <= 0;
					player_dir <= 0;
				end else if (btn_right && !btn_left) begin
					if (can_right)
						player_x <= player_x + {5'd0, move_speed};
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

				// ---- combo update: increment on catch, reset on miss/trip ----
				//
				// The break condition deliberately ignores frost. Letting a
				// shard fall past is the RIGHT play, and the old version reset
				// the streak for it, so a careful player was punished for
				// dodging and the multiplier could almost never be held.
				if (hit_valid) begin
					if (score_delta > 0) begin
						if (combo_cnt < 4'd15)
							combo_cnt <= combo_cnt + 1'b1;
						if (combo_cnt >= 4'd10 && combo_mult < 3'd3)
							combo_mult <= combo_mult + 1'b1;
						else if (combo_cnt >= 4'd5 && combo_mult < 3'd2)
							combo_mult <= combo_mult + 1'b1;
					end else if (hit_is_hazard && !skill_ember && !skill_gold) begin
						// Walked into frost with nothing protecting you.
						combo_cnt <= 0;
						combo_mult <= 3'd1;
					end
				end

				// Tripping on a loss ridge also breaks the streak.
				if (took_damage) begin
					combo_cnt <= 0;
					combo_mult <= 3'd1;
					hurt_cnt <= 4'd8;
				end else if (hurt_cnt != 0) begin
					hurt_cnt <= hurt_cnt - 1'b1;
				end

				// ---- health ----
				// Ridges are the only thing that touches HP, and they only
				// ever take it. Clamped at 0 so the bar cannot wrap round to
				// full on the frame the run ends.
				if (ridge_hurt && hp != 0)
					hp <= hp - 1'b1;

				// Dropping a real ember breaks it too. Only types 0..2 count -
				// a missed sunstone or crystal is a shame, not a mistake.
				for (i = 0; i < MAX_OBJ; i = i + 1) begin
					if (obj_valid[i] && obj_ypos[i] >= OBJ_GROUND_Y &&
						obj_type[i] <= TYPE_COIN_5) begin
						combo_cnt <= 0;
						combo_mult <= 3'd1;
					end
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
					//
					// Tier 0 (the first 24 s) still holds the tall ridges back
					// on EASY and NORMAL, so the player meets the hoppable kind
					// first. HARD skips that grace period.
					obs_tall[obs_free_idx] <= allow_tall && (speed_level != 0) && spawn_data[10];
					// Every ridge hurts, so every ridge has to LOOK like it
					// hurts. Only the hazard sprites are used now - the blue
					// button (2) and the two reds (3/4). Showing the fox or orb
					// button on something that costs a life would be teaching
					// the player the wrong thing.
					obs_btn[obs_free_idx] <= (spawn_data[7:6] == 2'd3) ? 3'd2
											 : {1'd0, spawn_data[7:6]} + 3'd2;
				end

				// ---- spawn countdowns ----
				if (spawn_pop)
					spawn_cnt <= fall_period - 1'b1;
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
						// Start the reveal from scratch: score first, then the
						// best score, then the choice. The best score itself is
						// latched in S_OVER below, off the collision path.
						over_cnt <= 0;
						over_phase <= 0;
						over_sel <= 0;
					end
				end else begin
					frame_cnt <= frame_cnt + 1'b1;
				end

				// ---- out of health ----
				// Placed after the clock so that if the last ridge and the last
				// second land together, this wins and the run ends the same way
				// either way. The results screen is reached identically, so
				// nothing downstream has to know which one finished the run.
				if (hp_empty) begin
					state <= S_OVER;
					over_cnt <= 0;
					over_phase <= 0;
					over_sel <= 0;
				end
			end else if (state == S_COUNT) begin
				// ---- pre-game countdown: 3,2,1 then play; JUMP skips ----
				if (frame_tick) begin
					if (btn_jump_rise || (count_frames == FPS - 1 && count_val <= 1)) begin
						// ---- start the run (also reached by holding JUMP) ----
						count_val <= 0;
						count_frames <= 0;
						player_x <= PLAYER_START_X;
						player_dir <= 1;
						player_y_fx <= GROUND_FX;
						player_vy <= 0;
						air_jumps <= AIR_JUMPS_MAX;
						obj_valid <= 0;
						obs_valid <= 0;
						obs_tall <= 0;
						obs_gain <= 0;
						for (i = 0; i < MAX_OBS; i = i + 1)
							obs_btn[i] <= 0;
						timer <= TIMER_START;
						score <= 0;
						skill_charge <= 0;
						combo_cnt <= 0;
						combo_mult <= 3'd1;
						hurt_cnt <= 0;
						hp <= hp_start;
						state <= S_PLAY;
						frame_cnt <= 0;
						anim_cnt <= 0;
						spawn_cnt <= SPAWN_PERIOD_FRAMES;
						obs_cnt <= 8'd180;
						warmup_cnt <= 0;
					end else if (count_frames == FPS - 1) begin
						count_frames <= 0;
						count_val <= count_val - 1'b1;
					end else begin
						count_frames <= count_frames + 1'b1;
					end
				end
			end else if (state == S_OVER) begin
				// -----------------------------------------------------------
				// Results screen, revealed in phases: score shows first, the
				// best score pops in when over_cnt[6] goes high (frame 64),
				// and the PLAY AGAIN / LEAVE choice appears when over_cnt[5]
				// goes high too (frame 96). The choice stays up for as long
				// as the player sits on the screen.
				//
				// The best score is latched here, from the frozen `score`
				// register, rather than from the live collision result on the
				// last frame of the run - see new_high_score above.
				// -----------------------------------------------------------
				if (frame_tick) begin
					if (new_high_score)
						high_score <= score;

					if (over_phase == 2 && btn_jump_rise) begin
						// ---- confirm the choice ----
						// PLAY AGAIN goes into the countdown (which clears the
						// player, objects, score, timer and charge when the
						// run starts); LEAVE goes back to the difficulty menu,
						// keeping the high score. The frozen run stays dimmed
						// behind either screen, exactly as before.
						if (over_sel == 0) begin
							count_val <= 3;
							count_frames <= 0;
							state <= S_COUNT;
						end else begin
							state <= S_MENU_DIFF;
						end
					end else if (over_phase == 2 && menu_move_rise) begin
						// ---- flip the choice ----
						over_sel <= ~over_sel;
					end else begin
						// ---- reveal timing. Bit-triggered so it is a couple
						// of ANDs, not 7-bit compares: the best score pops in
						// when over_cnt[6] goes high (frame 64), the choice
						// when over_cnt[5] goes high as well (frame 96). The
						// phase reg only ever advances, so the counter
						// wrapping at 127 is harmless.
						over_cnt <= over_cnt + 1'b1;
						if (over_phase == 0 && over_cnt[6] && !over_cnt[5])
							over_phase <= 2'd1;
						else if (over_phase == 1 && over_cnt[6] && over_cnt[5])
							over_phase <= 2'd2;
					end
				end
			end
		end

		if (SKILL_ENABLE && skill_start)
			skill_charge <= 0;
	end
end

// ---------------------------------------------------------------------------
// There is no sound. `buzz` (pin 19) is tied low in game_core.
//
// A frame-aligned sound event bus and a square-wave engine used to live here
// and in src/common/sound_engine.v, but the engine was never instantiated:
// the bus drove two dangling wires in game_core and every note it computed
// was discarded by the synthesiser. Both are gone rather than left looking
// functional. Bringing sound back needs ~60 free LUTs and the design places
// at 100% CLS today, so it is real work, not a re-connect.
// ---------------------------------------------------------------------------


endmodule
