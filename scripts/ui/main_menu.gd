extends Control
## Title screen, world creation, and settings.
##
## The game previously booted straight into a run — no title, no way to choose a difficulty,
## no way to start a fresh world without wiping the save by hand, and no way to change the
## volume of the sound it did not yet have.
##
## One scene with swapped panels rather than three scenes. The panels share a background and
## a back button, none of them needs to exist independently, and scene transitions on a phone
## cost a frame hitch for no gain.

const RUN_SCENE := "res://scenes/run/run.tscn"

## Not named `Panel`: that shadows Godot's native Panel class and the parser rejects it
## outright. Same trap as naming a local variable `scale` inside a Control.
enum Screen { ROOT, CREATE, OPTIONS, CREDITS }

@onready var _panels := {
	Screen.ROOT: $Center/Root,
	Screen.CREATE: $Center/Create,
	Screen.OPTIONS: $Center/Options,
	Screen.CREDITS: $Center/Credits,
}

@onready var _continue_button: Button = $Center/Root/Rows/ContinueButton
@onready var _best: Label = $Center/Root/Rows/Best

@onready var _difficulty_rows: VBoxContainer = $Center/Create/Rows/Difficulties
@onready var _seed_field: LineEdit = $Center/Create/Rows/SeedRow/SeedField
@onready var _pick_site: CheckBox = $Center/Create/Rows/PickSite
@onready var _difficulty_blurb: Label = $Center/Create/Rows/Blurb

@onready var _sliders := {
	Audio.BUS_MASTER: $Center/Options/Rows/MasterRow/Slider,
	Audio.BUS_MUSIC: $Center/Options/Rows/MusicRow/Slider,
	Audio.BUS_SFX: $Center/Options/Rows/SfxRow/Slider,
}

## difficulty id -> its button, so the selection can be shown without rebuilding the list.
var _difficulty_buttons: Dictionary = {}
var _chosen: StringName = &""
var _panel_tween: Tween


func _ready() -> void:
	modulate.a = 0.0
	_build_difficulties()
	_build_options()
	_wire_navigation()

	_chosen = Meta.last_difficulty
	_refresh_difficulty_selection()
	_reroll_seed()

	# Continue is hidden rather than disabled when there is nothing to continue. A greyed
	# button on a title screen invites the player to wonder what they did wrong.
	_continue_button.visible = RunSave.has_save()
	_best.text = L10n.t(&"UI_BEST_RUN", [Meta.best_day, Meta.shards])

	_show(Screen.ROOT)
	create_tween().tween_property(self, "modulate:a", 1.0, 0.35)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


# --- Navigation ------------------------------------------------------------------------

func _wire_navigation() -> void:
	$Center/Root/Rows/ContinueButton.pressed.connect(_on_continue)
	$Center/Root/Rows/NewButton.pressed.connect(func() -> void: _show(Screen.CREATE))
	$Center/Root/Rows/OptionsButton.pressed.connect(func() -> void: _show(Screen.OPTIONS))
	$Center/Root/Rows/CreditsButton.pressed.connect(func() -> void: _show(Screen.CREDITS))
	$Center/Root/Rows/QuitButton.pressed.connect(func() -> void: get_tree().quit())

	$Center/Create/Rows/Buttons/BackButton.pressed.connect(func() -> void: _show(Screen.ROOT))
	$Center/Create/Rows/Buttons/BeginButton.pressed.connect(_on_begin)
	$Center/Create/Rows/SeedRow/RerollButton.pressed.connect(_reroll_seed)
	$Center/Options/Rows/BackButton.pressed.connect(_on_options_closed)
	$Center/Credits/Rows/BackButton.pressed.connect(func() -> void: _show(Screen.ROOT))


func _show(which: Screen) -> void:
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	for key in _panels:
		_panels[key].visible = key == which
	var target: Control = _panels[which]
	target.modulate.a = 0.0
	_panel_tween = create_tween()
	_panel_tween.tween_property(target, "modulate:a", 1.0, 0.18)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# --- World creation --------------------------------------------------------------------

func _build_difficulties() -> void:
	for def: DifficultyDef in Difficulties.all():
		var b := Button.new()
		b.text = tr(def.display_name)
		b.toggle_mode = true
		# 26, not 34. Four tiers at 34px was 136px of a 360px screen on its own, which is what
		# pushed the New World panel off the bottom on a device with safe-area insets.
		b.custom_minimum_size = Vector2(0, 24)
		b.add_theme_color_override("font_color", def.color)
		b.pressed.connect(_on_difficulty_chosen.bind(def.id))
		_difficulty_rows.add_child(b)
		_difficulty_buttons[def.id] = b


func _on_difficulty_chosen(id: StringName) -> void:
	_chosen = id
	_refresh_difficulty_selection()


func _refresh_difficulty_selection() -> void:
	# Fall back if the saved preference names a tier that no longer exists on disk.
	if not _difficulty_buttons.has(_chosen):
		_chosen = Difficulties.DEFAULT_ID
	for id in _difficulty_buttons:
		_difficulty_buttons[id].set_pressed_no_signal(id == _chosen)
	var def := Difficulties.get_difficulty(_chosen)
	# Show the payout multiplier alongside the description. The whole reason the hard tiers
	# pay more is so players pick them, and that only works if they can see it before
	# committing rather than discovering it on the summary card.
	_difficulty_blurb.text = L10n.t(&"DIFFICULTY_SHARD_MULT",
		[tr(def.description), "%.2f" % def.shard_mult]) if def != null else ""


func _reroll_seed() -> void:
	_seed_field.text = str(randi())


## Seeds are typed as text so they can be shared. Anything that is not a number is hashed
## instead of rejected, which means a player can name a world and get a stable one.
func _requested_seed() -> int:
	var raw := _seed_field.text.strip_edges()
	if raw.is_empty():
		return randi()
	if raw.is_valid_int():
		return raw.to_int()
	return int(hash(raw))


func _on_begin() -> void:
	# The only place a difficulty preference is actually expressed, so the only place that
	# writes it to the profile.
	Meta.set_last_difficulty(_chosen)
	NewRunRequest.set_request(_requested_seed(), _chosen, _pick_site.button_pressed)
	get_tree().change_scene_to_file(RUN_SCENE)


func _on_continue() -> void:
	# No request set: run.gd finds the save on disk and resumes it.
	get_tree().change_scene_to_file(RUN_SCENE)


# --- Options ---------------------------------------------------------------------------

func _build_options() -> void:
	for bus: StringName in _sliders:
		var slider: HSlider = _sliders[bus]
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = Audio.get_volume(bus)
		# Applied live rather than on close, so dragging a slider is audibly a preview.
		slider.value_changed.connect(func(v: float) -> void: Audio.set_volume(bus, v))


func _on_options_closed() -> void:
	Audio.save_settings()
	_show(Screen.ROOT)
