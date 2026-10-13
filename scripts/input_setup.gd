class_name InputSetup
## Registers the prototype's input actions at runtime (keyboard + gamepad).

const LAYER_WORLD := 1
const LAYER_PROXY := 2
const LAYER_PUPPET := 4
const LAYER_PROPS := 8
const LAYER_HAZARDS := 16


static func ensure_actions() -> void:
	_key("move_forward", [KEY_W, KEY_UP])
	_key("move_back", [KEY_S, KEY_DOWN])
	_key("move_left", [KEY_A, KEY_LEFT])
	_key("move_right", [KEY_D, KEY_RIGHT])
	_key("jump", [KEY_SPACE])
	_key("crouch", [KEY_CTRL, KEY_C])
	_key("run", [KEY_SHIFT])
	_key("roll", [KEY_Q])
	_key("toggle_ragdoll", [KEY_G])
	_key("reset_player", [KEY_R])
	_key("toggle_help", [KEY_F1])

	_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_axis("cam_left", JOY_AXIS_RIGHT_X, -1.0)
	_axis("cam_right", JOY_AXIS_RIGHT_X, 1.0)
	_axis("cam_up", JOY_AXIS_RIGHT_Y, -1.0)
	_axis("cam_down", JOY_AXIS_RIGHT_Y, 1.0)
	_axis("run", JOY_AXIS_TRIGGER_LEFT, 1.0)
	_button("jump", JOY_BUTTON_A)
	_button("roll", JOY_BUTTON_X)
	_button("crouch", JOY_BUTTON_B)
	_button("run", JOY_BUTTON_LEFT_STICK)
	_button("toggle_ragdoll", JOY_BUTTON_Y)
	_button("reset_player", JOY_BUTTON_BACK)


static func _add(action: StringName) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)


static func _key(action: StringName, keys: Array) -> void:
	_add(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


static func _axis(action: StringName, axis: JoyAxis, value: float) -> void:
	_add(action)
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)


static func _button(action: StringName, button: JoyButton) -> void:
	_add(action)
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)
