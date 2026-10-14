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
| Turns | left turn 90, right turn 90, turn 180, running turn 180 |

**How it's used.** Looping clips are recognized by name: idle, walk, jog, run and sprint. A
looping clip slower than 0.3 m/s is the idle; the rest are blended by speed.

On first run, Godot imports the FBX files, and `scripts/anim/mocap_importer.gd` retargets them
onto the puppet. The result is cached in `user://mocap_cache/`.

With no clips here, the game uses the procedural locomotion.
