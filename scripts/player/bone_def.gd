class_name BoneDef
extends Resource
## One rigid segment of the puppet. All positions are in rig rest space:
## feet on the ground at the origin, facing -Z, +X is the character's right.

enum Shape { CAPSULE, BOX, SPHERE }

@export var name: StringName
@export var parent: StringName           ## empty = root (pelvis)
@export var pivot := Vector3.ZERO        ## joint position shared with the parent
@export var center := Vector3.ZERO       ## body center at rest
@export var shape: Shape = Shape.CAPSULE
@export var size := Vector3(0.05, 0.3, 0.0)  ## capsule: x=radius, y=height | box: extents*2 | sphere: x=radius
@export var mass := 1.0
@export var stiffness := 1.0             ## multiplier on the muscle drive
@export var limit_min := Vector3(-1, -0.5, -0.5)  ## joint angular limits (pitch, twist, roll) in radians
@export var limit_max := Vector3(1, 0.5, 0.5)
@export var color := Color.WHITE


static func make(n: StringName, p: StringName, pv: Vector3, c: Vector3, sh: Shape, sz: Vector3,
		m: float, stiff: float, lmin: Vector3, lmax: Vector3, col: Color) -> BoneDef:
	var b := BoneDef.new()
	b.name = n
	b.parent = p
	b.pivot = pv
	b.center = c
	b.shape = sh
	b.size = sz
	b.mass = m
	b.stiffness = stiff
	b.limit_min = lmin
	b.limit_max = lmax
	b.color = col
	return b


## Placeholder humanoid, ~1.8 m tall, ~64 kg. Parents always precede children.
static func default_humanoid(body: Color) -> Array[BoneDef]:
	var skin := Color(0.93, 0.76, 0.62)
	var limb := body.lightened(0.25)
	var dark := body.darkened(0.35)
	var C := Shape.CAPSULE
	var B := Shape.BOX
	var defs: Array[BoneDef] = []
	defs.append(make(&"pelvis", &"", Vector3(0, 1.0, 0), Vector3(0, 1.0, 0), B, Vector3(0.32, 0.2, 0.18), 10.0, 1.0, Vector3.ZERO, Vector3.ZERO, dark))
	defs.append(make(&"spine", &"pelvis", Vector3(0, 1.1, 0), Vector3(0, 1.2, 0), B, Vector3(0.28, 0.2, 0.17), 8.0, 1.0, Vector3(-0.8, -0.5, -0.4), Vector3(0.5, 0.5, 0.4), body))
	defs.append(make(&"chest", &"spine", Vector3(0, 1.3, 0), Vector3(0, 1.42, 0), B, Vector3(0.38, 0.24, 0.2), 10.0, 1.0, Vector3(-0.6, -0.5, -0.4), Vector3(0.4, 0.5, 0.4), body))
	defs.append(make(&"head", &"chest", Vector3(0, 1.56, 0), Vector3(0, 1.68, 0), Shape.SPHERE, Vector3(0.12, 0, 0), 4.5, 0.8, Vector3(-0.8, -1.0, -0.5), Vector3(0.6, 1.0, 0.5), skin))
	for side: float in [-1.0, 1.0]:
		var s := "l" if side < 0 else "r"
		var x := 0.25 * side
		# Arm Z limits mirrored so "raise outward" is allowed on both sides.
		var zmin := -2.6 if side < 0 else -0.3
		var zmax := 0.3 if side < 0 else 2.6
		defs.append(make(StringName("upper_arm_" + s), &"chest", Vector3(x, 1.5, 0), Vector3(x, 1.36, 0), C, Vector3(0.055, 0.3, 0), 2.0, 0.7, Vector3(-1.4, -1.2, zmin), Vector3(2.8, 1.2, zmax), limb))
		defs.append(make(StringName("forearm_" + s), StringName("upper_arm_" + s), Vector3(x, 1.22, 0), Vector3(x, 1.09, 0), C, Vector3(0.045, 0.28, 0), 1.5, 0.6, Vector3(-0.1, -0.6, -0.2), Vector3(2.5, 0.6, 0.2), limb))
		defs.append(make(StringName("hand_" + s), StringName("forearm_" + s), Vector3(x, 0.96, 0), Vector3(x, 0.9, 0), B, Vector3(0.07, 0.12, 0.05), 0.5, 0.4, Vector3(-0.8, -0.3, -0.4), Vector3(0.8, 0.3, 0.4), skin))
		var lx := 0.1 * side
		defs.append(make(StringName("thigh_" + s), &"pelvis", Vector3(lx, 0.92, 0), Vector3(lx, 0.71, 0), C, Vector3(0.075, 0.42, 0), 7.0, 1.0, Vector3(-0.9, -0.6, -0.6), Vector3(2.4, 0.6, 0.6), dark.lightened(0.15)))
		defs.append(make(StringName("shin_" + s), StringName("thigh_" + s), Vector3(lx, 0.5, 0), Vector3(lx, 0.3, 0), C, Vector3(0.055, 0.4, 0), 3.5, 1.0, Vector3(-2.6, -0.2, -0.15), Vector3(0.05, 0.2, 0.15), dark.lightened(0.15)))
		defs.append(make(StringName("foot_" + s), StringName("shin_" + s), Vector3(lx, 0.1, 0), Vector3(lx, 0.04, -0.05), B, Vector3(0.1, 0.07, 0.25), 1.0, 0.9, Vector3(-0.7, -0.3, -0.3), Vector3(0.8, 0.3, 0.3), Color(0.2, 0.2, 0.22)))
	return defs
