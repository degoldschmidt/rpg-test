# rpg-test: movement prototype

A physics-driven third-person movement prototype for a future RPG, built with **Godot 4.5 + Jolt Physics**.
The character keeps momentum (walk, run, skid, crouch, slide, jump, forward roll) and is an **active ragdoll**.
It follows its animation tightly, wobbles when hit, and collapses into a full ragdoll on hard falls and hazards, then gets back up.

![Swinging log knocks the player into a ragdoll](docs/log_hit.png)

## Run it

1. Install [Godot 4.5.x](https://godotengine.org/download) (standard build, no C# needed).
2. Open `project.godot` in Godot and press **F5**, or from a terminal run `godot --path .`.

| Action | Keyboard / mouse | Gamepad |
|---|---|---|
| Move | WASD | Left stick |
| Run | Shift | L3 / left trigger |
| Jump (hold for height) | Space | A |
| Crouch (while running: slide) | Ctrl or C | B |
| Forward roll | Q | X |
| Toggle ragdoll | G | Y |
| Reset player | R | Back |
| Camera | Mouse (click to capture, Esc to release) | Right stick |
| Toggle help | F1 | |

**Tip:** press roll just before landing from a big drop to roll it out instead of ragdolling.

## Test level

The level is built in code by `scripts/main.gd`. It contains:
- **Ramps:** 15°, 30° and 45°.
- **Stairs**
- **Landing platforms:** 2, 5 and 10 m high, each with a ramp up.
- **Crouch tunnel:** ceiling at 1.5 m.
- **Jump gaps:** 2.5, 3.5 and 4.5 m.
- **Crate pyramid:** physics props.
- **Hazards:** a swinging log, a rotating sweeper bar (jump it), a red bumper, and a ramp that drops boulders.

## Architecture: proxy + puppet

```
PlayerController (CharacterBody3D capsule)   ← gameplay truth: input, momentum, FSM
  │  pose ctx (state, speed, phase, lean…)
  ▼
PoseGenerator  → per-bone target rotations (procedural, no animation assets)
  │
  ▼
RagdollRig     → 16 RigidBody3D segments + Generic6DOFJoint3D (anatomical limits)
                 forward kinematics turns the pose into world targets;
                 each PuppetBone blends its velocity toward its target
                 scaled by muscle × stiffness × per-limb weakness
```

- **Proxy.** The `CharacterBody3D` handles all movement, so controls stay deterministic and responsive. This is the setup shipped games use. Balancing a character with physics alone is fragile.
- **Puppet.** Physical bodies follow the proxy through velocity-based muscles. Arms swing with inertia, the body banks into turns, and props shove limbs around.
- **Muscle.**
  - `muscle = 1`: the puppet looks animated.
  - `muscle = 0`: full ragdoll.
  - A stumble briefly drops it to 0.35.
  - A limb hit by a prop goes limp for about half a second (partial ragdoll).
- **Ragdoll triggers.**
  - A landing faster than `ragdoll_land_speed` (about 5 m or more).
  - Summed contact hits from props or hazards above `ragdoll_hit_threshold`. Hit strength is relative speed × mass.
  - `apply_hit(dv, point)`, used by the bumper and available for future combat.
- **Get-up.** Once the body settles, the proxy snaps under the pelvis and muscles ramp back up to a crouch, then to standing.
- **Foot IK** (in `ragdoll_rig.gd`, after FK). Each foot raycasts down to the ground under it.
  - The pelvis drops for the lower foot.
  - An analytic two-bone IK re-aims thigh and shin so each ankle lands at its own ground height, keeping the knee's bend direction.
  - Each foot tilts to the surface normal.
  - Results are smoothed to hide pops at step edges.
  - IK is on while grounded (ground, crouch, stumble, get-up), partly on during a slide, and off in the air or a roll.
  - Tunables: `ik_probe_up`, `ik_max_drop`, `ik_smoothing`.
- **Stairs.** The capsule rides a smooth invisible ramp through the step nosings (`proxy_only` layer). The treads are real colliders that only the puppet and foot IK see (`detail` layer), so the movement stays smooth while the feet land on each step.

### Physics layers

| Layer | Used by |
|---|---|
| 1 world | static level |
| 2 player_proxy | the movement capsule; collides with world, props and proxy_only |
| 3 puppet | ragdoll bodies; collide with world, props, hazards and detail, never with each other or the proxy |
| 4 props | crates, boulders |
| 5 hazards | kinematic log and sweeper |
| 6 proxy_only | collision only the capsule sees (smooth stair ramp) |
| 7 detail | collision only the puppet and foot IK see (stair treads) |

## Tuning

Every movement and ragdoll value is in `resources/movement_default.tres` (`MovementConfig`). Edit it in the Godot inspector. It covers:
- speeds and accelerations
- turn rates
- skid
- jump height
- gravity multipliers
- coyote time and jump buffer
- slide and roll
- landing thresholds
- hit thresholds
- get-up timing

Muscle stiffness gains are at the top of `scripts/player/ragdoll_rig.gd`. Per-bone stiffness, masses and joint limits are in `scripts/player/bone_def.gd`.

## Tests

```
godot --headless --fixed-fps 120 --path . -s tests/run_tests.gd
```

The suite has 57 deterministic gameplay checks. It covers:
- idle stability and joint-limit sanity
- walk and run acceleration and inertia
- skid
- variable jump height
- crouch under the tunnel ceiling
- foot IK on a 30° slope and on stairs (feet on the surface and tilted to it, pelvis drop, stair climb without sinking)
- slide distance
- roll tumble
- stumble landing
- hard-fall ragdoll and get-up
- roll-landing save
- log and bumper knockdowns
- 30 s of random input with NaN and separation checks

The process exits non-zero on failure.

## File map

```
project.godot                      Jolt, 120 Hz physics, layer names
scenes/main.tscn, player.tscn
scripts/main.gd                    level, player, camera, HUD
scripts/input_setup.gd             input actions (keyboard + gamepad), layer constants
scripts/player/player_controller.gd  movement + state machine
scripts/player/pose_generator.gd     procedural poses (gait, crouch, slide, air, roll, get-up)
scripts/player/ragdoll_rig.gd        builds the puppet, FK targets, muscles, hit handling
scripts/player/puppet_bone.gd        per-body drive + contact hit detection
scripts/player/bone_def.gd           humanoid definition
scripts/player/movement_config.gd    tunables resource
scripts/camera/camera_rig.gd         orbit camera with spring arm
scripts/level/*.gd                   greybox helpers and hazards
scripts/ui/debug_hud.gd
tests/run_tests.gd
```

## Next steps toward the RPG

- Swap the capsule puppet for a skinned humanoid. Drive its `Skeleton3D` bones from the puppet bodies, or use `PhysicalBoneSimulator3D`. Replace the procedural poses with authored animations sampled as targets.
- Add ledge grab and mantle, plus combat hit reactions through `apply_hit`.
- Move hot paths to C# or GDExtension if profiling shows a need. With many NPCs, put distant characters on a cheaper kinematic-only LOD.
