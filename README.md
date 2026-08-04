# HDMI Coin — Emberfox

Tang Nano 4K HDMI catch-and-jump arcade game implemented in Verilog.

> **Playing the game / presenting it?** Read [EMBERFOX.md](EMBERFOX.md) instead.
> It has the setting, the design reasoning, a plain-language code walkthrough,
> and the list of art assets to draw. This README is the hardware reference.

The game began as a coin catcher and keeps that whole half intact: objects still
fall straight down, the background is still a still image, and the scoring
system — the seven object types, their values, the 90 second clock, the high
score — is unchanged. What is new is **the floor**: it spawns obstacles that
slide in from the right and have to be jumped. So the player now moves
left/right *and* jumps.

Open this repository with `hdmi_coin` as the project root. The design keeps button input, game logic, render layers, and HDMI output separated so each part can be developed and explained independently.

## Pipeline

```text
top
  -> reset_sync
  -> ff_sync
  -> debounce
  -> game_core
       -> game_ctrl
       -> bg_layer
       -> obj_layer
       -> ui_layer
  -> svo_hdmi
       -> svo_enc
       -> svo_tmds
       -> OSER10 / ELVDS_OBUF
       -> HDMI
```

`game_core` produces one AXIS-like pixel stream. `svo_hdmi` only consumes that stream and drives the HDMI pins.

## Directory Structure

```text
hdmi_coin/
|-- README.md
|-- hdmi_coin.gprj
|-- skills/
|   |-- double_score.md
|   |-- gambler.md
|   |-- invincible_1.md
|   |-- invincible_2.md
|   |-- magnet.md
|   |-- fs/
|   |-- patches/
|   |-- run_all_patches.ps1
|   |-- speed_boost.md
|   `-- star_rain.md
|-- .vscode/
|   |-- launch.json
|   |-- tasks.json
|   |-- run.ps1
|   |-- png2mem.ps1
|   |-- bitmap2mem.ps1
|   |-- zip.ps1
|   `-- monitor.ps1
|-- png/
|-- bitmap/
`-- src/
    |-- top.v
    |-- hdmi_coin.cst
    |-- hdmi_coin.sdc
    |-- common/
    |   |-- bin2bcd.v
    |   |-- debounce.v
    |   |-- ff_sync.v
    |   |-- fifo.v
    |   |-- lfsr32.v
    |   |-- reset_sync.v
    |   `-- rom.v
    |-- game/
    |   |-- game_defs.vh
    |   |-- game_core.v
    |   |-- game_ctrl.v
    |   |-- skill_slot.v
    |   |-- spawn_postprocess.v
    |   `-- spawn_queue.v
    |-- overlay/
    |   |-- bg_layer.v
    |   |-- obj_layer.v
    |   |-- res_overlay.v
    |   `-- ui_layer.v
    |-- hdmi/
    |   |-- svo_defines.vh
    |   |-- svo_enc.v
    |   |-- svo_hdmi.v
    |   `-- svo_tmds.v
    |-- ip/
    |   |-- gowin_clkdiv.v
    |   `-- gowin_pllvr.v
    `-- assets/
        |-- background.mem
        |-- obj_atlas.mem
        |-- player_*.mem
        |-- font.mem
        `-- res_font.mem
```

## Video Spec

- Output mode: `640x480V`
- Resolution: 640 x 480
- Frame rate: 60 Hz
- Layout: top 16 px UI bar, a 640 x 400 background image band (`Y 16..415`), bottom 64 px UI bar
- Internal stream: AXIS-like valid/ready/data/user
- Stream pixel format: 24-bit BGR888
- ROM asset formats: RGB565 `.mem` (background), RGB323 8-bit `.mem` (player, objects), 1-bit packed font `.mem` (UI/result text)

The stream interface between `game_core` and `svo_hdmi` is:

```verilog
output        out_axis_tvalid;
input         out_axis_tready;
output [23:0] out_axis_tdata;
output [0:0]  out_axis_tuser;
```

`tuser[0]` marks the first pixel of a frame.

## Controls

Board buttons are active-low at the physical pin and become active-high pressed levels inside the game.

Pin assignments below come from `src/hdmi_coin.cst`, which is what the hardware
actually uses. (An earlier version of this README listed start on 18 and skill
on 16; that was wrong.)

```text
btn_left   pin 13   move left
btn_right  pin 17   JUMP
btn_start  pin 15 ) move right -- game_core ORs them together, so
btn_skill  pin 18 ) whichever of these two the third button is wired to
```

The board has **three** buttons, so two actions are folded in rather than given
a button of their own:

```text
Ember Dash   LEFT + RIGHT together
play again   JUMP, once the run has ended
```

Holding left and right at once already cancels out in the mover
(`if (btn_left && !btn_right) ... else if (btn_right && !btn_left)`), which is
what makes that combination free. `restart_armed` forces the player to release
jump once after the run ends, so finishing mid-leap does not restart instantly.

Every button pin has `PULL_MODE=UP` and `debounce` treats the pin as active-low,
so a pin with no button on it reads as "not pressed" rather than "stuck down".
That is why ORing the two spare pins for move right works no matter which one
the third button actually sits on.

Input path:

```text
raw active-low button
  -> ff_sync
  -> debounce
  -> active-high stable level
  -> game_core / game_ctrl / ui_layer
```

`ff_sync` is a two-flop synchronizer. `debounce` is counter-based: the output changes only after the synchronized input stays different for `DEBOUNCE_CYCLES`.

## Game Spec

### States

Current game states in `game_ctrl`:

