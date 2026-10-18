# Mixamo clips (local only)

Put Mixamo exports here (`*.fbx`). Mixamo's terms don't allow redistributing the raw files,
so everything in this folder except this README is gitignored.

**Export settings** (mixamo.com, default X Bot / Y Bot):
- Format: FBX Binary (.fbx)
- Skin: Without Skin
- Frames per second: 60
- Keyframe reduction: none
- In Place: unchecked (the importer needs the forward travel)

**Clips** (Mixamo search terms; pick the closest match, keep the file names descriptive):

| Purpose | Search for |
|---|---|
| Cycles | breathing idle, walking, jogging, running, fast run |
| Starts | start walking, run start |
| Stops | stop walking, run to stop |
| Turns | left turn, right turn 90, walking turn 180, running turn 180 |

**How it's used.** Looping clips are recognized by name: idle, walk, jog, run and sprint. A
looping clip slower than 0.3 m/s is the idle; the rest are blended by speed.

One-shot clips are matched by name:
- stop, start (walk), idle to sprint
- running turn 180
- turns on the spot: any "turn" clip that barely travels, left or right, any angle

`tools/import_mocap.gd` lists what each clip is used for.

On first run, Godot imports the FBX files, and `scripts/anim/mocap_importer.gd` retargets them
onto the puppet. The result is cached in `user://mocap_cache/`. To do that once up front (and see
the list), run `tools/crowd_mac.sh import` on a Mac, or
`godot --headless --path . --import; godot --headless --path . -s tools/import_mocap.gd`.

With no clips here, the game uses the procedural locomotion.
