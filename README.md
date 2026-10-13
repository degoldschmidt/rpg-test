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
| Lift / drop, or grab to push and pull | E | RB |
| Throw a carried object | F | LB |
| Toggle ragdoll | G | Y |
| Reset player | R | Back |
| Camera | Mouse (click to capture, Esc to release) | Right stick |
| Toggle help | F1 | |
| Show physics bodies instead of the mesh | F2 | |

**Ledges:**
- **Mantle:** jump facing a chest-high ledge (0.6–1.6 m) and you climb straight onto it. A running jump into a ledge keeps some of your speed over the top.
- **Grab:** jump at a higher ledge (up to about 3.6 m from the ground) to grab it and hang.
- **While hanging:** A/D shimmies along the ledge and stops at its end. Jump or W climbs up. Crouch or S drops off.

**Objects** (the HUD shows what E will do):
- **Lift:** objects up to 25 kg are lifted and carried in both hands. Carrying slows you in proportion to the weight. E drops the object; F throws it, and lighter objects fly further.
- **Push / pull:** objects from 25 to 300 kg are grabbed by the face you're looking at. W pushes and S pulls, and heavier objects move more slowly. E, jump or crouch lets go. Pulling stops at walls behind you.
- Anything heavier than 300 kg can't be moved.

**Tip:** press roll just before landing from a big drop to roll it out instead of ragdolling.

## Test level

The level is built in code by `scripts/main.gd`. It contains:
- **Ramps:** 15°, 30° and 45°.
- **Stairs**
- **Landing platforms:** 2, 5 and 10 m high, each with a ramp up.
- **Crouch tunnel:** ceiling at 1.5 m.
- **Jump gaps:** 2.5, 3.5 and 4.5 m.
- **Props yard:** a 4 kg box, an 18 kg sack, a 3 kg ball, an 80 kg crate, a 250 kg block and a 600 kg monolith.
- **Climbing area:** a 1.2 m mantle block, and an 8 m wide, 3 m tall wall to hang, shimmy and climb, with a higher ledge stacked on top.
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
- **Skin.** `HumanoidSkin` drives a skinned humanoid mesh from the puppet.
  - Each mapped skeleton bone takes its world rotation from its physics body.
  - Limb bones are aligned once from the model's A-pose to the puppet's rest pose.
  - Limb and neck bone heads are pinned to the puppet's joint pivots, so hands and feet are exactly where the physics contacts are. The spine is rebuilt down the hierarchy from the hips.
  - The puppet's joint positions match the model's proportions, so pinning doesn't visibly stretch the mesh.
  - Fingers, toes, shoulders and pelvis bones keep their rest pose relative to their parent.
  - F2 shows the physics capsules instead.
  - The model is the CC0 "3D Male Base Mesh" (Rigify bone names). Any mesh with the same bone names can replace it through `model_scene`. See `assets/characters/LICENSE.md`.
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
- **Ledges** (in `player_controller.gd`, under "ledges").
  - Detection: forward rays find a wall, a downward ray finds the ledge top, and a capsule overlap test checks there's room to stand on top.
  - Ledge height relative to the feet picks the move: ground mantle, mid-air mantle, or grab and hang.
  - `LEDGE_HANG` pins the capsule under the edge and re-probes the ledge as it shimmies. `CLIMB` moves the capsule up first, then over the edge.
  - The puppet blends through hang → pull → crouch → stand key poses.
  - All tunables are in the "Ledges" group of `MovementConfig`.
- **Objects** (in `player_controller.gd`, under "objects").
  - Carried objects are driven toward a hold point by a strength-limited force with gravity compensation. Collisions with the body are switched off while held and restored shortly after release.
  - Pushed or pulled objects get a strength-limited horizontal force applied low on the object, so friction doesn't tip it. The capsule follows the grab point, and contacts with the held object never count as hits.
  - Hand IK (two-bone, same solver as the legs) puts the palms on the object's sides or face.
  - All tunables are in the "Objects" group of `MovementConfig`.
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

The suite has 109 deterministic gameplay checks. It covers:
- idle stability and joint-limit sanity
- walk and run acceleration and inertia
- skid
- variable jump height
- crouch under the tunnel ceiling
- skinned mesh tracking the puppet: joint positions and limb directions while idle, running and ragdolled
- objects: lift, carry while running, throw, drop, push and pull the crate, the heavier block being slower, the monolith being too heavy
- ledges: ground, running and mid-air mantles; grab, hang height and hand placement; shimmy and stopping at the ledge end; climbing up; dropping off without re-grabbing; out-of-reach walls
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

- Replace the procedural poses with authored animations, sampled as puppet targets, and give the character clothing and textures.
- Add combat hit reactions through `apply_hit`.
- Move hot paths to C# or GDExtension if profiling shows a need. With many NPCs, put distant characters on a cheaper kinematic-only LOD.
