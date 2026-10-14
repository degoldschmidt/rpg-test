class_name CrowdLayer
extends Node3D
## Lightweight crowd for hundreds to thousands of NPCs.
##
## Every NPC is plain data (position, velocity, wander state) updated by this one node, drawn
## with MultiMeshes that play baked vertex animation (CrowdVAT), so a crowd NPC has no nodes, no
## physics bodies and no skinning. The crowd is split into CHUNK-sized MultiMeshes by home
## position, so off-screen chunks are culled and distant ones use the simplified mesh LODs. Only the `pool_size` agents nearest
## the focus (usually the player) become real PlayerControllers, borrowed from a pool: active
## ragdoll, shoves, combat, knockdowns. When an agent leaves that set and its character is calm
## again (not ragdolled, staggered, attacking, recently hit), the character goes back to the
## pool and the agent continues as data from where the character stopped.
##
## Limits: crowd agents walk on the plane of their home point (no ground queries) and only avoid
## each other, materialized characters and the focus; they don't collide with level geometry,
## so place crowds on open ground.

const FLOATS := 20   ## per MultiMesh instance: 12 transform + 4 color + 4 custom
const CHUNK := 16.0  ## metres per MultiMesh chunk
const PLAYER_SCENE := preload("res://scenes/player.tscn")

@export var pool_size := 24
@export var query_radius := 12.0     ## agents considered for materializing (m around the focus)
@export var wander_radius := 2.0
@export var personal_space := 0.7    ## agents push apart below this distance
@export var decide_interval := 0.1   ## seconds between materialize / release decisions
@export var accel := 9.0
@export var far_range := 40.0        ## beyond this, agents update every `far_stride` frames
@export var far_stride := 3

var focus: Node3D
var count := 0
var pos := PackedVector3Array()
var home := PackedVector3Array()
var vel := PackedVector2Array()
var yaw := PackedFloat32Array()
var wdir := PackedVector2Array()     ## wander intent, unit length or zero
var wt := PackedFloat32Array()       ## time until the next wander decision
var walk_ph := PackedFloat32Array()
var idle_ph := PackedFloat32Array()
var skin_col := PackedColorArray()
var materialized := PackedByteArray()
var pool: Array[PlayerController] = []

var _free: Array[PlayerController] = []
var _agent_of := {}                  ## PlayerController -> agent index
var _rng := RandomNumberGenerator.new()
var _mms: Array[MultiMesh] = []
var _bufs: Array[PackedFloat32Array] = []
var _chunk_agents: Array[PackedInt32Array] = []
var _chunk_of := PackedInt32Array()   ## agent -> chunk
var _slot := PackedInt32Array()       ## agent -> instance index in its chunk
var _decide_t := 0.0
var _frame := 0
var _stroll := 1.5
var _walk_m := 1.4
var _idle_t := 2.9
# Uniform grid with per-cell linked lists, rebuilt every 4th frame, for neighbour queries.
const CELL := 2.0
var _gmin := Vector2.ZERO
var _gmax := Vector2.ZERO
var _gw := 1
var _gh := 1
var _head := PackedInt32Array()
var _next := PackedInt32Array()


func add_agent(p: Vector3, facing: float, color: Color) -> int:
	pos.append(p)
	home.append(p)
	vel.append(Vector2.ZERO)
	yaw.append(facing)
	wdir.append(Vector2.ZERO)
	wt.append(0.0)
	walk_ph.append(0.0)
	idle_ph.append(0.0)
	skin_col.append(color)
	materialized.append(0)
	count += 1
	return count - 1


