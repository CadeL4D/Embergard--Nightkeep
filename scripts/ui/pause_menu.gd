extends CanvasLayer
## In-run navigation and the same settings surface used by the title screen.

@onready var _root_view: VBoxContainer = $Center/Card/Views/Root
@onready var _settings_view: VBoxContainer = $Center/Card/Views/Settings
@onready var _settings: SettingsPanel = $Center/Card/Views/Settings/SettingsPanel
@onready var _resume: Button = $Center/Card/Views/Root/Resume

var _was_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	$Center/Card/Views/Root/Resume.pressed.connect(close)
	$Center/Card/Views/Root/Settings.pressed.connect(_show_settings)
	$Center/Card/Views/Root/MainMenu.pressed.connect(_save_and_main_menu)
	$Center/Card/Views/Settings/Back.pressed.connect(_show_root)


func open() -> void:
	if visible:
		return
	_was_paused = Sim.paused
	Sim.set_paused(true)
	visible = true
	_show_root()
	_resume.grab_focus()


func close() -> void:
	if not visible:
		return
	_settings.save()
	visible = false
	if not _was_paused:
		Sim.set_paused(false)


func _show_root() -> void:
	_root_view.visible = true
	_settings_view.visible = false


func _show_settings() -> void:
	_root_view.visible = false
	_settings_view.visible = true


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
			_show_root()
		else:
			close()
		get_viewport().set_input_as_handled()
