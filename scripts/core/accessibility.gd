extends CanvasLayer
## Persistent accessibility, onboarding and player-facing input preferences.
##
## This deliberately shares profile.cfg with Meta and Audio: these are preferences that
## outlive a run. Every writer load-merges before saving, so changing text size cannot erase
## shards and earning shards cannot silently reset remapped controls.

signal changed(kind: StringName)

const SECTION := "accessibility"
const CONTROLS_SECTION := "controls"
const TUTORIAL_SECTION := "tutorial"

## Touch dimensions are expressed in screen pixels. UI scenes use half-height
## controls because the 800x360 canvas is normally displayed at 2x or greater;
## world picking works directly in screen coordinates and uses the full value.
const MIN_TOUCH_TARGET_PX := 44.0
const MIN_UI_TARGET_PX := 22.0
const GESTURE_SLOP_PX := 12.0
const TAP_MAX_TIME := 0.35
const HOLD_DURATIONS: Array[float] = [0.25, 0.35, 0.5, 0.75]
const SCREEN_SHAKE_LEVELS: Array[float] = [0.0, 0.35, 0.7, 1.0]

enum Handedness { RIGHT, LEFT }
enum GraphicsMode { BATTERY, BALANCED, QUALITY }

const HANDEDNESS_NAMES: Array[StringName] = [
	&"OPTIONS_RIGHT_HANDED", &"OPTIONS_LEFT_HANDED",
]
const GRAPHICS_NAMES: Array[StringName] = [
	&"OPTIONS_GRAPHICS_BATTERY",
	&"OPTIONS_GRAPHICS_BALANCED",
	&"OPTIONS_GRAPHICS_QUALITY",
]

const PALETTE_NAMES: Array[StringName] = [
	&"ACCESS_PALETTE_DEFAULT",
	&"ACCESS_PALETTE_RED_GREEN",
	&"ACCESS_PALETTE_BLUE_YELLOW",
	&"ACCESS_PALETTE_HIGH_CONTRAST",
]
const TEXT_SCALES: Array[float] = [0.9, 1.0, 1.15, 1.3]

const ACTION_DEFAULTS := {
	&"game_pause": KEY_SPACE,
	&"game_speed": KEY_F,
	&"game_jobs": KEY_J,
	&"game_build": KEY_B,
	&"game_realm": KEY_M,
	&"game_cancel": KEY_ESCAPE,
}
const ACTION_LABELS := {
	&"game_pause": &"CONTROL_PAUSE",
	&"game_speed": &"CONTROL_SPEED",
	&"game_jobs": &"CONTROL_JOBS",
	&"game_build": &"CONTROL_BUILD",
	&"game_realm": &"CONTROL_REALM",
	&"game_cancel": &"CONTROL_CANCEL",
}

var palette_mode: int = 0
var text_scale: float = 1.0
var reduced_motion: bool = false
var haptics: bool = true
var tutorials_enabled: bool = true
var tutorial_seen: Array[StringName] = []
var handedness: Handedness = Handedness.RIGHT
var graphics_mode: GraphicsMode = GraphicsMode.BALANCED
var hold_duration: float = 0.35
var screen_shake_strength: float = 0.7
var high_visibility_targets: bool = false
var pause_while_managing: bool = false
var compact_status_display: bool = false
var diagnostics_export_opt_in: bool = false

var _filter: ColorRect
var _filter_material: ShaderMaterial


func _ready() -> void:
	layer = 127
	_build_filter()
	_ensure_actions()
	load_settings()
	process_mode = Node.PROCESS_MODE_ALWAYS


func _build_filter() -> void:
	_filter = ColorRect.new()
	_filter.name = "PaletteFilter"
	_filter.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_filter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_filter_material = ShaderMaterial.new()
	_filter_material.shader = load("res://assets/shaders/accessibility_filter.gdshader")
	_filter.material = _filter_material
	add_child(_filter)