## Call once after adding the agents (the node must be in the tree).
func build(seed := 7) -> void:
	_rng.seed = seed
	var vat := CrowdVAT.get_baked(get_tree())
	_stroll = vat.stroll_speed
	_walk_m = vat.walk_cycle_m
	_idle_t = vat.idle_period
	for i in count:
		wt[i] = _rng.randf_range(0.0, 2.0)
		walk_ph[i] = _rng.randf()
		idle_ph[i] = _rng.randf()

	_gmin = Vector2(INF, INF)
	_gmax = -_gmin
	for p in home:
		_gmin = _gmin.min(Vector2(p.x, p.z))
		_gmax = _gmax.max(Vector2(p.x, p.z))
	var margin := wander_radius + 4.0
	_gmin -= Vector2.ONE * margin
	_gmax += Vector2.ONE * margin
	_gw = int(ceil((_gmax.x - _gmin.x) / CELL)) + 1
	_gh = int(ceil((_gmax.y - _gmin.y) / CELL)) + 1
	_head.resize(_gw * _gh)
	_next.resize(count)
	_rebuild_grid()

	# One MultiMesh per CHUNK x CHUNK area of home positions (agents stay near home).
	var ids := {}
	_chunk_of.resize(count)
	_slot.resize(count)
	for i in count:
		var key := Vector2i(floori((home[i].x - _gmin.x) / CHUNK), floori((home[i].z - _gmin.y) / CHUNK))
		if not ids.has(key):
			ids[key] = _chunk_agents.size()
			_chunk_agents.append(PackedInt32Array())
		var ch: int = ids[key]
		_chunk_of[i] = ch
		_slot[i] = _chunk_agents[ch].size()
		_chunk_agents[ch].append(i)
	var reach := wander_radius + 3.0
	for ch in _chunk_agents.size():
		var list := _chunk_agents[ch]
		var buf := PackedFloat32Array()
		buf.resize(list.size() * FLOATS)
		var box := AABB(home[list[0]], Vector3.ZERO)
		for k in list.size():
			var i := list[k]
			box = box.expand(home[i])
			var b := k * FLOATS
			buf[b + 5] = 1.0
			buf[b + 12] = skin_col[i].r
			buf[b + 13] = skin_col[i].g
			buf[b + 14] = skin_col[i].b
			buf[b + 15] = 1.0
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = vat.mesh
		mm.instance_count = list.size()
		mm.custom_aabb = box.grow(reach)   # wander reach around the homes, and body height
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Chunk%d" % ch
		mmi.multimesh = mm
		add_child(mmi)
		_mms.append(mm)
		_bufs.append(buf)

	for k in pool_size:
		var c: PlayerController = PLAYER_SCENE.instantiate()
		c.name = "Pooled%02d" % k
		c.use_external_input = true
		c.lod_enabled = true
		c.position = Vector3(0, -500.0 - k * 5.0, 0)
		add_child(c)
		var brain := DummyBrain.new()
		brain.name = "Brain"
		brain.mode = DummyBrain.Mode.WANDER
		brain.wander_radius = wander_radius
		c.add_child(brain)
		_park(c)
		pool.append(c)
		_free.append(c)
	_update(0.0)


func _process(dt: float) -> void:
	if _mms.is_empty():
		return
	var t0 := Time.get_ticks_usec() if PlayerController.profile else 0
	_update(minf(dt, 0.1))
	if PlayerController.profile:
		PlayerController.prof_add("crowd", Time.get_ticks_usec() - t0)


func _update(dt: float) -> void:
	_frame += 1
	for c: PlayerController in _agent_of:
		var a: int = _agent_of[c]
		pos[a] = c.global_position
		yaw[a] = c.facing_yaw
		vel[a] = Vector2(c.velocity.x, c.velocity.z)
	var group := _frame % 4
	if group == 0:
		_rebuild_grid()
	var fp := Vector3(INF, 0, INF)
	if focus and is_instance_valid(focus):
		fp = focus.global_position
	var ps2 := personal_space * personal_space
	var far2 := far_range * far_range
	for ch in _chunk_agents.size():
		_update_chunk(ch, dt, fp, ps2, far2, group)
	_decide_t -= dt
	if _decide_t <= 0.0:
		_decide_t = decide_interval
		_decide(fp)
	for ch in _mms.size():
		RenderingServer.multimesh_set_buffer(_mms[ch].get_rid(), _bufs[ch])