```text
0: menu -- difficulty
3: menu -- skill
4: how-to screen
5: countdown
1: playing
2: game over
```

Reset starts in the difficulty menu. JUMP moves through the menus
(difficulty → skill → how-to), then starts a 5 → 1 countdown before the run.
The state register stays inside `game_ctrl`; render layers receive `game_over`
and the `menu_mode` / `count_val` signals for the menu screens.

Restarting:

- player returns to the ground, velocity cleared
- timer resets
- score resets
- active objects are cleared
- state returns to playing
- high score is kept

The board has three buttons, so jump (pin 17) doubles as restart once the run
has ended. `restart_armed` requires the player to release jump first, otherwise
finishing a run mid-jump would restart instantly and the results panel would
never be seen. `btn_start` is still ORed into the right-mover, so a fourth
button also works if one is fitted.

### Timer and Score

- `timer` starts from `TIMER_START`.
- `FPS` defines how many `frame_tick` pulses make one second; `timer` decreases once every `FPS` frame ticks.
- When `timer` reaches 0, the game enters game over.
- `timer` and `score` are stored as binary registers and converted to packed 3-digit BCD for the UI.
- `high_score` starts from 0 and is stored as a **binary** register; `high_score_bcd` is a converter output for display only.
- `high_score` updates only when the game enters game over, comparing binary values.
- The BCD converters read the `score` / `high_score` / `timer` registers, never live collision results. Feeding `bin2bcd` the in-flight score put a whole double-dabble ripple inside the collision path and cost 14 ns of setup slack.
- `+time` objects add `TIME_BONUS`, currently 3 seconds.
- `charge` objects add 1 skill charge, up to `SKILL_CHARGE_MAX`, currently 5.
- `skill_slot` owns the common skill lifecycle: button edge detect, charge check, timer countdown, `skill_on`, and `skill_start`. It is unchanged from the coin game.
- `SKILL_ENABLE = 1` and `SKILL_DURATION = 8`: the skill is **Ember Dash**.
- `skill_start` is triggered by holding **left + right together**, since all
  three physical buttons are already spoken for.
- While `skill_on`: falling hazards and ground obstacles both pay `OBS_BURN_BONUS`
  (+1) instead of subtracting, gravity weakens from `GRAVITY` to `GRAVITY_DASH`
  so jumps float, and the fire sprite is drawn.

The floor speeds up as the clock runs down, in four 24-second tiers. The ramp
depends on the chosen difficulty: **EASY** stays at 1 px/frame with a fixed
210-frame gap, **NORMAL** rises 1 → 2 px/frame with the gap shrinking 180 → 150,
**HARD** rises 2 → 3 px/frame with the gap shrinking 150 → 114. Each tier
tightens the gap as well as the speed — without that shrink, faster obstacles
would be spaced further apart on screen and the game would get *easier* as it
sped up. The falling objects are not ramped — they keep the coin game's
constants.

Object effects:

```text
type 0: +1
type 1: +3
type 2: +5
type 3: -3
type 4: -5
type 5: +time
type 6: charge
```

Score clamps to the displayable BCD range, 0 to 999.

### Player

- Display size: 64 x 64
- Source sprite size: 32 x 32
- Scaling: 2x pixel replication
- Initial x: 288, speed 8 px/frame (unchanged from the coin game)
- y: variable, `GROUND_Y` = 352 when standing, driven by gravity and jumping
- Movement: left / right, plus jump / triple jump (two mid-air jumps)
- Facing direction uses right-facing source art; facing left mirrors the sprite address
- Vertical state is 8.4 fixed point (16 units = 1 pixel) so gravity can be
  gentler than 1 px/frame; `player_y` is just the top 9 bits
- Four-frame sheet: 0/1 = walk cycle (alternates on `player_x[6]`), 2 = rising, 3 = falling
- When `skill_on` is active, the player sprite switches to the fire skill sprite

Player assets are RGB323 (8-bit) sprite sheets, pixel value `0x00` transparent:

```text
src/assets/player_right_32.mem   4 frames, ROM depth 4096
src/assets/player_skill_32.mem   2 frames, ROM depth 2048
```

The player ROMs are read as `DATA_WIDTH(8)` and converted to BGR888 by
`rgb323_to_bgr888` inside `obj_layer`.

### Objects

Two separate kinds of thing live in the play field.

**Falling objects** (unchanged from the coin game):

- Maximum active: 6
- Display size: 32 x 32, source 16 x 16, 2x pixel replication
- Storage: RGB323 (8-bit); all types share one atlas ROM addressed by `{obj_type, src_y, src_x}`
- Motion: fall down at `FALL_SPEED` = 2 px/frame, removed on catch or on reaching the floor
- Spawn period: 24 frames

**Ground obstacles** (new):

- Maximum active: 3
- Same 32 x 32 display size, drawn from **atlas slots 7-11** (the button art:
  fox / orb / blue / red / red, matching gain vs loss)
- Fixed at `OBS_Y` = 384 so they rest on the floor line at 416; the tall
  variant stretches to 32 x 64 and only spawns on HARD
- Motion: slide right-to-left at 1-3 px/frame, ramped per difficulty (see above)
- Spawn period: 210 frames (EASY), 180 → 150 (NORMAL), 150 → 114 (HARD)
- Tripping on one costs `OBS_PENALTY` (2) and shatters it; during Ember Dash it
  pays `OBS_BURN_BONUS` (+1) instead

Because obstacles never move vertically, their top and bottom edges are
compile-time constants — so the vertical half of both the collision test and the
render test is a single comparison shared by all three, rather than one per
obstacle.

