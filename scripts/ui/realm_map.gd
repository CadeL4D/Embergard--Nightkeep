extends CanvasLayer
## Region selection, colony summaries, transfers, and the campaign victory action.

@onready var _canvas: RealmMapCanvas = $Backdrop/Safe/Panel/Layout/Main/MapFrame/Map
@onready var _title: Label = $Backdrop/Safe/Panel/Layout/Header/Title
@onready var _realm_state: Label = $Backdrop/Safe/Panel/Layout/Header/RealmState
@onready var _close_button: Button = $Backdrop/Safe/Panel/Layout/Header/Close
@onready var _name: Label = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Name
@onready var _status: Label = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Status
@onready var _summary: Label = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Summary
@onready var _warning: Label = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Warning
@onready var _primary: Button = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Primary
@onready var _transfers: Control = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Transfers
@onready var _send_food: Button = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Transfers/SendFood
@onready var _send_wood: Button = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Transfers/SendWood
@onready var _send_migrant: Button = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/Transfers/SendMigrant
@onready var _back_to_world: Button = $Backdrop/Safe/Panel/Layout/Main/Details/Layout/BackToWorld
@onready var _footer: Control = $Backdrop/Safe/Panel/Layout/Footer
@onready var _coverage: ProgressBar = $Backdrop/Safe/Panel/Layout/Footer/Coverage
@onready var _heart: Label = $Backdrop/Safe/Panel/Layout/Footer/Heart
@onready var _assault: Button = $Backdrop/Safe/Panel/Layout/Footer/Assault

var _selected: StringName = &""
var _was_paused: bool = false
var _choosing_first: bool = false


func _ready() -> void:
	visible = false
	_title.text = tr(&"REALM_TITLE")
	_close_button.text = tr(&"UI_CLOSE")
	_send_food.text = tr(&"REALM_SEND_FOOD")
	_send_wood.text = tr(&"REALM_SEND_WOOD")
	_send_migrant.text = tr(&"REALM_SEND_SETTLER")
	_back_to_world.text = tr(&"REALM_BACK_TO_WORLD")
	_assault.text = tr(&"REALM_ASSAULT")
	_close_button.pressed.connect(close)
	_canvas.site_selected.connect(_on_site_selected)
	_canvas.zoom_changed.connect(_on_zoom_changed)
	_back_to_world.pressed.connect(_canvas.zoom_out)
	_primary.pressed.connect(_on_primary)
	_send_food.pressed.connect(_send_resource.bind(&"food"))
	_send_wood.pressed.connect(_send_resource.bind(&"wood"))
	_send_migrant.pressed.connect(_on_send_migrant)
	_assault.pressed.connect(_on_assault)
	Events.realm_changed.connect(_refresh)
	Events.realm_victory.connect(close)


func open() -> void:
	if visible or Realm.awake_id == &"":
		return
	Realm.capture_awake()
	_choosing_first = false
	_close_button.visible = true
	_footer.visible = true
	_was_paused = Sim.paused
	Sim.set_paused(true)
	visible = true
	_selected = &""
	_canvas.reset_view()
	_canvas.refresh()
	_refresh()


func open_for_first_settlement() -> void:
	_choosing_first = true
	_was_paused = false
	_close_button.visible = false
	_footer.visible = false
	visible = true
	_selected = &""
	_canvas.reset_view()
	_canvas.refresh()
	_refresh()


func close() -> void:
	if not visible or _choosing_first:
		return
	visible = false
	Sim.set_paused(_was_paused)


func _finish_first_selection() -> void:
	_choosing_first = false
	visible = false
	_canvas.reset_view()


func _unhandled_input(event: InputEvent) -> void:
	if visible and not _choosing_first and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _on_site_selected(id: StringName) -> void:
	_selected = id
	_refresh()


func _on_zoom_changed(is_zoomed: bool) -> void:
	if not is_zoomed:
		_selected = &""
	_refresh()


