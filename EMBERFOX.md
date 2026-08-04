# EMBERFOX — The Long Dusk

A catch-and-jump arcade game for the Tang Nano 4K, built on the HDMI Coin hardware.

---

## 1. The story

> The sun did not set. It fell.
>
> It came apart somewhere past the eastern ridge, and it has been coming down
> ever since — not all at once, but in pieces small enough to carry. **Embers**,
> drifting out of a sky that has nothing else left in it. What a fox gathers is
> not counted in coins. It is counted in **heat**.
>
> The cold came up to meet them. Out on the flats the frost does not fall — it
> *grows*, shouldering up through the dirt in slow pale ridges, and the east
> wind drags them across the plain all night. The low ones you can hop. The tall
> ones you go over or you do not go at all.
>
> You are the last fox who still remembers what the light was for. You cannot
> put the sun back. But you can catch what falls, stay ahead of what slides, and
> every ember you hold buys the plain a few more seconds of dusk.
>
> Sixty seconds. Then the dark.

| In the game | In the story |
|---|---|
| Your score, **HEAT** | How much of the sun you are carrying |
| Embers `+1 / +3 / +5` falling | Pieces of the fallen sun |
| Frost shards `-3 / -5` falling | Cold that fell with them |
| **Short floor ridges** | Frost pushed up out of the plain, driven west by the wind |
| **Tall floor ridges** | Older frost. It has had all night to grow. |
| Sunstone `+time` | A piece big enough to hold the dusk open longer |
| Ember crystal `charge` | Fuel — five and the fox can spend it |
| The timer hitting zero | The dark |

---

## 2. What changed from the coin game

The scoring system is **untouched** — same seven object types, same values, same
60 second clock, same high score. Objects still fall straight down and the
background is still a still image. What is new is **the floor**, **a start
menu**, and **three skills to choose between**.

| | Coin catcher | Emberfox |
|---|---|---|
| Falling objects | fall down, catch them | **same, unchanged** |
| Background | still image | **same, unchanged** |
| Player | moves left / right | left / right **and jumps** |
| The floor | flat and empty | **spawns ridges** in two heights |
| On reset | straight into a run | **start menu**: pick difficulty, then skill |
| Difficulty | fixed | **EASY / NORMAL / HARD** |
| Skill | wired but did nothing | **EMBER / TIME / LURE** |

---

## 3. Controls — three buttons

| Button | Pin | In a run | In the menu |
|---|---|---|---|
| `btn_left` | 13 | Move left | Previous option |
| `btn_right` | 17 | Move right | Next option |
| `btn_start` **or** `btn_skill` | 15 or 18 | **Jump** (tap = hop, hold = full jump, again in mid-air = double jump) | **Confirm** |
| `btn_left` + `btn_right` together | — | **Use your skill** (needs 5 charges) | — |

**Three buttons, seven actions.** The extras are folded in rather than given
buttons of their own:

- **Skill = LEFT + RIGHT together.** Holding both already cancels out as
  movement in the original coin-game mover, so the combination was free.
- **Menu = one step per press.** Holding a direction does not scroll through
  the options; you have to release and press again.
- **Results screen → JUMP** returns to the start menu, so you can change
  difficulty and skill between runs. The high score survives.

**Which pin is jump?** Either spare one — `game_core` ORs them together
(`btn_jump = btn_start || btn_skill`). Every button pin has `PULL_MODE=UP` and
`debounce` treats it as active-low, so a pin with no button reads as "not
pressed" forever. The third button works wherever it happens to be wired.

**One detail that matters:** if the clock hits zero while you are *holding*
jump — mid-leap, which happens constantly — the button is already down and
would skip the results screen instantly. `restart_armed` makes you release once
first.

---

## 4. How it works

### 4.1 The screen

```text
y   0.. 15   top UI bar
y  16..415   play field (still background image)
y 416        the floor
y 416..479   bottom UI bar (timer, heat, best, charge)
```

The fox is 64×64. Standing, its top edge is at **y = 352**, feet on the floor.

### 4.2 Two kinds of thing, two kinds of motion

```text
embers / shards    spawn at the TOP     fall DOWN at 2 px/frame     catch them
floor ridges       spawn at the RIGHT   slide LEFT at 2-4 px/frame  jump them
```

The falling half is the original coin game, untouched: same `spawn_queue`, same
LFSR, same probabilities.

### 4.3 Two ridge heights from one sprite

```text
short   y 384..416   32 px tall   a hop clears it
tall    y 352..416   64 px tall   needs a real jump
```

Both are drawn from the **same 16×16 sprite** — the tall one just stretches it
4× vertically instead of 2×:

```verilog
wire [3:0] obs_src_y = obs_hit_tall ? obs_local_y_tall[5:2]    // 64 px / 16 rows
                                    : obs_local_y_short[4:1];  // 32 px / 16 rows
```

That matters because **BSRAM is completely full** — a genuinely separate second
obstacle sprite would need the atlas to double, and there is no block left for
it. A shift gets a second obstacle shape for free.