Object type probability (unchanged from the coin game):

```text
+1      20%
+3      20%
+5      10%
-3      20%
-5      15%
+time    5%
charge  10%
```

`spawn_queue` creates raw spawn data. `spawn_postprocess` now decides the height
lane from the object type — the more an ember is worth, the higher it flies, and
frost shards sit on the ground. That one `case` statement is the level design.

Per-object state:

Per-object state (falling objects, unchanged from the coin game):

```text
obj_valid
obj_lane
obj_xoff
obj_ypos
obj_type
```

```text
obj_x = 64 + obj_lane * 32 + obj_xoff
```

Per-obstacle state:

```text
obs_valid
obs_xpos    biased x (see below)
```

Both use **slots with a valid bit** rather than a compacting array: a slot is
either in use or it is not, and killing something just clears its bit. Nothing
shuffles down to fill a gap, which keeps the logic small and lets several things
disappear on the same frame with no special case. Spawning picks the lowest free
slot with a priority encoder.

Obstacles store x with `OBS_X_BIAS` (64) already added, so one can sit off the
left edge without the unsigned counter wrapping:

```text
screen_x = obs_xpos - OBS_X_BIAS

obs_xpos =  32  ->  screen_x = -32   fully off the left, delete it
obs_xpos =  64  ->  screen_x =   0   touching the left edge
obs_xpos = 704  ->  screen_x = 640   just off the right, spawn here
```

`obj_layer` adds the same bias to the pixel it is testing rather than
subtracting it from every obstacle — one adder for the screen instead of one per
obstacle. It also means no underflow guard is needed: a slot is killed at or
below 32 and the speed never exceeds 7, so anything alive stays positive.

The values are exported as packed buses:

```text
obj_valid_bus  obj_lane_bus  obj_xoff_bus  obj_ypos_bus  obj_type_bus
obs_valid_bus  obs_xpos_bus
```

Object assets:

```text
src/assets/obj_atlas.mem   (all 7 sprites, RGB323, one 256-entry slot per type)
```

## Render Layers

### `bg_layer`

Generates the base stream. Unchanged from the coin game — the background is a
still image and does not scroll:

- reads `src/assets/background.mem` (single 80 x 50 RGB565 image)
- shown 8x by pixel replication in the band `Y in [16, 416)`, `X in [0, 640)` (640 x 400)
- ROM address is `src_y * 80 + src_x`; outside the band it outputs dark gray (`0x181818`)
- the top 16 px and bottom 64 px are the UI bars (drawn by `ui_layer`)

### `obj_layer`

Receives the background stream and overlays gameplay sprites.

Draw order:

```text
background
  -> falling objects
  -> player
```

Sprite ROM reads are synchronous, so hit flags and background pixels are delayed to match ROM latency.

### `ui_layer`

Receives the object stream and overlays the top 16-pixel and bottom 64-pixel UI bars.

Layout:

```text
left    timer, 3 digits
center  score, 3 digits
right   high score, 3 digits
```

Current UI behavior:

- a 16 px dark bar at the very top (above the background image band)
- no English labels
- left/right button indicators at screen edges
- center score blinks during game over
- skill charge bar at the bottom, 5 segments
- skill countdown timer near the charge bar, 2 small digits
- digits are drawn from a 6x12 pixel font ROM (`src/assets/font.mem`) scaled by pixel replication
- timer, score, and high score receive packed BCD digits from `game_ctrl`
- UI receives `game_over`; it does not depend on the internal state encoding

### `res_overlay`

Receives the UI stream and overlays the result panel and the menu screens.

Content:

```text
TIME UP          (game over)
SCORE 123
BEST  456

(menu)   the title line shows the selected difficulty / skill word, with
         three option boxes underneath and the chosen one lit

(how-to) LEFT OR RIGHT TO MOVE, PRESS JUMP WHEN READY, etc.

(countdown)  GET READY + a big 5 -> 1 digit, one per second
```

All glyphs come from a shared 6x12 font ROM (`src/assets/res_font.mem`) holding
the digits 0-9, a blank, and `A-Z`, scaled by power-of-2 pixel replication
(title/value x4 -> 24x48, labels x2 -> 12x24, the countdown digit x8 -> 48x96).

It is a combinational overlay layer with no frame counter. Define `RES_OVERLAY_DIM`
at compile time to dim pixels outside the panel; leave it undefined for no dimming.

## Common Modules

- `reset_sync`: reset synchronizer used by `top`
- `ff_sync`: two-flop synchronizer for external asynchronous signals
- `debounce`: counter-based debounce for synchronized active-low buttons
- `bin2bcd`: parameterized double-dabble converter for score and timer BCD values
- `rom`: synchronous ROM wrapper with parameterized `DATA_WIDTH` (16 for RGB565 background/objects, 8 for RGB323 player sprites and packed font glyphs)
- `fifo`: small synchronous FIFO used by `spawn_queue`
- `lfsr32`: pseudo-random generator for object spawn logic; `spawn_queue` uses one LFSR for position and one for type
- `game_defs.vh`: shared gameplay geometry constants used by collision and rendering paths

## Skill Base

The base branch intentionally does not implement any skill. It only exposes clean hook points so each teaching branch can apply one skill patch without changing the video pipeline.

Base skill path:

```text
game_ctrl
  -> skill_slot          // common lifecycle, disabled by default
  -> spawn_queue
  -> spawn_postprocess   // pass-through shell
  -> object registers
```

`skill_slot` owns the common logic shared by every skill branch:

