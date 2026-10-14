class_name DebugHud
extends CanvasLayer
## On-screen state readout + controls help (F1).

@export var player: PlayerController

const HELP := """WASD / left stick  move     Shift / L3  run
Space / A  jump (hold for height)     Ctrl,C / B  crouch (while running: slide)
Q / X  forward roll (press just before landing to roll out of big falls)
Jump at a chest-high ledge: mantle | jump at a higher one: grab. Hanging: A/D shimmy, jump/W climb, crouch/S drop
LMB,J / Y  punch     K,V / RT  kick     hold RMB,L / LT  guard
E / RB  lift, drop, grab to push/pull     F / LB  throw
G / Y  toggle ragdoll     R / Back  reset     F2  physics bodies     Mouse / right stick  camera
Click to capture mouse, Esc to release, F1 hide help"""

var _label: Label
var _help: Label
var _hint: Label
var _event: Label
var _event_t := 99.0


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 5)
	add_child(_label)
	_help = Label.new()
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.offset_left = 16
	_help.offset_top = -176
	_help.text = HELP
	_help.add_theme_font_size_override("font_size", 15)
	_help.add_theme_color_override("font_outline_color", Color.BLACK)
	_help.add_theme_constant_override("outline_size", 4)
	add_child(_help)
	_hint = Label.new()
	_hint.anchor_left = 0.5
	_hint.anchor_right = 0.5
	_hint.anchor_top = 0.62
	_hint.offset_left = -200
	_hint.offset_right = 200
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_hint.add_theme_constant_override("outline_size", 6)
	add_child(_hint)
	_event = Label.new()
	_event.anchor_left = 0.5
	_event.anchor_right = 0.5
	_event.offset_left = -300
	_event.offset_right = 300
	_event.offset_top = 40
	_event.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_event.add_theme_font_size_override("font_size", 26)
	_event.add_theme_color_override("font_outline_color", Color.BLACK)
	_event.add_theme_constant_override("outline_size", 7)
	add_child(_event)


## Show a fading line whenever this character reacts to a hit.
func watch(character: PlayerController, label: String) -> void:
	character.combat.reacted.connect(func(kind: StringName, s: float):
		_event.text = "%s: %s  (%.1f)" % [label, String(kind).to_upper().replace("_", " "), s]
		_event_t = 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_help"):
		_help.visible = not _help.visible


func _process(_dt: float) -> void:
	if not player:
		return
	_hint.text = player.interact_hint()
	_event_t += _dt
	_event.modulate.a = clampf(1.5 - _event_t, 0.0, 1.0)
	_label.text = "State: %s%s\nSpeed: %.1f m/s   Vy: %.1f\nMuscle: %.2f\nLast landing: %.1f m/s   Last hit: %.0f\nFPS: %d" % [
		PlayerController.State.keys()[player.state], "  (guard)" if player.combat.guarding else "",
		player.horizontal_speed(), player.velocity.y,
		player.rig.muscle, player.last_impact, player.last_hit,
		Engine.get_frames_per_second(),
	]
