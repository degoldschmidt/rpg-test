class_name DebugHud
extends CanvasLayer
## On-screen state readout + controls help (F1).

@export var player: PlayerController

const HELP := """WASD / left stick  move     Shift / L3  run
Space / A  jump (hold for height)     Ctrl,C / B  crouch (while running: slide)
Q / X  forward roll (press just before landing to roll out of big falls)
Jump at a chest-high ledge: mantle | jump at a higher one: grab. Hanging: A/D shimmy, jump/W climb, crouch/S drop
G / Y  toggle ragdoll     R / Back  reset     Mouse / right stick  camera
Click to capture mouse, Esc to release, F1 hide help"""

var _label: Label
var _help: Label


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
	_help.offset_top = -132
	_help.text = HELP
	_help.add_theme_font_size_override("font_size", 15)
	_help.add_theme_color_override("font_outline_color", Color.BLACK)
	_help.add_theme_constant_override("outline_size", 4)
	add_child(_help)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_help"):
		_help.visible = not _help.visible


func _process(_dt: float) -> void:
	if not player:
		return
	_label.text = "State: %s\nSpeed: %.1f m/s   Vy: %.1f\nMuscle: %.2f\nLast landing: %.1f m/s   Last hit: %.0f\nFPS: %d" % [
		PlayerController.State.keys()[player.state],
		player.horizontal_speed(), player.velocity.y,
		player.rig.muscle, player.last_impact, player.last_hit,
		Engine.get_frames_per_second(),
	]