```text
btn_skill rising edge
charge full check
skill_timer countdown
skill_on
skill_start
charge clear trigger
```

`game_ctrl` exposes the common hack points:

```text
hit_player_l / hit_player_r / hit_player_t / hit_player_b
score_delta
score_delta_eff
player_speed
spawn_period
spawn_postprocess
```

The base branch uses these signals directly. Skill patches may override effective signals such as `score_delta_eff`, `player_speed_eff`, or `spawn_period_eff` inside the patch itself.

Skill specs are stored in `skills/`, one file per skill. Apply-ready patch files are stored in `skills/patches/`.
Each patch only enables the common slot and changes the skill-specific effect.

Patch usage:

```powershell
git apply --ignore-whitespace .\skills\patches\magnet.patch
```

Each patch is intended to be applied on a fresh branch from this base. The patches are not designed to be stacked together.

```text
skills/magnet.md
skills/double_score.md
skills/speed_boost.md
skills/invincible_1.md
skills/invincible_2.md
skills/star_rain.md
skills/gambler.md

skills/patches/magnet.patch
skills/patches/double_score.patch
skills/patches/speed_boost.patch
skills/patches/invincible_1.patch
skills/patches/invincible_2.patch
skills/patches/star_rain.patch
skills/patches/gambler.patch
```

## Asset Format

Sprite/tile assets use two color formats, both one token per pixel in row-major order:

```text
RGB565 (background)         4 hex digits per pixel
RGB323 (player, objects)    2 hex digits per pixel   transparent pixel = 00
```

Transparency comes only from PNG alpha: a fully transparent source pixel is written as
`00` (RGB323) and the render layers treat `00` as transparent. Opaque near-black art is
bumped to `01` so it stays visible. The background layer (RGB565) is opaque, no transparency.

Font assets (`font.mem`, `res_font.mem`) are 1-bit glyph bitmaps packed into 8-bit
words: each 6-pixel row is one word (MSB = leftmost column), and each glyph is padded
to 16 rows so the address is `{glyph, row}` with no multiply.

The render layers convert RGB565 and RGB323 ROM output to BGR888 for the SVO video stream.

## PNG to MEM

`.vscode/png2mem.ps1` converts all PNG files in an input folder to `.mem` files.

Default behavior:

```text
input : png/
output: src/assets
```

Conversion rules:

- Color format is RGB565 by default; the player sprites (`Sprites8bit`) and the object
  sprites (`ObjAtlas`) are written as RGB323 8-bit instead.
- Transparency comes only from PNG alpha (`A==0` -> `00`); there is no black color-key.
- Object atlas: the object sprites are packed in gameplay type order 0-6 into a single
  `obj_atlas.mem` (not one file each), so `obj_layer` reads them from one ROM.
- Auto-size: any-size source art is scaled (aspect-preserved, high-quality bicubic,
  transparent pad) to fit the target `N x N` box, from the trailing `_<N>` in the base
  name (`obj_plus1_16` -> 16, `player_right_32` -> 32) or the `FitSize` override.
- Stretch (big image): bases in `StretchSize` are resized to exactly `W x H`, aspect
  ratio NOT preserved (accepts distortion). `background` -> `80 x 50` (full-screen tile).
- Animation frames: files named `<base>.<N>.png` (e.g. `player_right_32.0.png`,
  `player_right_32.1.png`) are concatenated in index order into a single multi-frame
  `<base>.mem`.

Run from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\png2mem.ps1
```

Custom folders:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\png2mem.ps1 .\src\assets\objects .\src\assets\objects
```

The script only writes `.mem` files. It does not generate `assets.vh`, `assets.json`, or alpha map files.

## Bitmap to MEM

`.vscode/bitmap2mem.ps1` packs the 6x12 ASCII-art glyphs in `bitmap/*.txt` (a `#`
marks a lit pixel) into the 1-bit font ROMs used by the text layers:

```text
font.mem      digits 0-9 only          (used by ui_layer)
res_font.mem  digits 0-9 + space + A-Z   (used by res_overlay)
```

