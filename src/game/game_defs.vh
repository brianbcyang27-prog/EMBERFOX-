// ---------------------------------------------------------------------------
// EMBERFOX - shared geometry
//
// Everything the collision code and the render code both need to agree on
// lives here, so the two can never drift apart.
//
// Screen is 640x480:
//     y   0.. 15   top UI bar
//     y  16..415   play field (background image band)
//     y 416..479   bottom UI bar
//
// There are TWO kinds of things in the play field:
//
//   embers / shards   fall straight DOWN from the top   (catch them)
//   ground obstacles  slide in from the RIGHT along the floor  (jump them)
// ---------------------------------------------------------------------------

`define GAME_X0       10'd64    // left edge of the falling-object field
`define UI_TOP        10'd416   // first row of the bottom UI bar = the floor
`define PLAY_TOP      10'd16    // first row of the play field

// ---- the fox -------------------------------------------------------------
`define PLAYER_W      10'd64
`define PLAYER_H      10'd64
`define GROUND_Y      10'd352   // top edge of the fox when standing (feet on the floor)

// The drawn sprite is 64x64 but the art has empty margins, so the hitbox is
// pulled in. Without this the fox "hits" things it never touched.
`define PLAYER_PAD_T  10'd16    // ignore the top of the sprite when catching
`define PLAYER_PAD_X  10'd12    // ignore the sides when tripping on obstacles

// ---- falling objects (unchanged from the coin game) ----------------------
`define OBJ_W         10'd32
`define OBJ_H         10'd32

// ---- ground obstacles ----------------------------------------------------
// Two sizes, both drawn from a 16x16 atlas sprite - the tall one just
// stretches it 4x vertically instead of 2x, so a second obstacle shape costs
// no extra ROM. Obstacles come in two flavours: gain (+1, green-ish "+1" art)
// and loss (-3, "-3" art). They reuse falling-object atlas slots.
//
//   short   y 384..416   32 px tall, a hop clears it
//   tall    y 352..416   64 px tall, needs a real jump
`define OBS_W         10'd32
`define OBS_Y         10'd384   // 384 + 32 = 416, so it sits exactly on the floor
`define OBS_TALL_Y    10'd352   // 352 + 64 = 416, same floor line
`define OBS_GAIN_TYPE 3'd0      // atlas slot: the "+1" sprite, pays points
`define OBS_LOSS_TYPE 3'd3      // atlas slot: the "-3" sprite, costs points

// ---- Lure skill ----------------------------------------------------------
// How far past the sprite the catch box reaches while Lure is running.
`define LURE_PAD      10'd28

// Obstacles slide off the LEFT of the screen, so they are stored with
// OBS_X_BIAS already added. That way the position stays positive the whole
// time and the unsigned counter can never wrap around to a huge number:
//
//     screen_x = obs_xpos - OBS_X_BIAS
//
//     obs_xpos =  32  ->  screen_x = -32  (fully off the left, delete it)
//     obs_xpos =  64  ->  screen_x =   0  (touching the left edge)
//     obs_xpos = 704  ->  screen_x = 640  (just past the right edge, spawn here)
`define OBS_X_BIAS    11'd64
`define OBS_SPAWN_X   11'd704
`define OBS_KILL_X    11'd32