func _update_chunk(ch: int, step: float, fp: Vector3, ps2: float, far2: float, group: int) -> void:
	var buf := _bufs[ch]
	var list := _chunk_agents[ch]
	var near_dt := step
	var far_dt := step * far_stride
	for slot in list.size():
		var i := list[slot]
		if materialized[i]:
			continue
		var p := pos[i]
		# Far agents update on staggered frames with a longer step (nobody can tell at that range).
		var dt := near_dt
		if (p.x - fp.x) * (p.x - fp.x) + (p.z - fp.z) * (p.z - fp.z) > far2:
			if (i + _frame) % far_stride != 0:
				continue
			dt = far_dt
		# Wander: stroll in a random direction or pause, head home when too far out (as DummyBrain).
		var t := wt[i] - dt
		if t <= 0.0:
			t = _rng.randf_range(1.5, 4.0)
			if _rng.randf() < 0.4:
				wdir[i] = Vector2.ZERO
			else:
				var h := home[i]
				var th := Vector2(h.x - p.x, h.z - p.z)
				var a := _rng.randf_range(0.0, TAU)
				wdir[i] = th.normalized() if th.length() > wander_radius else Vector2(cos(a), sin(a))
		wt[i] = t
		var wd := wdir[i]
		if wd != Vector2.ZERO:
			# Out of the home radius and still walking away: turn back now.
			var hx := home[i].x - p.x
			var hz := home[i].z - p.z
			if hx * hx + hz * hz > wander_radius * wander_radius and wd.x * hx + wd.y * hz < 0.0:
				wd = Vector2(hx, hz).normalized()
				wdir[i] = wd
		var v := vel[i].move_toward(wd * _stroll, accel * dt)
		vel[i] = v
		p.x += v.x * dt
		p.z += v.y * dt
		# Personal space, a quarter of the crowd per frame.
		if i % 4 == group:
			p = _separate(i, p, ps2)
		var fx := p.x - fp.x
		var fz := p.z - fp.z
		var fd2 := fx * fx + fz * fz
		if fd2 < 0.81 and fd2 > 0.0001:
			var fd := sqrt(fd2)
			p.x += fx / fd * (0.9 - fd)
			p.z += fz / fd * (0.9 - fd)
		p.x = clampf(p.x, _gmin.x, _gmax.x)
		p.z = clampf(p.z, _gmin.y, _gmax.y)
		pos[i] = p
		var sp := v.length()
		var y := yaw[i]
		if sp > 0.05:
			y = lerp_angle(y, atan2(-v.x, -v.y), minf(8.0 * dt, 1.0))
			yaw[i] = y
		var wp := fmod(walk_ph[i] + sp / _walk_m * dt, 1.0)
		walk_ph[i] = wp
		var ip := fmod(idle_ph[i] + dt / _idle_t, 1.0)
		idle_ph[i] = ip
		var b := slot * FLOATS
		var co := cos(y)
		var si := sin(y)
		buf[b] = co
		buf[b + 2] = si
		buf[b + 3] = p.x
		buf[b + 7] = p.y
		buf[b + 8] = -si
		buf[b + 10] = co
		buf[b + 11] = p.z
		buf[b + 16] = wp
		buf[b + 17] = minf(sp / _stroll, 1.0)
		buf[b + 18] = ip


func _cell_of(x: float, z: float) -> int:
	var cx := clampi(int((x - _gmin.x) / CELL), 0, _gw - 1)
	var cz := clampi(int((z - _gmin.y) / CELL), 0, _gh - 1)
	return cz * _gw + cx


func _rebuild_grid() -> void:
	_head.fill(-1)
	for i in count:
		var p := pos[i]
		var c := _cell_of(p.x, p.z)
		_next[i] = _head[c]
		_head[c] = i


func _separate(i: int, p: Vector3, ps2: float) -> Vector3:
	var cx := clampi(int((p.x - _gmin.x) / CELL), 0, _gw - 1)
	var cz := clampi(int((p.z - _gmin.y) / CELL), 0, _gh - 1)
	for z in range(maxi(cz - 1, 0), mini(cz + 2, _gh)):
		for x in range(maxi(cx - 1, 0), mini(cx + 2, _gw)):
			var j := _head[z * _gw + x]
			while j >= 0:
				if j != i:
					var q := pos[j]
					var dx := p.x - q.x
					var dz := p.z - q.z
					var d2 := dx * dx + dz * dz
					if d2 < ps2 and d2 > 0.000001:
						var d := sqrt(d2)
						# Characters don't yield to crowd agents, so take the whole correction then.
						var k := (personal_space - d) / d * (1.0 if materialized[j] else 0.5)
						p.x += dx * k
						p.z += dz * k
				j = _next[j]
	return p


