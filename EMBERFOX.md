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
> Ninety seconds. Then the dark.

| In the game | In the story |
|---|---|
| Your score, **HEAT** | How much of the sun you are carrying |
| Your **HP bar** | How much of the cold the fox can still walk through |
| Embers `+1 / +3 / +5` falling | Pieces of the fallen sun |
| Frost shards `-3 / -5` falling | Cold that fell with them |
| **Short floor ridges** | Frost pushed up out of the plain, driven west by the wind |
| **Tall floor ridges** | Older frost. It has had all night to grow. |
| Sunstone `+time` | A piece big enough to hold the dusk open longer |
| Ember crystal `charge` | Fuel — five and the fox can spend it |
| The timer hitting zero | The dark |
| The HP bar hitting zero | The cold got there first |

**Two things fall, two things matter.** What comes out of the sky moves your
**heat**; what comes along the ground moves your **health**. Catching is how you
score, jumping is how you survive, and the two bars never trade against each
other — which is what makes it obvious, mid-run, which mistake you just made.

---

## 2. What changed from the coin game

The scoring system is **untouched** — same seven object types, same values, same
90 second clock, same high score. Objects still fall straight down and the
background is still a still image. What is new is **the floor**, **a start
menu**, **three skills to choose between**, and a gentler, longer default run.

| | Coin catcher | Emberfox |
|---|---|---|
| Falling objects | fall down, catch them | same, but the **mix and speed follow the difficulty** |
| Background | still image | **same, unchanged** |
| Player | moves left / right | left / right **and jumps** |
| The floor | flat and empty | **spawns ridges** in two heights |
| Losing | the clock running out | the clock **or the HP bar** running out |
| Bottom-right of the UI | best score | **HP bar** (best score moved to the results panel) |
| On reset | straight into a run | **full-screen how-to page**, then menu: difficulty, skill, countdown (shown once) |
| Difficulty | fixed | **EASY / NORMAL / HARD**, and it changes eight things |
| Skill | wired but did nothing | **EMBER / GOLD / LURE** |

---

## 3. Controls — three buttons

| Button | Pin | In a run | In the menu |
|---|---|---|---|
| `btn_left` | 13 | Move left | Previous option |
| `btn_right` = **JUMP** | 17 | **Jump** (tap = hop, hold = full jump, again in mid-air = a third jump) | **Confirm** |
| `btn_start` **or** `btn_skill` | 15 or 18 | Move right | Next option |
| `btn_left` + `btn_right` together | — | **Use your skill** (needs 5 charges) | — |

**Three buttons, seven actions.** The extras are folded in rather than given
buttons of their own:

- **Skill = LEFT + RIGHT together.** Holding both already cancels out as
  movement in the original coin-game mover, so the combination was free.
- **Menu = one step per press.** Holding a direction does not scroll through
  the options; you have to release and press again.
- **Results screen → JUMP** returns to the start menu, so you can change
  difficulty and skill between runs. The high score survives.

**Which pin is jump?** Pin 17 — that is `btn_right`, rewired to jump so a tap
is always a hop. The two spare pins are ORed together (`btn_move_right =
btn_start || btn_skill`) and move the fox right, so the third physical button
works as "move right" no matter which spare it is actually wired to. Every
button pin has `PULL_MODE=UP` and `debounce` treats it as active-low, so a pin
with no button reads as "not pressed" forever.

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
y 416..479   bottom UI bar (timer, heat, HP bar, charge)
```

The fox is 64×64. Standing, its top edge is at **y = 352**, feet on the floor.

### 4.2 Two kinds of thing, two kinds of motion

```text
embers / shards    spawn at the TOP     fall DOWN at 2 px/frame     catch them
floor ridges       spawn at the RIGHT   slide LEFT at 1-3 px/frame  jump them
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
S_HOWTO (4) --jump--> S_MENU_DIFF (0) --jump--> S_MENU_SKILL (3) --jump--> S_COUNT (5) --5s--> S_PLAY (1)
        ^                                                                                               |
        |                                            (timer runs out)                                   |
        +--------------------------------------- S_OVER (2) <-------------------------------------------+
                                                     |
                                                     +---- jump (play again) ----> S_MENU_DIFF