func _ensure_actions() -> void:
	for action: StringName in ACTION_DEFAULTS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		if InputMap.action_get_events(action).is_empty():
			_set_action_key(action, int(ACTION_DEFAULTS[action]))


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(Meta.SAVE_PATH) == OK:
		palette_mode = clampi(int(cfg.get_value(SECTION, "palette_mode", 0)),
			0, PALETTE_NAMES.size() - 1)
		text_scale = clampf(float(cfg.get_value(SECTION, "text_scale", 1.0)), 0.9, 1.3)
		reduced_motion = bool(cfg.get_value(SECTION, "reduced_motion", false))
		haptics = bool(cfg.get_value(SECTION, "haptics", true))
		tutorials_enabled = bool(cfg.get_value(TUTORIAL_SECTION, "enabled", true))
		tutorial_seen.assign(cfg.get_value(TUTORIAL_SECTION, "seen", []))
		handedness = clampi(int(cfg.get_value(SECTION, "handedness", Handedness.RIGHT)),
			Handedness.RIGHT, Handedness.LEFT)
		graphics_mode = clampi(int(cfg.get_value(SECTION, "graphics_mode",
			GraphicsMode.BALANCED)), GraphicsMode.BATTERY, GraphicsMode.QUALITY)
		hold_duration = HOLD_DURATIONS[_nearest_hold_duration(
			float(cfg.get_value(SECTION, "hold_duration", 0.35)))]
		screen_shake_strength = SCREEN_SHAKE_LEVELS[_nearest_value(
			SCREEN_SHAKE_LEVELS, float(cfg.get_value(SECTION, "screen_shake_strength", 0.7)))]
		high_visibility_targets = bool(cfg.get_value(SECTION, "high_visibility_targets", false))
		pause_while_managing = bool(cfg.get_value(SECTION, "pause_while_managing", false))
		compact_status_display = bool(cfg.get_value(SECTION, "compact_status_display", false))
		diagnostics_export_opt_in = bool(cfg.get_value(
			SECTION, "diagnostics_export_opt_in", false))
		for action: StringName in ACTION_DEFAULTS:
			var keycode := int(cfg.get_value(CONTROLS_SECTION, String(action),
				int(ACTION_DEFAULTS[action])))
			_set_action_key(action, keycode)
	_apply_filter()
	_apply_graphics_mode()
	call_deferred("_apply_ui_scale")


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(Meta.SAVE_PATH)
	cfg.set_value(SECTION, "palette_mode", palette_mode)
	cfg.set_value(SECTION, "text_scale", text_scale)
	cfg.set_value(SECTION, "reduced_motion", reduced_motion)
	cfg.set_value(SECTION, "haptics", haptics)
	cfg.set_value(SECTION, "handedness", int(handedness))
	cfg.set_value(SECTION, "graphics_mode", int(graphics_mode))
	cfg.set_value(SECTION, "hold_duration", hold_duration)
	cfg.set_value(SECTION, "screen_shake_strength", screen_shake_strength)
	cfg.set_value(SECTION, "high_visibility_targets", high_visibility_targets)
	cfg.set_value(SECTION, "pause_while_managing", pause_while_managing)
	cfg.set_value(SECTION, "compact_status_display", compact_status_display)
	cfg.set_value(SECTION, "diagnostics_export_opt_in", diagnostics_export_opt_in)
	cfg.set_value(TUTORIAL_SECTION, "enabled", tutorials_enabled)
	cfg.set_value(TUTORIAL_SECTION, "seen", tutorial_seen)
	for action: StringName in ACTION_DEFAULTS:
		cfg.set_value(CONTROLS_SECTION, String(action), action_key(action))
	cfg.save(Meta.SAVE_PATH)


func set_palette_mode(value: int) -> void:
	palette_mode = clampi(value, 0, PALETTE_NAMES.size() - 1)
	_apply_filter()
	changed.emit(&"palette")


func set_text_scale(value: float) -> void:
	text_scale = TEXT_SCALES[_nearest_text_scale(value)]
	_apply_ui_scale()
	changed.emit(&"text")


func set_reduced_motion(value: bool) -> void:
	reduced_motion = value
	changed.emit(&"motion")


func set_haptics(value: bool) -> void:
	haptics = value
	changed.emit(&"haptics")


func set_handedness(value: int) -> void:
	handedness = clampi(value, Handedness.RIGHT, Handedness.LEFT)
	changed.emit(&"handedness")


func set_graphics_mode(value: int) -> void:
	graphics_mode = clampi(value, GraphicsMode.BATTERY, GraphicsMode.QUALITY)
	_apply_graphics_mode()
	changed.emit(&"graphics")


