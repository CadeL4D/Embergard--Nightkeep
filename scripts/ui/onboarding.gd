extends CanvasLayer
## Contextual, shown-once onboarding. Cards are queued by real game events rather than a
## front-loaded tutorial level, and may be skipped individually or disabled permanently.

const CARDS := {
	&"welcome": [&"TUTORIAL_WELCOME_TITLE", &"TUTORIAL_WELCOME_BODY"],
	&"ember": [&"TUTORIAL_EMBER_TITLE", &"TUTORIAL_EMBER_BODY"],
	&"jobs": [&"TUTORIAL_JOBS_TITLE", &"TUTORIAL_JOBS_BODY"],
	&"building": [&"TUTORIAL_BUILD_TITLE", &"TUTORIAL_BUILD_BODY"],
	&"dusk": [&"TUTORIAL_DUSK_TITLE", &"TUTORIAL_DUSK_BODY"],
	&"powers": [&"TUTORIAL_POWERS_TITLE", &"TUTORIAL_POWERS_BODY"],
	&"production": [&"TUTORIAL_PRODUCTION_TITLE", &"TUTORIAL_PRODUCTION_BODY"],
	&"colonies": [&"TUTORIAL_COLONIES_TITLE", &"TUTORIAL_COLONIES_BODY"],
	&"blight": [&"TUTORIAL_BLIGHT_TITLE", &"TUTORIAL_BLIGHT_BODY"],
}

@onready var _card: PanelContainer = $Dim/Center/Card
@onready var _title: Label = $Dim/Center/Card/Rows/Title
@onready var _body: Label = $Dim/Center/Card/Rows/Body
@onready var _count: Label = $Dim/Center/Card/Rows/Footer/Count

var _queue: Array[StringName] = []
var _current: StringName = &""
var _was_paused: bool = false
var _show_scheduled: bool = false


func _ready() -> void:
	$Dim.visible = false
	if DisplayServer.get_name() == "headless":
		return
	$Dim/Center/Card/Rows/Buttons/Continue.pressed.connect(_dismiss)
	$Dim/Center/Card/Rows/Buttons/SkipAll.pressed.connect(_skip_all)
	Events.run_started.connect(_on_run_started)
	Events.placement_mode_changed.connect(func(active: bool) -> void:
		if active:
			show_once(&"building")
	)
	Events.phase_changed.connect(func(phase: int, _duration: float) -> void:
		if phase == Sim.Phase.DUSK:
			show_once(&"dusk")
	)
	Events.power_cast.connect(func(_id: StringName, _pos: Vector2) -> void:
		show_once(&"powers")
	)
	Events.building_completed.connect(_on_building_completed)
	Events.realm_changed.connect(_on_realm_changed)
	Events.blight_changed.connect(func(_cell: int, blighted: bool) -> void:
		if blighted and Sim.day > 1:
			show_once(&"blight")
	)


func _on_run_started(_seed: int) -> void:
	show_once(&"welcome")
	show_once(&"ember")
	show_once(&"jobs")


func _on_building_completed(building: Node) -> void:
	var building_def: BuildingDef = building.get("def")
	if building_def != null and (building_def.worker_slots > 0 or building_def.tier >= 2):
		show_once(&"production")


func _on_realm_changed() -> void:
	if Realm.colonies.size() > 1:
		show_once(&"colonies")


func show_once(id: StringName) -> void:
	if not Accessibility.tutorials_enabled or not CARDS.has(id) \
			or Accessibility.tutorial_was_seen(id) or id in _queue or id == _current:
		return
	_queue.append(id)
	if _current == &"" and not _show_scheduled:
		_show_scheduled = true
		call_deferred("_show_next")


func _show_next() -> void:
	_show_scheduled = false
	if _queue.is_empty():
		_current = &""
		$Dim.visible = false
		Sim.set_paused(_was_paused)
		return
	_current = _queue.pop_front()
	var copy: Array = CARDS[_current]
	_title.text = tr(copy[0])
	_body.text = tr(copy[1])
	_count.text = L10n.t(&"TUTORIAL_COUNT", [
		Accessibility.tutorial_seen.size() + 1, CARDS.size()])
	_was_paused = Sim.paused
	Sim.set_paused(true)
	$Dim.visible = true
	_card.modulate.a = 0.0
	_card.scale = Vector2(0.97, 0.97)
	_card.pivot_offset = _card.size * 0.5
	var reveal := create_tween().set_parallel(true)
	var duration := Accessibility.motion_duration(0.2)
	reveal.tween_property(_card, "modulate:a", 1.0, duration)
	reveal.tween_property(_card, "scale", Vector2.ONE, duration)


func _dismiss() -> void:
	if _current != &"":
		Accessibility.mark_tutorial_seen(_current)
	_current = &""
	_show_next()


func _skip_all() -> void:
	Accessibility.set_tutorials_enabled(false)
	Accessibility.save_settings()
	_queue.clear()
	_current = &""
	$Dim.visible = false
	Sim.set_paused(_was_paused)
