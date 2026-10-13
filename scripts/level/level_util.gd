class_name LevelUtil
## Greybox helpers: boxes, ramps and a world-space grid material.

static var _grid_tex: Texture2D
static var _mats := {}


static func grid_texture() -> Texture2D:
	if _grid_tex == null:
		var n := 256
		var img := Image.create(n, n, true, Image.FORMAT_RGB8)
		for y in n:
			for x in n:
				var checker := ((x / 128) + (y / 128)) % 2 == 0
				var v := 0.82 if checker else 0.74
				if x % 64 < 2 or y % 64 < 2:
					v = 0.55
				img.set_pixel(x, y, Color(v, v, v))
		img.generate_mipmaps()
		_grid_tex = ImageTexture.create_from_image(img)
	return _grid_tex


## Grid-textured material in world-space triplanar, 1 texture tile per 4 m (1 m lines).
static func mat(color: Color) -> StandardMaterial3D:
	if _mats.has(color):
		return _mats[color]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = grid_texture()
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.25
	m.roughness = 0.85
	_mats[color] = m
	return m


static func box(parent: Node, size: Vector3, xform: Transform3D, color: Color, collide := true,
		layer := InputSetup.LAYER_WORLD) -> Node3D:
	var root: Node3D
	if collide:
		var sb := StaticBody3D.new()
		sb.collision_layer = layer
		sb.collision_mask = 0
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		sb.add_child(cs)
		root = sb
	else:
		root = Node3D.new()
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat(color)
	root.add_child(mi)
	parent.add_child(root)
	root.transform = xform
	return root


## Ramp whose top surface runs from `bottom` to `top` (both on the surface centerline).
static func ramp(parent: Node, bottom: Vector3, top: Vector3, width: float, color: Color,
		visible := true, thickness := 0.4, layer := InputSetup.LAYER_WORLD) -> Node3D:
	var d := top - bottom
	var fwd := d.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd)
	var b := Basis(right, up, -fwd)
	var center := (bottom + top) * 0.5 - up * thickness * 0.5
	var size := Vector3(width, thickness, d.length())
	if visible:
		return box(parent, size, Transform3D(b, center), color, true, layer)
	var sb := StaticBody3D.new()
	sb.collision_layer = layer
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	parent.add_child(sb)
	sb.transform = Transform3D(b, center)
	return sb


static func dynamic_box(parent: Node, size: Vector3, pos: Vector3, mass: float, color: Color) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.mass = mass
	rb.collision_layer = InputSetup.LAYER_PROPS
	rb.collision_mask = InputSetup.LAYER_WORLD | InputSetup.LAYER_PUPPET | InputSetup.LAYER_PROPS | InputSetup.LAYER_HAZARDS | InputSetup.LAYER_DETAIL
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat(color)
	rb.add_child(mi)
	parent.add_child(rb)
	rb.global_position = pos
	return rb
