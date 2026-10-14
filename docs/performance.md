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

`scripts/player/character_lod.gd`, with ranges in the "Performance" group of `MovementConfig`:

| Tier | Distance to the player | Puppet | Animation | Hittable |
|---|---|---|---|---|
| FULL | < 25 m | active ragdoll (simulated, driven) | 120 Hz + foot/hand IK | yes, with physical reactions |
| KINEMATIC | 25–60 m | frozen bodies snapped to the animation | 60 Hz, no IK | yes (promotes to FULL on hit) |
| PROXY_ONLY | > 60 m | parked, out of collision | 30 Hz, no IK | no (only the capsule collides) |

- A hit, knockdown or bumper launch promotes a character to FULL immediately, and it stays FULL for 3 s afterwards.
- Ragdolling, getting up, staggering, attacking, hanging, climbing and carrying always stay FULL.
- The player is always FULL.
- F3 in game tints characters by tier, and the HUD shows how many are in each tier.

**Known limit:** hazards and thrown props don't knock over characters in the reduced tiers. They promote only through `receive_hit` / `apply_hit` / `enter_ragdoll`, or by coming within 25 m of the player.
