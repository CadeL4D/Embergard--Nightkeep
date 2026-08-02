extends CanvasLayer
## A single focused decision card. Choices are stacked vertically so they never overlap.

@onready var _dim: Control = $Dim
@onready var _card: PanelContainer = $Dim/Center/Card
@onready var _title: Label = $Dim/Center/Card/Rows/Title
@onready var _body: Label = $Dim/Center/Card/Rows/Body
@onready var _choices: VBoxContainer = $Dim/Center/Card/Rows/Choices

var _was_paused: bool = false


func _ready() -> void:
	_dim.visible = false
	# Headless tests deliberately auto-resolve storyteller events. Connecting the visual card
	# there would pause the clock for a button press no screen can ever provide.
	if DisplayServer.get_name() == "headless":
		return
	Events.storyteller_event.connect(_show_event)


func _show_event(_event_id: StringName, payload: Dictionary) -> void:
	_title.text = String(payload.get("title", tr(&"STORY_EVENT")))
	_body.text = String(payload.get("body", ""))
	for child in _choices.get_children():
		child.queue_free()
	for row: Dictionary in payload.get("choices", []):
		var button := Button.new()
		button.custom_minimum_size = Vector2(0.0, 48.0)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var marker := tr(&"STORY_RECOMMENDED") + " · " if bool(row.get("recommended", false)) else ""
		button.text = "%s%s\n%s%s" % [
			marker,
			String(row.get("label", "")),
			String(row.get("detail", "")),
			_cost_text(row),
		]
		button.disabled = not bool(row.get("enabled", false))
		var choice_id := StringName(row.get("id", &""))
		button.pressed.connect(func() -> void: _choose(choice_id))
		_choices.add_child(button)
	_was_paused = Sim.paused
	Sim.set_paused(true)
	_dim.visible = true
	_card.modulate.a = 0.0
	_card.scale = Vector2(0.975, 0.975)
	_card.pivot_offset = _card.size * 0.5
	var reveal := create_tween().set_parallel(true)
	var duration := Accessibility.motion_duration(0.18)
	reveal.tween_property(_card, "modulate:a", 1.0, duration)
	reveal.tween_property(_card, "scale", Vector2.ONE, duration)


func _cost_text(row: Dictionary) -> String:
	var parts := PackedStringArray()
	for kind: StringName in row.get("cost", {}):
		parts.append("%d %s" % [int(row["cost"][kind]), L10n.resource(kind)])
	var faith_cost := int(round(float(row.get("faith_cost", 0.0))))
	if faith_cost > 0:
		parts.append("%d %s" % [faith_cost, tr(&"RESOURCE_FAITH")])
	if parts.is_empty():
		return ""
	return "  ·  " + L10n.t(&"STORY_COST", [", ".join(parts)])


func _choose(choice_id: StringName) -> void:
	if not Storyteller.resolve_event(choice_id):
		return
	_dim.visible = false
	Sim.set_paused(_was_paused)