Both heights end on the floor line, so "am I high enough?" is two comparisons
shared by every obstacle rather than one per obstacle. Tall ridges only appear
on HARD.

### 4.4 Slots with a valid bit

Both kinds of thing are stored as a fixed set of slots, each with a `valid` bit.
Killing something clears its bit — nothing shuffles down to fill the gap, so
several things can disappear on the same frame with no special case. Spawning
picks the lowest free slot with a priority encoder.

### 4.5 The bias trick

Ridges have to slide off the **left** edge, but position is an unsigned counter
and unsigned counters cannot go negative. So every ridge is stored shifted right
by 64:

```text
stored 32   ->  really at x = -32   (fully off the left, delete it)
stored 64   ->  really at x =   0   (touching the left edge)
stored 704  ->  really at x = 640   (just off the right, spawn here)
```

Nothing is ever negative, and the renderer adds the same 64 to the pixel it is
testing instead of subtracting it from every ridge — one adder for the screen
instead of one per ridge.

### 4.6 Jumping — fixed-point arithmetic

An FPGA has no decimals, but "1 pixel per frame" gravity is far too heavy. The
fix is **8.4 fixed point**: store the position multiplied by 16, so the bottom
4 bits are a fraction of a pixel.

```verilog
reg [12:0] player_y_fx;       // position x 16
reg signed [11:0] player_vy;  // speed    x 16
parameter GRAVITY = 9;        // = 0.56 pixels per frame, per frame
```

**Variable jump height** is three lines and does a lot of work:

```verilog
else if (!btn_jump && vy_next < 0)
    vy_next = vy_next >>> 1;      // released while rising -> cut the climb
```

Let go early and the jump dies early — one button covers both "hop a low ridge"
and "clear a tall one".

### 4.7 The start menu

State `0` was unused in the coin game. It is now the menu:

```text
S_MENU_DIFF (0) --jump--> S_MENU_SKILL (3) --jump--> S_PLAY (1)
        ^                                                |
        +---------------- jump ---- S_OVER (2) <---------+
```

The menu costs almost no hardware because it **reuses the results panel**. The
big title line already existed for `TIME UP`; it now renders whichever word is
selected, chosen by a `title_id` from `game_ctrl`. Under it are three small
boxes with the chosen one lit — three fixed rectangles and a compare.

### 4.8 The three skills

`skill_slot.v` is untouched — it still owns the button edge, the charge check
and the countdown. Only the **effects** are new, and each is a mux on something
that already existed:

| Skill | What it does | Cost |
|---|---|---|
| **EMBER** | Frost burns: falling shards *and* floor ridges pay +1 instead of costing heat. Gravity weakens so jumps float. | two muxes |
| **TIME** | The world crawls: ridges and falling objects both move at half speed (floored at 1 so nothing parks on screen). | two shifts |
| **LURE** | The catch box reaches `LURE_PAD` further out on each side. The drawn sprite does not change — you just collect wider. | one mux |

### 4.9 Difficulty

| | Ridge speed | Frames between ridges | Tall ridges? |
|---|---|---|---|
| **EASY** | 2 (flat, no ramp) | 190 | no |
| **NORMAL** | 2 → 3 | 160 → 130 | no |
| **HARD** | 3 → 4 | 130 → 96 | yes |

The gap has to **shrink** as speed grows. If it did not, faster ridges would end
up spaced further apart on screen and the game would get *easier* as it sped up.
Falling objects are never ramped — they keep the coin game's constants.

### 4.10 Three bugs worth showing

**The disappearing jump.** Detecting a press needs the previous value:
`pressed_now && !pressed_before`. The first version stored that previous value
*every clock*, making the rising edge one clock wide — about 40 ns. But the game
only moves on `frame_tick`, once every 16 ms. The edge almost always landed
between two frames and vanished: roughly **9 out of 10 jumps were dropped.**

**The build that would not finish.** An earlier version registered `hit_idx` to
shorten the critical path. But `hit_idx` indexes `obj_type[]`, a memory array —
with a *registered* index that looks like a registered-address memory read, so
GowinSynthesis tried to infer a block RAM and hung at "Running inference".

**The 14-nanosecond BCD.** `bin2bcd` is a double-dabble: ten iterations of three
dependent 4-bit compare-and-add-3 stages, about thirty chained operations. Once
the fox could jump, `player_y` became a register feeding collision → score →
*that*, all in one clock, and setup slack collapsed to **-14.5 ns**. Feeding the
converters the `score` register instead of the in-flight value recovered 14.4 ns
with no visible change — `score` updates on the frame's first pixel and the
digits are not drawn until hundreds of clocks later.

---

## 5. Asset sizes — what to draw if you want to swap an image

Everything is converted by the `png2mem` task. **You can author at any
resolution** — the script rescales — but the *target* box below is what the
hardware actually stores, so draw with that in mind.

Transparency comes only from a **real alpha channel**. A fully transparent pixel
becomes `00`; there is no black colour-key.

### Sprites