Run from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\bitmap2mem.ps1
```

## VS Code Tasks

Open VS Code with `hdmi_coin` as the workspace folder.

Available tasks:

```text
run         build and upload through Gowin
png2mem     convert PNG files under png/ to MEM sprite/tile files in src/assets/
bitmap2mem  pack the ASCII glyphs under bitmap/ into font.mem and res_font.mem
zip         stage the project (minus .git/.gitignore/skills) and zip it to the Desktop
monitor     launch the Windows Camera app to view the HDMI capture
```

Use:

```text
Terminal -> Run Task... -> run
Terminal -> Run Task... -> png2mem
```

`run` is the default build task.

## Build and Upload

`.vscode/run.ps1` does:

1. Open `hdmi_coin.prj` if it exists, otherwise `hdmi_coin.gprj`.
2. Run Gowin build.
3. Find the generated `.fs` bitstream under `impl/pnr`.
4. Upload the bitstream with `programmer_cli`.

Expected Gowin install path in the current script:

```text
C:\Gowin\Gowin_V1.9.11.03_Education_x64
```

If your Gowin installation path is different, update `$GOWIN_HOME` in `.vscode/run.ps1`.

## Development Notes

- Keep `svo_hdmi` free of game logic.
- Add gameplay features inside `game_ctrl`.
- Add visual changes inside `bg_layer`, `obj_layer`, or `ui_layer`.
- Keep ROM assets small because Tang Nano 4K memory and LUT resources are limited.
- Prefer source sprites with power-of-two dimensions.
- Prefer pixel replication over linear interpolation for FPGA-friendly scaling.
- Treat each render layer as an independently testable stage.

## Current Implemented State

Implemented:

- 640 x 480 HDMI output
- separated `reset_sync` from `top`
- separated `game_core` and `svo_hdmi`
- background layer: single 80 x 50 RGB565 image, shown 8x in the 640 x 400 middle band
- object layer with RGB323 object sprites in a single atlas ROM (type in the address)
- animated RGB323 player sprite (two-frame walk, mirror-for-left, skill sprite swap)
- UI layer with timer, score, high score, and button indicators, using a pixel font ROM
- game-over result panel (`res_overlay`) with a shared digit+letter font ROM
- game controller with timer, movement, spawn queue, falling objects, collision, score, and high score update
- cascaded BCD digit counters for UI timer, score, and high score outputs
- skill base hooks with common `skill_slot` lifecycle and pass-through `spawn_postprocess`
- button synchronization and debounce
- start menu (difficulty → skill → how-to screen) and a 5 → 1 pre-game countdown, reusing the results panel
- PNG to MEM conversion script (auto-size, RGB565/RGB323, animation frames)
- Bitmap to MEM font-packing script
- VS Code tasks for build/upload, asset conversion, packaging, and camera capture

Open items:

- tune spawn rate and fall speed
- tune sprite art (the floor ridge is still button art in atlas slots 7-11)
- add more gameplay feedback if needed
- watch Gowin resource usage (currently LUT 4071, Register 1300, BSRAM 10/10 on GW1NSR-4C — BSRAM has no headroom left)

---

# HDMI Coin（中文版）

以 Verilog 實作、跑在 Tang Nano 4K 上的 HDMI 接金幣遊戲。

請以 `hdmi_coin` 作為專案根目錄開啟本儲存庫。設計上刻意把按鈕輸入、遊戲邏輯、繪製圖層與 HDMI 輸出彼此分開，讓每個部分都能獨立開發與講解。

## 管線（Pipeline）

```text
top
  -> reset_sync
  -> ff_sync
  -> debounce
  -> game_core
       -> game_ctrl
       -> bg_layer
       -> obj_layer
       -> ui_layer
  -> svo_hdmi
       -> svo_enc
       -> svo_tmds
       -> OSER10 / ELVDS_OBUF
       -> HDMI
```

`game_core` 產生一條類 AXIS 的像素串流；`svo_hdmi` 只負責消化這條串流並驅動 HDMI 接腳。

## 目錄結構

```text
hdmi_coin/
|-- README.md
|-- hdmi_coin.gprj
|-- skills/
|   |-- double_score.md
|   |-- gambler.md
|   |-- invincible_1.md
|   |-- invincible_2.md
|   |-- magnet.md
|   |-- fs/
|   |-- patches/
|   |-- run_all_patches.ps1
|   |-- speed_boost.md
|   `-- star_rain.md
|-- .vscode/
|   |-- launch.json
|   |-- tasks.json
|   |-- run.ps1
|   |-- png2mem.ps1
|   |-- bitmap2mem.ps1
|   |-- zip.ps1
|   `-- monitor.ps1
|-- png/
|-- bitmap/
`-- src/
    |-- top.v
    |-- hdmi_coin.cst
    |-- hdmi_coin.sdc
    |-- common/
    |   |-- bin2bcd.v
    |   |-- debounce.v
    |   |-- ff_sync.v
    |   |-- fifo.v
    |   |-- lfsr32.v
    |   |-- reset_sync.v
    |   `-- rom.v
    |-- game/
    |   |-- game_defs.vh
    |   |-- game_core.v
    |   |-- game_ctrl.v
    |   |-- skill_slot.v
    |   |-- spawn_postprocess.v
    |   `-- spawn_queue.v
    |-- overlay/
    |   |-- bg_layer.v
    |   |-- obj_layer.v
    |   |-- res_overlay.v
    |   `-- ui_layer.v
    |-- hdmi/
    |   |-- svo_defines.vh
    |   |-- svo_enc.v
    |   |-- svo_hdmi.v
    |   `-- svo_tmds.v
    |-- ip/
    |   |-- gowin_clkdiv.v
    |   `-- gowin_pllvr.v
    `-- assets/
        |-- background.mem
        |-- obj_atlas.mem
        |-- player_*.mem
        |-- font.mem
        `-- res_font.mem
```

## 影像規格

- 輸出模式：`640x480V`
- 解析度：640 x 480
- 更新率：60 Hz
- 版面：上方 16px UI 條、640 x 400 背景圖帶（`Y 16..415`）、下方 64px UI 條
- 內部串流：類 AXIS 的 valid/ready/data/user
- 串流像素格式：24-bit BGR888
- ROM 資產格式：RGB565 `.mem`（背景）、RGB323 8-bit `.mem`（玩家、物件）、1-bit 打包字型 `.mem`（UI／結算文字）

`game_core` 與 `svo_hdmi` 之間的串流介面為：

```verilog
output        out_axis_tvalid;
input         out_axis_tready;
output [23:0] out_axis_tdata;
output [0:0]  out_axis_tuser;
```

`tuser[0]` 標記一個影格的第一個像素。

## 操作按鈕

板上按鈕在實體接腳上為低電位有效（active-low），進到遊戲內部後轉為高電位有效（active-high）的按下狀態。

```text
btn_left   pin 13   向左移動
btn_right  pin 17   跳躍（JUMP）
btn_start  pin 15 ) 向右移動 -- game_core 將兩者 OR 在一起，
btn_skill  pin 18 ) 第三顆按鈕接在哪個 spare pin 都行
```

輸入路徑：

```text
raw active-low button
  -> ff_sync
  -> debounce
  -> active-high stable level
  -> game_core / game_ctrl / ui_layer
