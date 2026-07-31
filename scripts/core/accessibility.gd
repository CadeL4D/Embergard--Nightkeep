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
		for action: StringName in ACTION_DEFAULTS:
			var keycode := int(cfg.get_value(CONTROLS_SECTION, String(action),
				int(ACTION_DEFAULTS[action])))
			_set_action_key(action, keycode)
	_apply_filter()
	call_deferred("_apply_ui_scale")


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(Meta.SAVE_PATH)
	cfg.set_value(SECTION, "palette_mode", palette_mode)
	cfg.set_value(SECTION, "text_scale", text_scale)
	cfg.set_value(SECTION, "reduced_motion", reduced_motion)
	cfg.set_value(SECTION, "haptics", haptics)
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


func _apply_filter() -> void:
	if _filter_material == null:
		return
	_filter.visible = palette_mode != 0
	_filter_material.set_shader_parameter("palette_mode", palette_mode)


func _apply_ui_scale() -> void:
	var ui := get_node_or_null("/root/Ui")
	if ui != null and ui.has_method("set_text_scale"):
		ui.set_text_scale(text_scale)
