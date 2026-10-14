class_name CrowdVAT
extends RefCounted
## Bakes the humanoid's procedural stroll and idle cycles into vertex animation textures (VAT),
## so a crowd can be drawn with one MultiMesh and zero CPU skinning. The poses come from the
## same PoseGenerator -> FK -> HumanoidSkin path the real characters use, sampled once at startup
## (about 40 frames of 1226 vertices), so crowd NPCs look like the reduced-LOD characters.
##
## Texture layout: one row per frame, one texel per vertex (x = vertex index stored in UV2.x).
## Rows 0..WALK_FRAMES-1 are the stroll cycle, the next IDLE_FRAMES rows the idle cycle.
## Positions and normals are in the character's root space (feet at y = 0, facing -Z).

const WALK_FRAMES := 24
const IDLE_FRAMES := 16
const STROLL_INPUT := 0.45   ## same stick amount the wandering NPC brains use
const STRIDE := 0.7          ## PoseGenerator walk stride (run_k = 0)

static var _cache: Dictionary = {}


## {mesh, material, walk_cycle_m (metres per stroll cycle), idle_period (s), stroll_speed, bake_ms}
static func get_baked(tree: SceneTree) -> Dictionary:
	if _cache.is_empty():
		_cache = _bake(tree)
	return _cache


static func _bake(tree: SceneTree) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var c: PlayerController = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	c.position = Vector3(0, -1000, 0)
	c.use_external_input = true
	tree.root.add_child(c)   # builds the rig and the skin
	c.process_mode = Node.PROCESS_MODE_DISABLED
	c.rig.set_lod(CharacterLOD.Tier.PROXY_ONLY)   # skin reads the animation targets

	var mi: MeshInstance3D = c.skin.model.find_children("*", "MeshInstance3D", true, false)[0]
	var arr := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var nv := verts.size()
	var nb := bones.size() / nv
	var skin: Skin = mi.skin
	var sk: Skeleton3D = c.skin.skeleton
	var bind_bone: Array[int] = []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		bind_bone.append(b)

	var cfg := c.config
	var speed := cfg.walk_speed * STROLL_INPUT
	var walk_cycle_t := 2.0 * STRIDE / speed
	var idle_period := TAU / 2.2   # PoseGenerator idle breathing
	var data := PackedFloat32Array()
	var ndata := PackedFloat32Array()
	data.resize(nv * 3 * (WALK_FRAMES + IDLE_FRAMES))
	ndata.resize(data.size())
	var root := c.root_transform()
	var to_root := root.affine_inverse()

	var cycles := [
		[{"mode": &"ground", "speed": speed, "run_k": 0.0, "move": STROLL_INPUT}, walk_cycle_t, WALK_FRAMES, 0],
		[{"mode": &"ground", "speed": 0.0, "run_k": 0.0, "move": 0.0}, idle_period, IDLE_FRAMES, WALK_FRAMES],
	]
	for cyc in cycles:
		var pg := PoseGenerator.new()
		var frames: int = cyc[2]
		var dt: float = cyc[1] / frames
		for i in frames * 4:   # settle the pose smoothing into its periodic steady state
			pg.compute(cyc[0], dt)
		for f in frames:
			c.rig.step(dt, root, Vector3.ZERO, pg.compute(cyc[0], dt))
			c.skin.update_pose()
			var to_local := to_root * sk.global_transform
			var mats: Array[Transform3D] = []
			for i in bind_bone.size():
				mats.append(to_local * sk.get_bone_global_pose(bind_bone[i]) * skin.get_bind_pose(i))
			var row: int = (cyc[3] + f) * nv * 3
			for v in nv:
				var p := Vector3.ZERO
				var n := Vector3.ZERO
				for k in nb:
					var w := weights[v * nb + k]
					if w <= 0.0:
						continue
					var m := mats[bones[v * nb + k]]
					p += (m * verts[v]) * w
					n += (m.basis * norms[v]) * w
				n = n.normalized()
				var o := row + v * 3
				data[o] = p.x
				data[o + 1] = p.y
				data[o + 2] = p.z
				ndata[o] = n.x
				ndata[o + 1] = n.y
				ndata[o + 2] = n.z
	c.queue_free()

	var h := WALK_FRAMES + IDLE_FRAMES
	var pos_tex := ImageTexture.create_from_image(Image.create_from_data(nv, h, false, Image.FORMAT_RGBF, data.to_byte_array()))
	var nrm_tex := ImageTexture.create_from_image(Image.create_from_data(nv, h, false, Image.FORMAT_RGBF, ndata.to_byte_array()))

	# Static mesh: first idle frame as the bind shape, vertex index in UV2.x for the texture lookup.
	var rest := PackedVector3Array()
	var rest_n := PackedVector3Array()
	var uv2 := PackedVector2Array()
	rest.resize(nv)
	rest_n.resize(nv)
	uv2.resize(nv)
	var r0 := WALK_FRAMES * nv * 3
	for v in nv:
		rest[v] = Vector3(data[r0 + v * 3], data[r0 + v * 3 + 1], data[r0 + v * 3 + 2])
		rest_n[v] = Vector3(ndata[r0 + v * 3], ndata[r0 + v * 3 + 1], ndata[r0 + v * 3 + 2])
		uv2[v] = Vector2(v, 0)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = rest
	out[Mesh.ARRAY_NORMAL] = rest_n
	out[Mesh.ARRAY_TEX_UV2] = uv2
	out[Mesh.ARRAY_INDEX] = arr[Mesh.ARRAY_INDEX]
	# Simplified LODs (vertices are kept, so the texture lookup still matches) for distant chunks.
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, out)
	im.generate_lods(25.0, 60.0, [])
	var mesh := im.get_mesh()
	mesh.custom_aabb = AABB(Vector3(-1.0, -0.2, -1.0), Vector3(2.0, 2.4, 2.0))

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/crowd_vat.gdshader")
	mat.set_shader_parameter("pos_tex", pos_tex)
	mat.set_shader_parameter("nrm_tex", nrm_tex)
	mat.set_shader_parameter("walk_frames", WALK_FRAMES)
	mat.set_shader_parameter("idle_frames", IDLE_FRAMES)
	mesh.surface_set_material(0, mat)
	return {"mesh": mesh, "material": mat, "walk_cycle_m": 2.0 * STRIDE, "idle_period": idle_period,
		"stroll_speed": speed, "vertices": nv, "bake_ms": Time.get_ticks_msec() - t0,
		"pos_data": data}