```

`ff_sync` 是雙正反器同步器；`debounce` 採計數器方式：只有在同步後的輸入持續維持不同狀態達 `DEBOUNCE_CYCLES` 後，輸出才會改變。

## 遊戲規格

### 狀態（States）

`game_ctrl` 目前的遊戲狀態：

```text
0: 選單 -- 難度
3: 選單 -- 技能
4: 教學畫面（how-to）
5: 倒數計時
1: playing
2: game over
```

Reset 後從難度選單開始。JUMP 依序通過難度 → 技能 → 教學畫面，接著 5 → 1 倒數後才開始遊戲。
狀態暫存器保留在 `game_ctrl` 內部；繪製圖層只會收到 `game_over` 與 `menu_mode`／`count_val` 訊號。

`btn_start` 會重新開始遊戲：

- 玩家回到中央
- 計時器重置
- 分數重置
- 清除所有作用中的物件
- 狀態回到 playing

### 計時器與分數

- `timer` 從 `TIMER_START` 開始。
- `FPS` 定義幾個 `frame_tick` 脈衝算一秒；`timer` 每 `FPS` 個 frame tick 減一。
- 當 `timer` 歸零時，遊戲進入 game over。
- `timer` 與 `score` 以二進位暫存器儲存，並轉換成打包的 3 位數 BCD 供 UI 使用。
- `high_score_bcd` 從 0 開始，以打包 BCD 儲存以供顯示與比較。
- `high_score_bcd` 只在遊戲進入 game over 時更新。
- `+time` 物件增加 `TIME_BONUS`，目前為 3 秒。
- `charge` 物件增加 1 點技能充能，上限為 `SKILL_CHARGE_MAX`，目前為 5。
- 在 base 分支中，`btn_skill` 已接線但不會觸發任何遊戲效果。
- `skill_slot` 掌管共用的技能生命週期：按鈕邊緣偵測、充能檢查、計時倒數、`skill_on` 與 `skill_start`。
- 在 base 分支中 `SKILL_ENABLE = 0`，因此 `skill_slot` 不會啟動也不會消耗充能。
- 技能 patch 會啟用該 slot，並透過既有的 hook 點接上單一遊戲效果。

物件效果：

```text
type 0: +1
type 1: +3
type 2: +5
type 3: -3
type 4: -5
type 5: +time
type 6: charge
```

分數會夾限在可顯示的 BCD 範圍內，0 到 999。

### 玩家（Player）

- 顯示尺寸：64 x 64
- 來源圖素尺寸：32 x 32
- 縮放：2 倍像素複製
- 初始 x：288
- 固定 y：352
- 移動：僅左／右
- 預設速度：8 px/frame
- 技能 patch 可在本地修改移動區塊。
- 面向以右向來源圖素為準；顯示左向時鏡射圖素位址
- 兩格走路動畫：來源影格會隨玩家移動而交替（`player_x[6]`）
- 當 `skill_on` 作用時，玩家圖素切換為火焰技能圖素

玩家資產為 RGB323（8-bit）的兩格走路圖表。每個 `.mem` 連續存放兩個 32 x 32 影格（ROM 深度 2048），像素值 `0x00` 代表透明：

```text
src/assets/player_right_32.mem
src/assets/player_skill_32.mem
```

玩家 ROM 以 `DATA_WIDTH(8)` 讀取，並在 `obj_layer` 內由 `rgb323_to_bgr888` 轉換為 BGR888。

### 物件（Objects）

- 最大作用中物件數：16
- 顯示尺寸：32 x 32
- 來源圖素尺寸：16 x 16
- 縮放：2 倍像素複製
- 儲存：RGB323（8-bit）；所有 type 共用一顆 atlas ROM，以 `{obj_type, src_y, src_x}` 定址
- 預設落下速度：2 px/frame
- 預設生成週期：24 影格
- 技能 patch 可在本地修改生成計數器的重載值。

物件類型機率：

```text
+1      20%
+3      20%
+5      10%
-3      20%
-5      15%
+time    5%
charge  10%
```

`spawn_queue` 產生原始生成資料。`spawn_postprocess` 位於 `spawn_queue` 與物件暫存器之間。base 版本為直通（pass-through），技能分支可利用它在不更動原始佇列的情況下重新映射物件類型或位置。

每個物件的狀態：

```text
obj_valid
obj_lane
obj_xoff
obj_ypos
obj_type
```

座標公式：

```text
obj_x = 64 + obj_lane * 32 + obj_xoff
obj_ypos = stored object y pixel coordinate
```

多物件的值以打包匯流排輸出：

```text
obj_valid_bus
obj_lane_bus
obj_xoff_bus
obj_ypos_bus
obj_type_bus
```

物件資產：

```text
src/assets/obj_atlas.mem   (all 7 sprites, RGB323, one 256-entry slot per type)
```

## 繪製圖層（Render Layers）

### `bg_layer`

產生基底串流：

- 讀取 `src/assets/background.mem`（單張 80 x 50 RGB565 大圖）
- 以 8 倍像素複製顯示於 `Y ∈ [16, 416)`、`X ∈ [0, 640)` 的圖帶（640 x 400）
- ROM 位址為 `src_y * 80 + src_x`；圖帶外輸出深灰（`0x181818`）
- 上方 16px 與下方 64px 為 UI 條（由 `ui_layer` 繪製）

### `obj_layer`

接收背景串流，並疊上遊戲圖素。

繪製順序：

```text
background
  -> falling objects
  -> player