```

Power-on lands on the **full-screen how-to page**; it appears exactly once.
Play-again from the results screen jumps straight back to the difficulty menu
(no instructions again).

The menu costs almost no hardware because it **reuses the results panel**. The
big title line already existed for `TIME UP`; it now renders whichever word is
selected, chosen by a `title_id` from `game_ctrl`. Under it are three small
boxes with the chosen one lit — three fixed rectangles and a compare. Below
those sit two centred hint rows, **MOVE LEFT OR RIGHT** / **JUMP TO CONFIRM**,
so a first-time player knows which button does what.

Two of the states are new screens:

- **`S_HOWTO`** is a **full-screen page** (black, not a panel box) with the
  title **HOW TO PLAY** and four centred lines — **CATCH EMBERS FOR HEAT**,
  **JUMP OVER THE RIDGES**, **LEFT AND RIGHT SKILL**, **PRESS JUMP TO START**.
  JUMP moves on to the difficulty menu. Rendering it full screen is nearly
  free: it is the same text renderer with a mode gate that skips the panel box.
- **`S_COUNT`** shows **GET READY** and a big 3 → 1 digit, one per second, then
  drops straight into the run. The countdown shares the body/digit renderer, so
  it costs a state and a counter, not a new layer.

Every base X in `res_overlay` is the *computed* centred position for its own
word (`x = 322 - 14n` at scale 4, `x = 321 - 7n` at scale 2) rather than an
eyeballed constant, so no line sits off-centre and no two rows overlap.

### 4.8 The three skills

`skill_slot.v` is untouched — it still owns the button edge, the charge check
and the countdown. Only the **effects** are new, and each is a mux on something
that already existed.

The previous set was three flavours of *"things move at a different speed"* —
one slowed the world, one weakened gravity, one silently widened an invisible
box. Firing a skill therefore did almost nothing you could see, and it never
touched the score. Two of the three are now real buffs, one on the fox and one
on what falls out of the sky:

| Skill | Kind of buff | What it does | Cost |
|---|---|---|---|
| **EMBER** | on the **character** | **Faster and invulnerable** for 8 s. Ridges cannot take HP — they still shatter, they just cost nothing — and falling shards pay +1 instead of costing heat. The fox also moves at 12 px/frame instead of 8, and gravity drops to 5 so it jumps higher. | three muxes |
| **GOLD** | on the **falling score** | Every ember pays **three times** face value — a +5 is worth 15 — and frost shards stop being a hazard, paying +3 instead. The multiplier digit already in the UI switches to `3`, so the payout is visible rather than just felt. | one mux |
| **LURE** | on the **character's reach** | The catch box grows `LURE_PAD` (40 px) to the left and right *and* loses its 16 px of top padding, so embers are taken from well outside the sprite and from above the fox's head. | two muxes |

GOLD deliberately **replaces** the combo multiplier rather than stacking with
it. Stacked, a +5 caught on a 3× streak would pay 45 and a single skill use
would out-score the rest of the run.

All three draw the same burning-fox sprite, so the skill countdown digits are
tinted per skill (orange / gold / green) — otherwise there is nothing on screen
that says which one is running.

### 4.9 Difficulty

Difficulty used to set the ridge speed and spacing and nothing else. Since
nearly all the score comes from the *falling* half, EASY and HARD played almost
identically and the menu was close to decorative. It now drives eight things:

| | EASY | NORMAL | HARD |
|---|---|---|---|
| Ridge speed | 2 (flat, no ramp) | 2 → 3 | 3 → 4 |
| Frames between ridges | 240 | 180 → 140 | 150 → 105 |
| Tall ridges | no | no | **yes** |
| Falling speed | 2 | 2 | 3 |
| Frames between falling objects | 30 | 24 | 20 |
| **Starting HP** | 5 | 4 | 3 |
| Teaching window | 8 s | 5 s | 3 s |
| Hazard mix *(`spawn_postprocess`)* | 3 hazards in 4 become +1 embers, survivors capped at −3 → **~9 %** | −5 capped to −3 → **35 %, all mild** | untouched → **35 %, full −3 / −5** |

The gap has to **shrink** as speed grows. If it did not, faster ridges would end
up spaced further apart on screen and the game would get *easier* as it sped up.

**Every run opens with a teaching window.** While it is open the spawn
post-processor remaps frost shards to plain +1 embers. And on EASY and NORMAL
the whole first tier (24 s) sends only gain ridges, so the start teaches before
it punishes.

#### Why EASY does not use the slowest ridges

This is the least obvious number in the game and it was backwards before.

A ridge does not move vertically, so clearing one is a race between two
durations: how long the ridge **sweeps** across the fox, and how long a jump
**hangs** above it.

```text
sweep = (OBS_W + trip width) / speed = (32 + 24) / speed
hang  = 44 frames above a short ridge, 37 above a tall one
```

```text
speed 1  ->  sweep 56 frames   IMPOSSIBLE - the ridge is still underneath
                               the fox when the jump has already ended
