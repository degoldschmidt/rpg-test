# Performance baseline

How much each active-ragdoll character costs, and how much the LOD tiers save.

## How to rerun

```
godot --headless --fixed-fps 120 --path . -s tests/benchmark.gd -- --out=docs/bench_table.md
# options: --counts=1,10,25,50,100  --scenarios=idle,walk,ragdoll,walk_kinematic,walk_proxy
```

The benchmark builds a flat floor and spawns N characters in a grid for each scenario. After 120 warm-up ticks, it measures the wall-clock time of 600 physics ticks. Physics runs at 120 Hz, so **one tick is 1/120 s of game time**. At 120 Hz the whole frame budget for physics is 8.3 ms per tick, and that also has to leave room for rendering and the rest of the game.

"Controller script" is the GDScript in `PlayerController` (state machine, pose generation, FK and IK). "Physics + drive + skin" is everything else in the tick: the Jolt step, the per-body drive in `_integrate_forces`, and the skinned mesh update.

**Hardware:** a 4-core Intel Xeon @ 2.1 GHz in a cloud container, headless with no GPU. A desktop CPU is typically 1.5–2.5× faster per core, so treat these as relative numbers and upper bounds.

## Results (Godot 4.5.1, Jolt)

| Scenario | 1 char | 10 | 25 | 50 | 100 | ms per character (at 50) |
|---|---|---|---|---|---|---|
| FULL, idle | 0.62 | 3.79 | 8.13 | 17.02 | 36.83 | 0.34 |
| FULL, walking | 0.65 | 4.01 | 8.83 | 17.48 | 41.68 | 0.35 |
| FULL, ragdolled | 0.59 | 3.02 | 6.88 | 14.46 | 31.55 | 0.29 |
| KINEMATIC, walking | 0.42 | 2.31 | 5.70 | 12.00 | 21.41 | 0.24 (−31 %) |
| PROXY_ONLY, walking | 0.35 | 1.73 | 4.23 | 8.06 | 16.19 | 0.16 (−54 %) |

All values are ms per physics tick. Cost scales linearly. There is no physics blow-up: Jolt handles hundreds of jointed bodies easily.

### What it means

- **Full active ragdoll costs about 0.35 ms per character per tick.** Within a ~4 ms per-tick physics budget (half the 120 Hz frame), that's about **10–12 fully simulated characters** on this CPU, or roughly 20–25 on a desktop.
- **GDScript is about half the cost**, not physics. Pose generation, FK/IK and the per-body drive dominate. Ragdolls are the cheapest FULL state because they skip the pose and drive.
- **KINEMATIC (25–60 m)** costs about 0.24 ms per character. It animates at 60 Hz, places frozen bodies on the animation, and skips IK, while bodies stay hittable.
- **PROXY_ONLY (> 60 m)** costs about 0.16 ms per character. It animates at 30 Hz, bodies are parked and out of collision, and the skin reads the animation directly. What remains is the capsule's movement and state machine, plus per-node engine overhead.
- **Example crowd at about 4 ms per tick:** 4 full + 6 kinematic + 10 proxy-only ≈ 1.4 + 1.4 + 1.6 = 4.4 ms. Beyond a few dozen characters, the next steps are:
  1. Run distant characters' controller logic at 30 Hz too, not just their pose.
  2. Skip skin updates for characters that are off-screen (VisibleOnScreenNotifier3D).
  3. Lower the global physics rate to 60 Hz if the feel survives it. That halves everything.
  4. Move the hot GDScript paths (pose generator, FK/IK, drive) to C++ via GDExtension, typically 10–50× faster.

## LOD tiers

`scripts/player/character_lod.gd`, with settings in the "Performance" group of `MovementConfig`. Every 0.25 s the characters are ranked by distance to the player and assigned within a **budget**:

| Tier | Who | Puppet | Controller + animation | Hittable |
|---|---|---|---|---|
| FULL | nearest 5 within 25 m (`lod_max_full`) | active ragdoll (simulated, driven) | 120 Hz + foot/hand IK | yes, with physical reactions |
| KINEMATIC | next 20 within 60 m (`lod_max_kinematic`) | bodies parked outside the physics server; the skin plays the animation | 30 Hz, no IK | yes: a strike or shove touching the capsule promotes it to FULL |
| PROXY_ONLY | everyone else | parked | 15 Hz, no IK | yes, same as KINEMATIC |

- **Staggered updates.** Reduced tiers update on staggered phases, so their work spreads evenly across ticks instead of landing on one frame.
- **Promotion.** A hit, shove, knockdown or bumper launch promotes a character to FULL immediately, and it stays FULL for 3 s afterwards.
- **Always FULL:** characters that are ragdolling, getting up, staggering, attacking, hanging, climbing or carrying (these count against the FULL budget), and the player.
- **Debug view.** F3 in game tints characters by tier, and the HUD shows how many are in each tier.

**Known limit:** hazards and thrown props don't knock over characters in the reduced tiers. Only melee strikes, being run into, `receive_hit` / `apply_hit` / `enter_ragdoll`, or entering the FULL budget promote them.

## Crowd test: running through 100 NPCs

`tests/crowd.gd` runs a scripted 22 s scenario. 100 wandering NPCs stand in a 26 m square, and the player sprints through them along four waypoints. Running into NPCs staggers them, or knocks them down at sprint speed.

```
# measure: real CPU time per 60 fps frame (2 physics ticks + AI + animation + skinning), headless
godot --headless --fixed-fps 60 --path . -s tests/crowd.gd -- --measure --timeline=crowd.json
# video of the same deterministic run, overlaying the measured simulation FPS
godot --rendering-driver opengl3 --resolution 1280x720 --write-movie crowd.avi --fixed-fps 60 \
  --path . -s tests/crowd.gd -- --timeline=crowd.json
```

**Result** on the 4-core 2.1 GHz cloud VM, with no rendering (there's no GPU here):

- average **13.2 ms per frame (76 FPS)**
- 99th percentile 20.9 ms (48 FPS)
- 90 % of frames within the 16.7 ms budget for 60 fps
- tiers on average: 5 FULL, 20 KINEMATIC, 75 PROXY_ONLY

What it took, from the first measurement (76 ms per frame, 13 FPS):

| Step | Simulation FPS |
|---|---|
| First run: every NPC inside the 25 m range was FULL | 13 |
| LOD budget instead of pure distance (8 FULL, 24 KINEMATIC) | 43 |
| Reduced tiers tick their whole controller at a stride; parked bodies leave the physics server; no drive outside FULL | — |
| Skin updates only the ~20 bones that move (not fingers and toes); flat-table FK; staggered phases | 62 |
| Budget 5 FULL / 20 KINEMATIC | 68 |
| Background update rates 30 Hz / 15 Hz | 76 |

Remaining cost per frame:

| Section | ms per frame |
|---|---|
| Controller GDScript | 7.2 (FK/IK 2.8, pose 1.2, `move_and_slide` 1.1, rest 2.1) |
| Skinning | 2.0 |
| Per-body drive | 0.5 |
| Engine physics and everything else | 3.5 |

The next big win would be moving the pose generator, FK/IK and skinning to C++ (GDExtension).

Rendering isn't included. A real GPU draws 100 low-poly skinned characters in well under a millisecond of CPU submit time, but that wasn't measurable here.