```

圖素 ROM 讀取為同步式，因此命中旗標與背景像素會被延遲以對齊 ROM 延遲。

### `ui_layer`

接收物件串流，並疊上上方 16 像素與下方 64 像素的 UI 條。

版面配置：

```text
left    timer, 3 digits
center  score, 3 digits
right   high score, 3 digits
```

目前 UI 行為：

- 最上方一條 16px 深灰條（在背景圖帶上方）
- 無英文標籤
- 螢幕兩側有左／右按鈕指示
- game over 時中央分數會閃爍
- 底部有技能充能條，共 5 段
- 充能條附近有技能倒數計時，2 個小數字
- 數字取自 6x12 像素字型 ROM（`src/assets/font.mem`），以像素複製縮放
- timer、score、high score 由 `game_ctrl` 提供打包 BCD 數字
- UI 收到的是 `game_over`；不依賴內部狀態編碼

### `res_overlay`

接收 UI 串流，並疊上 game over 的結算面板。

內容：

```text
TIME UP
SCORE 123
BEST  456
```

所有字形皆來自共用的 6x12 字型 ROM（`src/assets/res_font.mem`），內含數字 0-9、一個空白，以及 `A-Z`，以 2 的次方倍像素複製縮放（標題／數值 x4 -> 24x48，標籤 x2 -> 12x24，倒數數字 x8 -> 48x96）。

它是一個組合邏輯的疊加圖層，沒有影格計數器。可在編譯時定義 `RES_OVERLAY_DIM` 以使面板外的像素變暗；不定義則不變暗。

## 共用模組（Common Modules）

- `reset_sync`：`top` 使用的重置同步器
- `ff_sync`：處理外部非同步訊號的雙正反器同步器
- `debounce`：針對同步後低電位有效按鈕的計數器式防彈跳
- `bin2bcd`：可參數化的 double-dabble 轉換器，用於分數與計時器的 BCD 值
- `rom`：同步 ROM 包裝器，具可參數化的 `DATA_WIDTH`（RGB565 背景／物件為 16，RGB323 玩家圖素與打包字型字形為 8）
- `fifo`：`spawn_queue` 使用的小型同步 FIFO
- `lfsr32`：物件生成邏輯用的偽隨機產生器；`spawn_queue` 以一個 LFSR 決定位置、另一個決定類型
- `game_defs.vh`：碰撞與繪製路徑共用的遊戲幾何常數

## 技能基底（Skill Base）

base 分支刻意不實作任何技能，只暴露乾淨的 hook 點，讓每個教學分支都能套用單一技能 patch 而不動到影像管線。

基底技能路徑：

```text
game_ctrl
  -> skill_slot          // common lifecycle, disabled by default
  -> spawn_queue
  -> spawn_postprocess   // pass-through shell
  -> object registers
```

`skill_slot` 掌管每個技能分支共用的邏輯：

```text
btn_skill rising edge
charge full check
skill_timer countdown
skill_on
skill_start
charge clear trigger
```

`game_ctrl` 暴露共用的 hack 點：

```text
hit_player_l / hit_player_r / hit_player_t / hit_player_b
score_delta
score_delta_eff
player_speed
spawn_period
spawn_postprocess
```

base 分支直接使用這些訊號。技能 patch 可在 patch 內部覆寫如 `score_delta_eff`、`player_speed_eff` 或 `spawn_period_eff` 等有效訊號。

技能規格存放於 `skills/`，一個技能一個檔案。可直接套用的 patch 檔存放於 `skills/patches/`。
每個 patch 只會啟用共用 slot 並改變該技能特有的效果。

Patch 用法：

```powershell
git apply --ignore-whitespace .\skills\patches\magnet.patch
```

每個 patch 都預期套用在從此 base 開出的全新分支上，且並非設計成彼此堆疊套用。

```text
skills/magnet.md
skills/double_score.md
skills/speed_boost.md
skills/invincible_1.md
skills/invincible_2.md
skills/star_rain.md
skills/gambler.md

