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
enum Screen { ROOT, CREATE, OPTIONS, HISTORY, CREDITS }

@onready var _panels := {
	Screen.ROOT: $Center/Root,
	Screen.CREATE: $Center/Create,
	Screen.OPTIONS: $Center/Options,
	Screen.HISTORY: $Center/History,
	Screen.CREDITS: $Center/Credits,
}

@onready var _continue_button: Button = $Center/Root/Rows/ContinueButton
@onready var _best: Label = $Center/Root/Rows/Best

@onready var _difficulty_rows: GridContainer = $Center/Create/Rows/Difficulties
@onready var _seed_field: LineEdit = $Center/Create/Rows/SeedRow/SeedField
@onready var _pick_site: CheckBox = $Center/Create/Rows/PickSite
@onready var _difficulty_blurb: Label = $Center/Create/Rows/Blurb
@onready var _doctrine_options: Array[OptionButton] = [
	$Center/Create/Rows/DoctrineRow/Doctrine1,
	$Center/Create/Rows/DoctrineRow/Doctrine2,
	$Center/Create/Rows/DoctrineRow/Doctrine3,
]

@onready var _settings_panel: SettingsPanel = $Center/Options/Rows/Settings
@onready var _history_lifetime: Label = $Center/History/Rows/Lifetime
@onready var _history_achievements: Label = $Center/History/Rows/Achievements
@onready var _history_records: VBoxContainer = \
	$Center/History/Rows/Scroll/Records

## difficulty id -> its button, so the selection can be shown without rebuilding the list.
var _difficulty_buttons: Dictionary = {}
var _chosen: StringName = &""
var _chosen_doctrines: Array[StringName] = []
var _panel_tween: Tween


func _ready() -> void:
	modulate.a = 0.0
	_build_difficulties()
	_build_doctrines()
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
	create_tween().tween_property(self, "modulate:a", 1.0,
		Accessibility.motion_duration(0.35))\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


# --- Navigation ------------------------------------------------------------------------

func _wire_navigation() -> void:
	$Center/Root/Rows/ContinueButton.pressed.connect(_on_continue)
	$Center/Root/Rows/NewButton.pressed.connect(func() -> void: _show(Screen.CREATE))
	$Center/Root/Rows/OptionsButton.pressed.connect(func() -> void: _show(Screen.OPTIONS))
	$Center/Root/Rows/HistoryButton.pressed.connect(func() -> void: _show(Screen.HISTORY))
	$Center/Root/Rows/CreditsButton.pressed.connect(func() -> void: _show(Screen.CREDITS))
	$Center/Root/Rows/QuitButton.pressed.connect(func() -> void: get_tree().quit())

	$Center/Create/Rows/Buttons/BackButton.pressed.connect(func() -> void: _show(Screen.ROOT))
	$Center/Create/Rows/Buttons/BeginButton.pressed.connect(_on_begin)
	$Center/Create/Rows/SeedRow/RerollButton.pressed.connect(_reroll_seed)
	$Center/Options/Rows/BackButton.pressed.connect(_on_options_closed)
	$Center/History/Rows/BackButton.pressed.connect(func() -> void: _show(Screen.ROOT))
	$Center/Credits/Rows/BackButton.pressed.connect(func() -> void: _show(Screen.ROOT))


func _show(which: Screen) -> void:
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	for key in _panels:
		_panels[key].visible = key == which
	var target: Control = _panels[which]
	if which == Screen.HISTORY:
		_refresh_history()
	target.modulate.a = 0.0
	_panel_tween = create_tween()
	_panel_tween.tween_property(target, "modulate:a", 1.0,
		Accessibility.motion_duration(0.18))\
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


func _build_doctrines() -> void:
	_chosen_doctrines = Doctrines.sanitize(Meta.equipped_doctrines)
	while _chosen_doctrines.size() < _doctrine_options.size():
		_chosen_doctrines.append(&"")
	for slot in _doctrine_options.size():
		var option := _doctrine_options[slot]
		option.clear()
		option.add_item(tr(&"UI_NONE"))
		option.set_item_metadata(0, &"")
		for doctrine in Doctrines.available():
			option.add_item(doctrine.display_name)
			option.set_item_metadata(option.item_count - 1, doctrine.id)
		var desired := _chosen_doctrines[slot] if slot < _chosen_doctrines.size() else &""
		for item in option.item_count:
			if StringName(option.get_item_metadata(item)) == desired:
				option.select(item)
				break
		option.item_selected.connect(_on_doctrine_chosen.bind(slot))