func _refresh() -> void:
	if not visible:
		return
	if _selected == &"" or not Realm.sites.has(_selected):
		if _choosing_first:
			_realm_state.text = tr(&"REALM_FIRST_HEADER").format([Realm.world_seed])
		else:
			_realm_state.text = tr(&"REALM_HEADER_STATE").format([
				Realm.colonies.size(), int(round(Realm.ring_coverage() * 100.0))])
		_name.text = tr(&"REALM_OVERVIEW")
		_status.text = tr(&"REALM_CHOOSE_REGION")
		_summary.text = tr(&"REALM_CHOOSE_REGION_SUMMARY")
		_warning.text = ""
		_primary.visible = false
		_transfers.visible = false
		_back_to_world.visible = false
		_update_footer()
		_canvas.queue_redraw()
		return
	var row: Dictionary = Realm.site(_selected)
	var ledger := Realm.colony(_selected)
	var is_awake := _selected == Realm.awake_id
	var is_settled := ledger != null and not ledger.fallen
	var is_connected := Realm.connected(Realm.awake_id, _selected)
	var coord: Vector2i = row["coord"]
	var biome_id := StringName(row.get("biome", Biomes.DEFAULT_ID))
	var biome := tr(Biomes.name_key(biome_id))
	var hazard := tr(Biomes.hazard_key(biome_id))

	if _choosing_first:
		_realm_state.text = tr(&"REALM_FIRST_HEADER").format([Realm.world_seed])
	else:
		_realm_state.text = tr(&"REALM_HEADER_STATE").format([
			Realm.colonies.size(), int(round(Realm.ring_coverage() * 100.0))])
	_name.text = "%s  [%d,%d]" % [String(row.get("name", _selected)), coord.x + 1, coord.y + 1]

	if bool(row.get("blight_core", false)):
		_status.text = tr(&"REALM_BLIGHT_CORE")
		_summary.text = tr(&"REALM_CORE_SUMMARY")
	elif not bool(row.get("settleable", false)):
		_status.text = tr(&"REALM_OCEAN")
		_summary.text = tr(&"REALM_OCEAN_SUMMARY")
	elif ledger == null:
		_status.text = tr(&"REALM_UNSETTLED")
		_summary.text = tr(&"REALM_REGION_SUMMARY").format([
			biome,
			int(round(float(row.get("forest", 0.0)) * 100.0)),
			int(round(float(row.get("stone", 0.0)) * 100.0)),
			int(round(float(row.get("food", 0.0)) * 100.0))])
		_summary.text += "\n" + hazard
		if not _choosing_first:
			_summary.text += "\n\n" + tr(&"REALM_SITE_SUMMARY").format([
				int(Realm.SETTLEMENT_COST[&"wood"]),
				int(Realm.SETTLEMENT_COST[&"stone"]),
				int(Realm.SETTLEMENT_COST[&"food"]),
				Realm.SETTLERS_REQUIRED])
	elif ledger.fallen:
		_status.text = tr(&"REALM_FALLEN")
		_summary.text = tr(&"REALM_FALLEN_SUMMARY")
	else:
		_status.text = tr(&"REALM_AWAKE") if is_awake else tr(&"REALM_SLEEPING")
		_summary.text = tr(&"REALM_COLONY_SUMMARY").format([
			ledger.population(), ledger.building_count(), int(round(ledger.average_mood())),
			ledger.stock_of(&"food"), ledger.stock_of(&"wood"), ledger.stock_of(&"stone"),
			int(round(ledger.corruption * 100.0)),
			int(round(ledger.defense_strength() * 100.0)),
			int(round(ledger.pressure))])

	_primary.visible = false
	_back_to_world.visible = _canvas.zoomed_in
	_primary.disabled = false
	_warning.text = ""
	if _choosing_first and _canvas.zoomed_in:
		var first_check := Realm.can_found_first(_selected)
		_primary.visible = true
		_primary.text = tr(&"REALM_BEGIN_HERE")
		_primary.disabled = not bool(first_check["ok"])
		_warning.text = String(first_check["reason"])
	elif _canvas.zoomed_in and not is_awake and not (ledger != null and ledger.fallen):
		_primary.visible = true
		if ledger == null:
			var check := Realm.can_found(_selected)
			_primary.text = tr(&"REALM_FOUND")
			_primary.disabled = not bool(check["ok"])
			_warning.text = String(check["reason"])
		else:
			_primary.text = tr(&"REALM_TRAVEL")
			_primary.disabled = not Realm.can_travel(_selected)
			if not is_connected:
				_warning.text = tr(&"REALM_NO_ROAD")

	var can_transfer := not _choosing_first and is_settled and not is_awake and is_connected
	_transfers.visible = can_transfer
	_send_food.disabled = Colony.available(&"food") < 10
	_send_wood.disabled = Colony.available(&"wood") < 10
	_send_migrant.disabled = Colony.population() <= 1

	_update_footer()
	_canvas.queue_redraw()


func _update_footer() -> void:
	if _choosing_first:
		return
	_coverage.value = Realm.ring_coverage() * 100.0
	_coverage.tooltip_text = tr(&"REALM_COVERAGE_HELP")
	_heart.text = tr(&"REALM_HEART_STATE").format([
		Realm.blight_heart_health, Realm.BLIGHT_HEART_MAX])
	var assault_check := Realm.can_assault()
	_assault.disabled = not bool(assault_check["ok"])
	_assault.tooltip_text = String(assault_check["reason"])


func _on_primary() -> void:
	var run := get_parent()
	var ok := false
	if _choosing_first and run.has_method("found_first_region"):
		ok = run.found_first_region(_selected)
	elif Realm.colony(_selected) == null and run.has_method("found_realm_site"):
		ok = run.found_realm_site(_selected)
	elif run.has_method("travel_to_colony"):
		ok = run.travel_to_colony(_selected)
	if ok:
		if _choosing_first:
			_finish_first_selection()
		else:
			close()


func _send_resource(kind: StringName) -> void:
	var run := get_parent()
	if run.has_method("send_realm_resource"):
		run.send_realm_resource(_selected, kind, 10)
	_refresh()


func _on_send_migrant() -> void:
	var run := get_parent()
	if run.has_method("send_realm_migrant"):
		run.send_realm_migrant(_selected)
	_refresh()


func _on_assault() -> void:
	Realm.assault_blight_heart()
	_refresh()