skills/patches/magnet.patch
skills/patches/double_score.patch
skills/patches/speed_boost.patch
skills/patches/invincible_1.patch
skills/patches/invincible_2.patch
skills/patches/star_rain.patch
skills/patches/gambler.patch
```

## 資產格式（Asset Format）

圖素／圖磚資產使用兩種色彩格式，皆以列優先（row-major）順序、每像素一個 token：

```text
RGB565 (background)         4 hex digits per pixel
RGB323 (player, objects)    2 hex digits per pixel   transparent pixel = 00
```

透明一律只來自 PNG alpha：完全透明的來源像素寫成 `00`（RGB323），繪製圖層把 `00` 當透明；不透明的近黑美術像素會被提升為 `01` 以維持可見。背景層（RGB565）不透明、無透明需求。

字型資產（`font.mem`、`res_font.mem`）是打包成 8-bit 字組的 1-bit 字形點陣：每個 6 像素列為一個字組（MSB = 最左欄），且每個字形補齊到 16 列，讓位址為 `{glyph, row}` 而無需乘法。

繪製圖層會把 RGB565 與 RGB323 的 ROM 輸出轉換為 BGR888 供 SVO 影像串流使用。

## PNG 轉 MEM

`.vscode/png2mem.ps1` 會把輸入資料夾內所有 PNG 檔轉成 `.mem` 檔。

預設行為：

```text
input : png/
output: src/assets
```

轉換規則：

- 色彩格式預設為 RGB565；玩家 sprite（`Sprites8bit`）與物件 sprite（`ObjAtlas`）則寫成 RGB323 8-bit。
- 透明一律只來自 PNG alpha（`A==0` -> `00`），沒有黑色色鍵。
- 物件 atlas：物件 sprite 依 type 順序 0-6 打包成單一 `obj_atlas.mem`（不再一個檔一個），讓 `obj_layer` 用一顆 ROM 讀取。
- 自動尺寸：任意尺寸的來源圖會被縮放（保持長寬比、高品質 bicubic、透明填邊）以符合目標 `N x N` 方框，`N` 取自基底名尾端 `_<N>`（`obj_plus1_16` -> 16、`player_right_32` -> 32）或 `FitSize` 覆寫值。
- 大圖拉伸：`StretchSize` 內的基底會被縮放到剛好 `W x H`、**不保持長寬比**（接受變形）。`background` -> `80 x 50`（全螢幕背景）。
- 動畫影格：命名為 `<base>.<N>.png` 的檔案（例如 `player_right_32.0.png`、`player_right_32.1.png`）會依索引順序串接成單一多影格的 `<base>.mem`。

從 PowerShell 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\png2mem.ps1
```

自訂資料夾：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\png2mem.ps1 .\src\assets\objects .\src\assets\objects
```

此腳本只會寫出 `.mem` 檔，不會產生 `assets.vh`、`assets.json` 或 alpha map 檔。

## Bitmap 轉 MEM

`.vscode/bitmap2mem.ps1` 會把 `bitmap/*.txt` 中的 6x12 ASCII 字形（以 `#` 標記亮起的像素）打包成文字圖層所用的 1-bit 字型 ROM：

```text
font.mem      digits 0-9 only          (used by ui_layer)
res_font.mem  digits 0-9 + space + A-Z   (used by res_overlay)
```

從 PowerShell 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\bitmap2mem.ps1
```

## VS Code 工作（Tasks）

以 `hdmi_coin` 作為工作區資料夾開啟 VS Code。

可用的工作：

```text
run         build and upload through Gowin
png2mem     convert PNG files under png/ to MEM sprite/tile files in src/assets/
bitmap2mem  pack the ASCII glyphs under bitmap/ into font.mem and res_font.mem
zip         stage the project (minus .git/.gitignore/skills) and zip it to the Desktop
monitor     launch the Windows Camera app to view the HDMI capture
```

使用方式：

```text
Terminal -> Run Task... -> run
Terminal -> Run Task... -> png2mem
```

`run` 是預設的建置工作。

## 建置與上傳

`.vscode/run.ps1` 會做：

1. 若存在 `hdmi_coin.prj` 則開啟它，否則開啟 `hdmi_coin.gprj`。
2. 執行 Gowin 建置。
3. 在 `impl/pnr` 底下找到產生的 `.fs` 位元流。
4. 以 `programmer_cli` 上傳該位元流。

目前腳本中預期的 Gowin 安裝路徑：

```text
C:\Gowin\Gowin_V1.9.11.03_Education_x64
```

若你的 Gowin 安裝路徑不同，請修改 `.vscode/run.ps1` 中的 `$GOWIN_HOME`。

## 開發須知

- 保持 `svo_hdmi` 不含遊戲邏輯。
- 在 `game_ctrl` 內新增遊戲玩法功能。
- 在 `bg_layer`、`obj_layer` 或 `ui_layer` 內新增視覺變化。
- 讓 ROM 資產保持精簡，因為 Tang Nano 4K 的記憶體與 LUT 資源有限。
- 盡量使用尺寸為 2 的次方的來源圖素。
- 為了對 FPGA 友善的縮放，偏好像素複製而非線性內插。
- 把每個繪製圖層都當成可獨立測試的階段。

## 目前實作狀態

已實作：

- 640 x 480 HDMI 輸出
- 將 `reset_sync` 從 `top` 分離
- 將 `game_core` 與 `svo_hdmi` 分離
- 背景圖層：單張 80 x 50 RGB565 大圖，於 640 x 400 中段帶以 8 倍顯示
- 使用 RGB323 物件圖素、單一 atlas ROM 的物件圖層（type 併入位址）
- 動畫化的 RGB323 玩家圖素（兩格走路、左向鏡射、技能圖素切換）
- 具計時器、分數、最高分與按鈕指示的 UI 圖層，使用像素字型 ROM
- 使用共用數字＋字母字型 ROM 的 game over 結算面板（`res_overlay`）
- 具計時器、移動、生成佇列、落下物件、碰撞、分數與最高分更新的遊戲控制器
- 供 UI 計時器、分數與最高分輸出用的串接式 BCD 位數計數器
- 具共用 `skill_slot` 生命週期與直通 `spawn_postprocess` 的技能基底 hook
- 按鈕同步與防彈跳
- PNG 轉 MEM 轉換腳本（自動尺寸、RGB565／RGB323、動畫影格）
- Bitmap 轉 MEM 字型打包腳本
- 供建置／上傳、資產轉換、打包與相機擷取用的 VS Code 工作

待辦項目：

- 調整生成速率與落下速度
- 調整圖素美術
- 決定是否加入待機／開始畫面
- 視需要增加更多遊戲回饋
- 留意 Gowin 資源用量（目前 GW1NSR-4C 上 LUT 4071、Register 1300、BSRAM 10/10，BSRAM 已無餘裕）