func set_hold_duration(value: float) -> void:
	hold_duration = HOLD_DURATIONS[_nearest_hold_duration(value)]
	changed.emit(&"hold")


func set_screen_shake_strength(value: float) -> void:
	screen_shake_strength = SCREEN_SHAKE_LEVELS[_nearest_value(SCREEN_SHAKE_LEVELS, value)]
	changed.emit(&"shake")


func set_high_visibility_targets(value: bool) -> void:
	high_visibility_targets = value
	changed.emit(&"targets")


func set_pause_while_managing(value: bool) -> void:
	pause_while_managing = value
	changed.emit(&"management_pause")


func set_compact_status_display(value: bool) -> void:
	compact_status_display = value
	changed.emit(&"status_display")


func set_diagnostics_export_opt_in(value: bool) -> void:
	diagnostics_export_opt_in = value
	changed.emit(&"diagnostics")


func particle_density() -> float:
	match graphics_mode:
		GraphicsMode.BATTERY:
			return 0.45
		GraphicsMode.QUALITY:
			return 1.0
		_:
			return 0.72


func animation_interval() -> float:
	return 1.0 / 20.0 if graphics_mode == GraphicsMode.BATTERY else 0.0


func set_tutorials_enabled(value: bool) -> void:
	tutorials_enabled = value
	changed.emit(&"tutorial")


func reset_tutorials() -> void:
	tutorial_seen.clear()
	changed.emit(&"tutorial")


func tutorial_was_seen(id: StringName) -> bool:
	return id in tutorial_seen


func mark_tutorial_seen(id: StringName) -> void:
	if id in tutorial_seen:
		return
	tutorial_seen.append(id)
	save_settings()


func motion_duration(seconds: float) -> float:
	return 0.001 if reduced_motion else seconds


func shake_scale() -> float:
	return 0.0 if reduced_motion else screen_shake_strength


func pulse(duration_ms: int = 18, amplitude: float = 0.45) -> void:
	if haptics and OS.has_feature("mobile"):
		Input.vibrate_handheld(duration_ms, amplitude)


func action_key(action: StringName) -> int:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			var key := event as InputEventKey
			return int(key.physical_keycode if key.physical_keycode != 0 else key.keycode)
	return int(ACTION_DEFAULTS.get(action, KEY_NONE))


func remap_action(action: StringName, keycode: int) -> void:
	if not ACTION_DEFAULTS.has(action) or keycode == KEY_NONE:
		return
	_set_action_key(action, keycode)
	save_settings()
	changed.emit(&"controls")


func reset_controls() -> void:
	for action: StringName in ACTION_DEFAULTS:
		_set_action_key(action, int(ACTION_DEFAULTS[action]))
	save_settings()
	changed.emit(&"controls")


func _set_action_key(action: StringName, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode as Key
	InputMap.action_add_event(action, event)


func _nearest_text_scale(value: float) -> int:
	var best := 0
	var distance := INF
	for i in TEXT_SCALES.size():
		var candidate := absf(TEXT_SCALES[i] - value)
		if candidate < distance:
			distance = candidate
			best = i
	return best


func _nearest_hold_duration(value: float) -> int:
	var best := 0
	var distance := INF
	for i in HOLD_DURATIONS.size():
		var candidate := absf(HOLD_DURATIONS[i] - value)
		if candidate < distance:
			distance = candidate
			best = i
	return best


func _nearest_value(values: Array[float], value: float) -> int:
	var best := 0
	var distance := INF
	for i in values.size():
		var candidate := absf(values[i] - value)
		if candidate < distance:
			distance = candidate
			best = i
	return best


func _apply_filter() -> void:
	if _filter_material == null:
		return
	_filter.visible = palette_mode != 0
	_filter_material.set_shader_parameter("palette_mode", palette_mode)


func _apply_graphics_mode() -> void:
	Engine.max_fps = 30 if graphics_mode == GraphicsMode.BATTERY else 60


func _apply_ui_scale() -> void:
	var ui := get_node_or_null("/root/Ui")
	if ui != null and ui.has_method("set_text_scale"):
		ui.set_text_scale(text_scale)