| File in `png/` | Target | On screen | Format | Notes |
|---|---|---|---|---|
| `player_right_32.0.png` | 32×32 | 64×64 | RGB323 + alpha | walk, foot forward |
| `player_right_32.1.png` | 32×32 | 64×64 | RGB323 + alpha | walk, other foot |
| `player_right_32.2.png` | 32×32 | 64×64 | RGB323 + alpha | **rising** (needed) |
| `player_right_32.3.png` | 32×32 | 64×64 | RGB323 + alpha | **falling** (needed) |
| `player_skill_32.0.png` | 32×32 | 64×64 | RGB323 + alpha | burning fox |
| `player_skill_32.1.png` | 32×32 | 64×64 | RGB323 + alpha | burning fox, frame 2 |
| `obj_plus1_16.png` | 16×16 | 32×32 | RGB323 + alpha | small ember |
| `obj_plus3_16.png` | 16×16 | 32×32 | RGB323 + alpha | brighter ember |
| `obj_plus5_16.png` | 16×16 | 32×32 | RGB323 + alpha | big ember, the prize |
| `obj_minus3_16.png` | 16×16 | 32×32 | RGB323 + alpha | small falling shard |
| `obj_minus5_16.png` | 16×16 | 32×32 | RGB323 + alpha | big falling shard |
| `obj_time_16.png` | 16×16 | 32×32 | RGB323 + alpha | sunstone |
| `obj_charge_16.png` | 16×16 | 32×32 | RGB323 + alpha | ember crystal |
| **`obj_rock_16.png`** | 16×16 | 32×32 **and** 32×64 | RGB323 + alpha | **the floor ridge — still a placeholder** |

**Draw the fox facing right.** Facing left is done in hardware by reading each
row backwards, so a left-facing sprite is never needed.

**`obj_rock_16` is drawn at two sizes.** The tall ridge is the same art
stretched to 32×64 — so draw something that survives being pulled to twice its
height. A jagged vertical spike works; anything with a recognisable square shape
will look wrong when stretched. Root it at the **bottom** of the 16×16 box:
it sits directly on the floor line.

### Background

| File in `png/` | Target | On screen | Format |
|---|---|---|---|
| `background.png` | **80×50** | 640×400 | RGB565, opaque |

This one is **stretched to exactly 80×50 with aspect ratio ignored**, so author
it at a matching 8:5 ratio or it will distort — **640×400** or **1280×800** are
the natural choices. It is then blown up 8×, so think in big shapes and
silhouettes; anything under 8 screen pixels vanishes. It does **not** scroll, so
it does not need to tile. Keep the bottom ~32 px clear — that band is where the
ridges and the fox's feet are.

### Font

| Files | Size | Format |
|---|---|---|
| `bitmap/*.txt` | 6×12 characters | ASCII art, `#` = lit pixel |

Digits `0-9` plus `B C E I M O P R S T U A D H L N Y`. The ROM holds 32 glyph
slots and 28 are used, so **4 more letters can be added for free** — drop a new
`.txt` in `bitmap/` and add it to the `$extra` list in `bitmap2mem.ps1`.

### Rebuild assets

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\png2mem.ps1
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\.vscode\bitmap2mem.ps1
```

A missing atlas sprite now produces a warning and a transparent slot rather than
aborting the whole conversion.

---

## 6. Numbers to tune

All at the top of `game_ctrl.v` unless noted:

| Parameter | Now | Effect |
|---|---|---|
| `GRAVITY` | 9 | Higher = heavier, snappier fall |
| `GRAVITY_DASH` | 7 | How much EMBER floats |
| `JUMP_V` | 176 | Jump launch speed → height |
| `AIR_JUMP_V` | 140 | Second jump strength |
| `AIR_JUMPS_MAX` | 1 | 0 = no double jump, 2 = triple |
| `OBS_SPEED_BASE` | 3 | HARD ridge speed, px/frame |
| `OBS_PENALTY` | 3 | Heat lost for clipping a ridge |
| `OBS_BURN_BONUS` | 1 | Heat gained instead, while EMBER burns |
| `FALL_SPEED` | 2 | Falling object speed *(coin game value)* |
| `SPAWN_PERIOD_FRAMES` | 24 | Frames between falling objects *(coin game value)* |
| `PLAYER_SPEED_START` | 8 | Sideways speed *(coin game value)* |
| `SKILL_DURATION` | 8 | Skill length, seconds |
| `SKILL_CHARGE_MAX` | 5 | Crystals needed to fire a skill |
| `TIMER_START` | 60 | Run length, seconds |
| `LURE_PAD` *(game_defs.vh)* | 28 | How far LURE reaches |
| `OBS_Y` / `OBS_TALL_Y` *(game_defs.vh)* | 384 / 352 | Ridge heights |

The per-difficulty speed and spacing tables are in the `case (diff_sel)` block —
that is the one place to touch if a mode still feels wrong.

`MAX_OBJ` (6) and `MAX_OBS` (3) are in `game_core.v`. Each extra one costs a
full set of comparators in **both** `game_ctrl` and `obj_layer`, so they are the
main dials for logic usage.