speed 2  ->  sweep 28 frames   clears comfortably
speed 3  ->  sweep 19 frames   clears easily
```

**A slower ridge is a harder ridge.** EASY used to run at 1 px/frame, which
made its ridges the only genuinely unjumpable ones in the game. EASY now keeps
the speed at a jumpable 2 and buys its easiness with a four-second gap, no tall
ridges, a gentler hazard mix and a 1-heat penalty.

Two constants exist to make that arithmetic work at all: `GRAVITY` dropped from
9 to 7 (a jump is airborne 50 frames instead of 39) and `PLAYER_PAD_X` grew
from 12 to 20 (the trip box is 24 px wide, not 40).

### 4.10 Bugs found and fixed in the playability pass

**The boss ridge, which is now gone.** It was fixed first and cut later, when
the design turned out not to fit (see §7). Four separate faults, kept here
because they are the reason it was the cheapest feature to give up:

- *It ate your score.* The gap counter was cleared to 0 at the start of a run,
  so the spawn condition (`counter == 0 and no boss present`) fired on the
  **first frame of every game** — a 64 px wall in the fox's face during the
  teaching window. Worse, touching it did not remove it, unlike every other
  ridge, so `boss_hit_valid` stayed true for the whole overlap and re-applied
  the penalty **once per frame**. Simulating the old code counts **206 penalty
  frames in the first 15 seconds**; the score sat at 8 and never recovered.
- *Its bonus wrapped the score.* It was added straight to `score` in the
  clocked block, in a second non-blocking assignment that raced the ordinary
  `score <= next_score` — so a catch on the same frame was silently lost. It
  also skipped the 0..999 clamp, and `score` is 10 bits, so 999 + 50 wrapped
  round to **25**.
- *Its bonus was free.* "Did the player clear the boss?" was tested as *feet
  above the boss top while rising*, with no check that the fox was anywhere
  near it — so any jump taken while a boss was on screen paid out.
- *It could not be jumped.* At 96 px tall a full jump held the feet above it
  for ~28 frames while it took ~29 frames to sweep past. Off by one frame, so
  strictly impossible.

**The combo that punished good play.** The streak reset whenever *any* object
reached the floor, including frost shards. Dodging a shard is the correct play,
so the multiplier broke precisely when the player did the right thing and could
almost never be held. Only dropping a real ember (types 0–2) breaks it now.

**The screen shake that never shook.** `shake_x` was declared `output shake_x`
— one bit — while being assigned a 10-bit signed offset. Every value it could
produce (±4, ±2, 0) has bit 0 clear, so the port was permanently 0 and the
14-bit adder it fed was folded away. Rather than pay for a real one on a part
with no CLS left, tripping now flashes the score digits red, which is visible
where a 4-pixel camera nudge on a 640×480 screen was not.

**The best score that hid itself.** `res_overlay` gated the BEST row on
`over_phase[0]`. The reveal runs 0 → 1 → 2, and 2 is binary `10`, so the best
score popped in at phase 1 and vanished again the moment the PLAY AGAIN /
LEAVE row appeared.

**The menu that said everything twice.** The menu drew its two hint lines, then
drew the *same two strings* again 40 px lower as a separate "hint" block, so
every menu page showed each instruction twice. The how-to page meanwhile drew
only two lines, at X positions computed for different, longer strings, so both
sat off-centre.

**A compile error nobody had hit.** `over_phase` was declared twice — once as
`output reg` in the port list and again as a bare `reg`. Gowin's synthesiser
tolerated it; `iverilog -g2012` rejects the file outright.

### 4.11 Three older bugs worth showing

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
| `obj_btn1_16.png` | 16×16 | 32×32 **and** 32×64 | RGB323 + alpha | floor ridge — **gain** button (fox) |
| `obj_btn2_16.png` | 16×16 | 32×32 **and** 32×64 | RGB323 + alpha | floor ridge — **gain** button (orb) |
| `obj_btn3_16.png` | 16×16 | 32×32 **and** 32×64 | RGB323 + alpha | floor ridge — **loss** button (blue) |
| `obj_btn4_16.png` | 16×16 | 32×32 **and** 32×64 | RGB323 + alpha | floor ridge — **loss** button (red) |
| `obj_btn5_16.png` | 16×16 | 32×32 **and** 32×64 | RGB323 + alpha | floor ridge — **loss** button (red) |

**Draw the fox facing right.** Facing left is done in hardware by reading each
row backwards, so a left-facing sprite is never needed.

**The ridge sprites are drawn at two sizes.** The tall ridge is the same art
stretched to 32×64 — so draw something that survives being pulled to twice its
height. A jagged vertical spike works; anything with a recognisable square shape
will look wrong when stretched. Root it at the **bottom** of the 16×16 box:
it sits directly on the floor line. `game_ctrl` picks which button sprite to
show (atlas slots 7-11): gain obstacles are the fox (0) or orb (1) button, loss
ones are the blue (2) or one of the red (3/4) buttons.

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

Digits `0-9`, a blank, and `A-Z`. The ROM holds 48 glyph slots; indices 0-36 are
used, so **11 more glyphs can be added for free** — drop a new `.txt` in
`bitmap/` and add it to the `$extra` list in `bitmap2mem.ps1`.

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
| `GRAVITY` | 7 | Higher = heavier, snappier fall. **Read §4.9 before raising it** — it sets how long a jump hangs, and ridges become unclearable if it gets much bigger |
| `GRAVITY_EMBER` | 5 | How much EMBER floats |
| `JUMP_V` | 176 | Jump launch speed → height (~138 px peak) |
| `AIR_JUMP_V` | 140 | Second jump strength |
| `AIR_JUMPS_MAX` | 2 | 1 = double jump, 3 = triple jump |
| `PLAYER_SPEED_START` | 8 | Sideways speed *(coin game value)* |
| `PLAYER_SPEED_EMBER` | 12 | Sideways speed while EMBER burns |
| `OBS_BONUS` | 1 | Heat gained for hitting a **gain** ridge |
| `OBS_BURN_BONUS` | 1 | Heat gained from frost instead, while EMBER burns |
| `GOLD_MULT` | 3 | GOLD multiplier on every catch |
| `GOLD_SHARD` | 3 | What a frost shard pays during GOLD |
| `SKILL_DURATION` | 8 | Skill length, seconds |
| `SKILL_CHARGE_MAX` | 5 | Crystals needed to fire a skill |
| `TIMER_START` | 90 | Run length, seconds — the same on every difficulty, so one BEST stays comparable |
| `LURE_PAD` *(game_defs.vh)* | 40 | How far LURE reaches sideways |
| `PLAYER_PAD_X` *(game_defs.vh)* | 20 | Trip-box inset. Also read §4.9 first |
| `OBS_Y` / `OBS_TALL_Y` *(game_defs.vh)* | 384 / 352 | Ridge heights |

**Ridge speed, ridge spacing, falling speed, falling spacing, trip penalty,
warm-up length and tall-ridge permission are no longer parameters
at all** — they live in the `case (diff_sel)` table in `game_ctrl.v`, and the
hazard mix lives in `spawn_postprocess.v`. Those two blocks are the one place
to touch if a mode still feels wrong.

`MAX_OBJ` (6) and `MAX_OBS` (3) are in `game_core.v`. Each extra one costs a
full set of comparators in **both** `game_ctrl` and `obj_layer`, so they are the
main dials for logic usage.

---

## 7. There is no logic budget left

The design fills the GW1NSR-4C, with BSRAM already at 10/10. Anything new has
to pay for itself, and at one point it stopped fitting entirely.

Most of the recent work is cost-neutral: the four extra glyph strings and the
whole per-difficulty table were funded by rewriting `res_overlay` to call
`glyph_col` four times instead of eight, and to pass it a *constant* character
count so its 24-iteration loop can fold. `glyph_col` is combinational, so every
call site is its own copy in fabric, and a runtime character count made all 24
iterations un-foldable at every one of them.

**The boss ridge had to go, and finding out why was instructive.** Four signals
— `boss_valid`, `boss_xpos`, `skill_sel`, `count_val` — were declared once in
the ANSI port list and again as bare `reg`s. That is illegal, and
GowinSynthesis said so:

```text
WARN (EX3628) : Redeclaration of ANSI port 'boss_valid' is not allowed
```

but only as a *warning*, and `iverilog` accepts it silently, so it went
unnoticed. While those signals were mis-declared the synthesiser was not
treating them as properly driven registers and logic hanging off them was being
optimised away — the design only *appeared* to fit. Correcting the declarations
added **279 LUTs** and put it 237 over capacity:

| | LUT | ALU | total |
|---|---|---|---|
| With the port bug | 3720 | 759 | 4479 / 4608 |
| Bug fixed | 3999 | 604 | 4603, **237 unplaced** |

So the feature set genuinely exceeded the part. The boss was the cheapest thing
to drop: HARD-only, twice a run, and carrying four separate bugs (§4.10).

With it gone the design placed at 4518/4608 logic and CLS 2304/2304 —
completely full, nothing left at all.

**Then the health system gave a lot of it back.** Moving the ridge penalty out
of `score_delta_eff` deleted two adders and a 3-way penalty mux from the score
arithmetic, and dropping the best-score digits from `ui_layer` deleted a whole
`big_col` field. Adding HP cost less than either:

| | logic | CLS |
|---|---|---|
| before HP | 4518/4608 (99 %) | 2304/2304 (100 %) |
| after HP | **4387/4608 (96 %)** | **2286/2304** |

(Expect ±100 cells of run-to-run variance from the placer; two builds differing
only in one text string measured 4300 and 4387. Treat these as approximate.)

### And it closed timing

The critical path was always `obj_ypos -> collision -> what it is worth ->
score`. Two changes cut it: latching the best score during `S_OVER` from the
registered `score` instead of comparing the live `next_score`, and then taking
ridges out of the score path entirely.

| | worst setup slack |
|---|---|
| baseline `26694be` | −21.066 ns |
| best-score latch moved | −11.937 ns |
| ridges moved to HP | **+0.006 ns — meets timing** |

One negative number survives, and it is not the game logic:

```text
u_clkdiv/clkdiv_inst/CLKOUT.default_gen_clk  ->
u_pll/pllvr_inst/CLKOUT.default_gen_clk      -1.823 ns
```

That is a crossing between the two clocks the tool *auto-created* because
`hdmi_coin.sdc` declares only the 27 MHz oscillator and never creates the
PLL/CLKDIV generated clocks. It is inside the HDMI serialiser, where the 1:5
domain crossing is handled by dedicated OSER10 hardware rather than fabric, and
it is present in every build ever made including the baseline. Declaring the
generated clocks in the SDC is the fix; nothing in the game needs changing.

It is also why there is no sound. `src/common/sound_engine.v` and a frame-aligned
event bus in `game_ctrl` used to exist, but the engine was never instantiated —
the bus drove two dangling wires and the synthesiser discarded everything it
computed. Both were removed rather than left looking functional. Pin 19 has the
piezo footprint and `buzz` is tied low; bringing sound back needs ~60 free LUTs
that do not currently exist.