func _on_doctrine_chosen(item: int, slot: int) -> void:
	var selected := StringName(_doctrine_options[slot].get_item_metadata(item))
	while _chosen_doctrines.size() < _doctrine_options.size():
		_chosen_doctrines.append(&"")
	if selected != &"":
		for other in _doctrine_options.size():
			if other != slot and _chosen_doctrines[other] == selected:
				_chosen_doctrines[other] = &""
				_doctrine_options[other].select(0)
	_chosen_doctrines[slot] = selected
	var compact: Array[StringName] = []
	for id in _chosen_doctrines:
		if id != &"":
			compact.append(id)
	Meta.set_equipped_doctrines(compact)
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
	if not _chosen_doctrines.is_empty():
		var names := PackedStringArray()
		for id in _chosen_doctrines:
			var doctrine := Doctrines.get_doctrine(id) if id != &"" else null
			if doctrine != null:
				names.append(doctrine.display_name)
		_difficulty_blurb.text += "\n" + ", ".join(names)


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
	NewRunRequest.set_request(_requested_seed(), _chosen, _pick_site.button_pressed,
		_chosen_doctrines)
	get_tree().change_scene_to_file(RUN_SCENE)


func _on_continue() -> void:
	# No request set: run.gd finds the save on disk and resumes it.
	get_tree().change_scene_to_file(RUN_SCENE)


# --- Options ---------------------------------------------------------------------------

func _build_options() -> void:
	pass


func _on_options_closed() -> void:
	_settings_panel.save()
	_show(Screen.ROOT)


# --- Run history -----------------------------------------------------------------------

func _refresh_history() -> void:
	var stats := Meta.lifetime_stats
	_history_lifetime.text = L10n.t(&"HISTORY_LIFETIME", [
		Meta.runs_played,
		int(stats.get("days", 0)),
		int(stats.get("monsters", 0)),
		int(stats.get("buildings", 0)),
	])
	var achievement_names := PackedStringArray()
	for id: StringName in Meta.achievements:
		achievement_names.append(tr(StringName("ACHIEVEMENT_" + String(id).to_upper())))
	_history_achievements.text = L10n.t(&"HISTORY_ACHIEVEMENTS", [
		Meta.achievements.size(), Meta.ACHIEVEMENT_TOTAL,
		", ".join(achievement_names) if not achievement_names.is_empty() else tr(&"HISTORY_NONE"),
	])
	_history_achievements.text += "\n" + L10n.t(&"HISTORY_CHRONICLE_GOALS", [
		Meta.chronicle_completed.size(), Chronicle.all().size(), Doctrines.available().size(),
		Doctrines.all().size()])
	for child in _history_records.get_children():
		_history_records.remove_child(child)
		child.queue_free()
	if Meta.run_history.is_empty():
		var empty := Label.new()
		empty.text = tr(&"HISTORY_EMPTY")
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_history_records.add_child(empty)
		return
	for record: Dictionary in Meta.run_history:
		_history_records.add_child(_history_row(record))


func _history_row(record: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	var copy := VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = L10n.t(&"HISTORY_RUN_TITLE", [
		int(record.get("day", 0)),
		tr(StringName("DIFFICULTY_" + String(record.get("difficulty", "harried")).to_upper())),
		tr(&"HISTORY_COMPLETE" if bool(record.get("realm_completed", false)) else
			&"HISTORY_ASCENDED" if bool(record.get("ascended", false)) else &"HISTORY_FALLEN"),
	])
	title.add_theme_color_override("font_color", UiPalette.ACCENT_PALE)
	var detail := Label.new()
	detail.text = L10n.t(&"HISTORY_RUN_DETAIL", [
		int(record.get("colonies", 1)), int(record.get("population", 0)),
		int(record.get("monsters", 0)), int(record.get("shards", 0)),
	])
	detail.add_theme_color_override("font_color", UiPalette.TEXT_DIM)
	copy.add_child(title)
	copy.add_child(detail)
	var seed_button := Button.new()
	seed_button.custom_minimum_size = Vector2(88, 30)
	seed_button.text = L10n.t(&"HISTORY_COPY_SEED", [int(record.get("seed", 0))])
	seed_button.tooltip_text = tr(&"HISTORY_COPY_HELP")
	seed_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(str(record.get("seed", 0)))
		seed_button.text = tr(&"HISTORY_COPIED")
	)
	row.add_child(copy)
	row.add_child(seed_button)
	return panel