## Hand the agents nearest the focus (and where it is heading) to real characters, and give
## characters whose agents dropped out of that set back to the pool once they're calm.
func _decide(fp: Vector3) -> void:
	if fp.x == INF:
		return
	var pred := fp
	if focus is CharacterBody3D:
		pred += (focus as CharacterBody3D).velocity * 0.5
	var r := query_radius + fp.distance_to(pred)
	var cand: Array[Vector2] = []
	var c0 := _cell_of(fp.x - r, fp.z - r)
	var c1 := _cell_of(fp.x + r, fp.z + r)
	for z in range(c0 / _gw, c1 / _gw + 1):
		for x in range(c0 % _gw, c1 % _gw + 1):
			var j := _head[z * _gw + x]
			while j >= 0:
				var q := pos[j]
				var d := minf(Vector2(q.x - fp.x, q.z - fp.z).length(), Vector2(q.x - pred.x, q.z - pred.z).length())
				if d < query_radius:
					cand.append(Vector2(d, j))
				j = _next[j]
	cand.sort()
	var want := {}
	for k in mini(cand.size(), pool_size):
		want[int(cand[k].y)] = true
	for c: PlayerController in _agent_of.keys():
		var a: int = _agent_of[c]
		if not want.has(a) and _calm(c):
			_dematerialize(a, c)
	for k in mini(cand.size(), pool_size):
		var a := int(cand[k].y)
		if not materialized[a] and not _free.is_empty():
			_materialize(a)


func _calm(c: PlayerController) -> bool:
	return c.state in [PlayerController.State.IDLE, PlayerController.State.WALK] \
		and not c.lod_locked_full() and c.is_on_floor()


func _materialize(a: int) -> void:
	var c: PlayerController = _free.pop_back()
	c.process_mode = Node.PROCESS_MODE_INHERIT
	c.visible = true
	c.teleport(pos[a], yaw[a])
	c.velocity = Vector3(vel[a].x, 0.0, vel[a].y)
	c.lod_assigned = CharacterLOD.Tier.KINEMATIC
	c.skin.set_skin_color(skin_col[a])
	(c.get_node("Brain") as DummyBrain).start_wander(home[a], _rng.randi(),
		wdir[a] * CrowdVAT.STROLL_INPUT, maxf(wt[a], 0.01))
	materialized[a] = 1
	_agent_of[c] = a
	var buf := _bufs[_chunk_of[a]]
	var b := _slot[a] * FLOATS
	for k in [0, 2, 5, 8, 10]:
		buf[b + k] = 0.0   # zero scale hides the instance


func _dematerialize(a: int, c: PlayerController) -> void:
	pos[a] = c.global_position
	yaw[a] = c.facing_yaw
	vel[a] = Vector2(c.velocity.x, c.velocity.z)
	var brain := c.get_node("Brain") as DummyBrain
	wdir[a] = brain.wander_dir() / CrowdVAT.STROLL_INPUT
	wt[a] = brain.wander_time_left()
	_park(c)
	materialized[a] = 0
	_agent_of.erase(c)
	_free.append(c)
	_bufs[_chunk_of[a]][_slot[a] * FLOATS + 5] = 1.0


func _park(c: PlayerController) -> void:
	c.external_input = {}
	c.velocity = Vector3.ZERO
	c.process_mode = Node.PROCESS_MODE_DISABLED   # also removes its bodies from the physics server
	c.visible = false


# ---------------------------------------------------------------- stats

func materialized_count() -> int:
	return _agent_of.size()


func character_of(a: int) -> PlayerController:
	for c: PlayerController in _agent_of:
		if _agent_of[c] == a:
			return c
	return null


func active_characters() -> Array:
	return _agent_of.keys()
