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

| Scenario | 1 char | 10 | 25 | 50 | 100 | ms per character (at 100) |
|---|---|---|---|---|---|---|
| FULL, idle | 0.47 | 3.45 | 8.97 | 14.46 | 34.75 | 0.35 |
| FULL, walking | 0.46 | 3.56 | 8.31 | 17.37 | 38.86 | 0.39 |
| FULL, ragdolled | 0.48 | 2.93 | 6.60 | 13.04 | 32.50 | 0.33 |
| KINEMATIC, walking | 0.18 | 0.71 | 1.48 | 2.96 | 5.25 | 0.053 (−86 %) |
| PROXY_ONLY, walking | 0.25 | 0.39 | 0.88 | 1.71 | 3.98 | 0.040 (−90 %) |

All values are ms per physics tick. Cost scales linearly. There is no physics blow-up: Jolt handles hundreds of jointed bodies easily.

### What it means

- **Full active ragdoll costs about 0.35 ms per character per tick.** Within a ~4 ms per-tick physics budget (half the 120 Hz frame), that's about **10–12 fully simulated characters** on this CPU, or roughly 20–25 on a desktop. Hence the FULL budget of 5.
- **GDScript is about half the cost**, not physics. Pose generation, FK/IK and the per-body drive dominate. Ragdolls are the cheapest FULL state because they skip the pose and drive.
- **KINEMATIC costs about 0.05 ms per character** (7× cheaper). The controller ticks at 30 Hz, the puppet bodies are parked outside the physics server, and the skin plays the animation.
- **PROXY_ONLY costs about 0.04 ms per character** (9× cheaper). Same as KINEMATIC, at 15 Hz.
- **Example: 5 full + 20 kinematic + 75 proxy-only** ≈ 1.8 + 1.1 + 3.0 = 5.9 ms per tick in the worst case. In practice it's lower, because reduced tiers spread their work over staggered ticks (see the crowd test below). Next steps if more is needed:
  1. Skip skin updates for characters that are off-screen (VisibleOnScreenNotifier3D).
  2. Lower the global physics rate to 60 Hz if the feel survives it. That halves everything.
  3. Move the hot GDScript paths (pose generator, FK/IK, drive, skinning) to C++ via GDExtension, typically 10–50× faster.

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

## Crowd test: running through 100 NPCs (all real characters)

`tests/crowd.gd` runs a scripted 22 s scenario. 100 wandering NPCs stand in a 26 m square, and the player sprints through them along four waypoints. Running into NPCs staggers them, or knocks them down at sprint speed. This section is the `--characters` mode, where every NPC is a full `PlayerController` with character LOD. The default is now the crowd layer (next section).

```
# measure: real CPU time per 60 fps frame (2 physics ticks + AI + animation + skinning), headless
godot --headless --fixed-fps 60 --path . -s tests/crowd.gd -- --measure --characters --timeline=crowd.json
# video of the same deterministic run, overlaying the measured simulation FPS
godot --rendering-driver opengl3 --resolution 1280x720 --write-movie crowd.avi --fixed-fps 60 \
  --path . -s tests/crowd.gd -- --timeline=crowd.json
```

**Result** on the 4-core 2.1 GHz cloud VM, with no rendering (there's no GPU here):

- average **13.2 ms per frame (76 FPS)**; 15.1 ms (66 FPS) with the foot-placement locomotion
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

## Crowd layer: 1000 and more NPCs

With every NPC a real character, 1000 NPCs ran at 13 FPS. Each one still had 17 physics bodies (Jolt's default limit of 10,240 bodies ran out after about 600 NPCs) and per-character GDScript, FK and skinning. `scripts/crowd/crowd_layer.gd` adds a separate crowd tier underneath the character LOD:

- **NPCs are plain data.** Position, velocity, heading and wander state live in packed arrays and are updated by one node: wander, turn back home, personal space via a uniform grid. Agents beyond 40 m update every third frame.
- **Baked animation instead of skinning.** At startup, `scripts/crowd/crowd_vat.gd` samples the real character's stroll and idle cycles (the same PoseGenerator → FK → skin path) into vertex animation textures. 1226 vertices × 40 frames take about 50 ms. `shaders/crowd_vat.gdshader` plays them back per instance.
- **Chunked MultiMeshes.** NPCs are drawn with one MultiMesh per 16 m × 16 m chunk, so off-screen chunks are culled. The mesh has generated LODs (1968 → 41 triangles) for distant chunks. Zero CPU skinning, and one draw call per visible chunk.
- **The nearest 24 NPCs become real characters, borrowed from a pool.** Every 0.1 s, the agents nearest the player (and where the player is heading) become pooled `PlayerController`s with active ragdoll, shoves, combat and knockdowns. The existing LOD budget then makes 5 of them FULL and the rest KINEMATIC. When an agent drops out of that set and its character is calm again (on its feet, not hit recently), the character is parked: disabled, so out of the physics server. The agent continues as data from where the character stopped.

```
godot --headless --fixed-fps 60 --path . -s tests/crowd.gd -- --measure --npcs=1000
tools/crowd_mac.sh live --npcs=1000      # real time with rendering, on a Mac
```

**Results** on the 4-core 2.1 GHz cloud VM, simulation only (2 physics ticks + AI + animation per 60 fps frame, no rendering):

| NPCs | Average | 99th percentile | Crowd layer update | Real characters (avg) |
|---|---|---|---|---|
| 100 | 7.9 ms (127 FPS) | 13.4 ms (75 FPS) | 0.25 ms | 4.4 full, 14.8 kinematic |
| 1000 | 9.6 ms (105 FPS) | 15.3 ms (65 FPS) | 1.6 ms | 4.8 full, 19.1 kinematic |
| 10,000 | 18.2 ms (55 FPS) | 30.4 ms (33 FPS) | 9.7 ms | 4.8 full, 19.1 kinematic |

These numbers include the foot-placement locomotion (planted feet, leg IK in every tier), which costs about 1.3 ms per frame over the old sine-wave gait for the 24 real characters. Before it: 159 / 119 / 61 FPS.

About 5 ms of every frame is the 24 real characters, about the same at any crowd size. The crowd layer costs about 1 µs per NPC per frame in GDScript. At 10,000 NPCs, that loop is the next thing to move to C++ (GDExtension) or a compute shader.

**Rendering:** 1000 NPCs × 1226 vertices is about 1.2 M vertices for the visible chunks. That's trivial for any GPU, but slow on this VM's software renderer (about 0.7 s per frame for the recorded video).

**Limits:**
- Crowd agents walk on the plane of their home point. They don't query the ground or collide with level geometry, so crowds belong on open ground.
- Hazards and thrown props only affect the real characters near the player.
- Handing an agent to a character snaps from the baked stroll to the procedural pose; at that distance the switch is subtle.
