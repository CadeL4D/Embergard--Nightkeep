extends CanvasLayer
## In-run navigation and the same settings surface used by the title screen.

const CODEX_ENTRIES := preload("res://scripts/ui/codex_entries.gd")

@onready var _root_view: VBoxContainer = $Center/Card/Views/Root
@onready var _settings_view: VBoxContainer = $Center/Card/Views/Settings
@onready var _settings: SettingsPanel = $Center/Card/Views/Settings/SettingsPanel
@onready var _resume: Button = $Center/Card/Views/Root/Resume
@onready var _codex_view: VBoxContainer = $Center/Card/Views/Codex
@onready var _codex_search: LineEdit = $Center/Card/Views/Codex/Search
@onready var _codex_topics: ItemList = $Center/Card/Views/Codex/Content/Topics
@onready var _codex_body: RichTextLabel = $Center/Card/Views/Codex/Content/Body

var _codex_rows: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	$Center/Card/Views/Root/Resume.pressed.connect(close)
	$Center/Card/Views/Root/Settings.pressed.connect(_show_settings)
	$Center/Card/Views/Root/Codex.pressed.connect(_show_codex)
	$Center/Card/Views/Root/MainMenu.pressed.connect(_save_and_main_menu)
	$Center/Card/Views/Settings/Back.pressed.connect(_save_settings_and_show_root)
	$Center/Card/Views/Codex/Back.pressed.connect(_show_root)
	_codex_search.text_changed.connect(_filter_codex)
	_codex_topics.item_selected.connect(_select_codex)


func open() -> void:
	if visible:
		return
	Sim.set_paused(true)
	visible = true
	_show_root()
	_resume.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	# This button is labelled Resume, so it must always resume. Preserving a pause that
	# happened before the menu opened made Continue appear to do nothing.
	Sim.set_paused(false)


func _show_root() -> void:
	_root_view.visible = true
	_settings_view.visible = false
	_codex_view.visible = false


func _show_settings() -> void:
	_root_view.visible = false
	_settings_view.visible = true
	_codex_view.visible = false


func _save_settings_and_show_root() -> void:
	# Disk writes belong to the explicit Settings Back action. Resume is the most
	# common button in this menu and must return to play without a synchronous
	# ConfigFile save on its input frame.
	_settings.save()
	_show_root()


func _show_codex(topic: StringName = &"") -> void:
	_root_view.visible = false
	_settings_view.visible = false
	_codex_view.visible = true
	_filter_codex(_codex_search.text)
	if topic != &"":
		for i in _codex_rows.size():
			if StringName(_codex_rows[i].get("id", &"")) == topic:
				_codex_topics.select(i)
				_select_codex(i)
				break
	_codex_search.grab_focus()


func open_codex_for_warning(reason: String) -> void:
	if not visible:
		open()
	_show_codex(CODEX_ENTRIES.for_warning(reason))


func _filter_codex(query: String) -> void:
	_codex_rows = CODEX_ENTRIES.search(query)
	_codex_topics.clear()
	for row in _codex_rows:
		_codex_topics.add_item(tr(row["title"]))
	if not _codex_rows.is_empty():
		_codex_topics.select(0)
		_select_codex(0)
	else:
		_codex_body.text = tr(&"CODEX_NO_RESULTS")


func _select_codex(index: int) -> void:
	if index < 0 or index >= _codex_rows.size():
		return
	var row := _codex_rows[index]
	var overlay := StringName(row.get("overlay", &""))
	_codex_body.text = "[font_size=14][color=#ffd88a]%s[/color][/font_size]\n\n%s%s" % [
		tr(row["title"]), tr(row["body"]),
		"\n\n[color=#9fb5c8]%s[/color]" % L10n.t(&"CODEX_OVERLAY_LINK", [String(overlay)])
			if overlay != &"" else "",
	]


func _save_and_main_menu() -> void:
	_settings.save()
	if Sim.running:
		RunSave.save()
	visible = false
	# Sim is an autoload, so leaving it paused would carry that state through the
	# scene transition until a new run starts.
	Sim.set_paused(false)
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"game_cancel") or event.is_action_pressed(&"game_pause"):
		if _settings_view.visible:
			_save_settings_and_show_root()
		elif _codex_view.visible:
			_show_root()
		else:
			close()
		get_viewport().set_input_as_handled()
