class_name RealmMapCanvas
extends Control
## Gridless world overview that zooms into an exact local-region preview before confirmation.

signal site_selected(site_id: StringName)
signal zoom_changed(zoomed_in: bool)

var selected_id: StringName = &""
var zoomed_in: bool = false
var _hovered_id: StringName = &""
var _preview_texture: ImageTexture
var _zoom_tween: Tween
## Mouse clicks are emulated as touch presses on desktop. Remember the frame so
## the touch twin cannot immediately hit the newly-open preview's Back field.
var _press_frame: int = -1
var _zoom_progress := 0.0:
	set(value):
		_zoom_progress = value
		queue_redraw()


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(queue_redraw)
	Events.realm_changed.connect(refresh)
	refresh()


func refresh() -> void:
	if selected_id != &"" and not Realm.sites.has(selected_id):
		reset_view()
	if zoomed_in and selected_id != &"":
		_preview_texture = Realm.build_region_preview(selected_id)
	queue_redraw()


func reset_view() -> void:
	if _zoom_tween != null:
		_zoom_tween.kill()
	zoomed_in = false
	selected_id = &""
	_hovered_id = &""
	_preview_texture = null
	_zoom_progress = 0.0
	tooltip_text = ""
	queue_redraw()


func select(id: StringName) -> void:
	if Realm.sites.has(id):
		selected_id = id


func zoom_to(id: StringName) -> void:
	if not Realm.sites.has(id):
		return
	if _zoom_tween != null:
		_zoom_tween.kill()
	selected_id = id
	_preview_texture = Realm.build_region_preview(id)
	zoomed_in = true
	# Region inspection is navigation, not decoration. It should answer the tap on
	# the same frame instead of making the player wait through a camera flourish.
	_zoom_progress = 1.0
	site_selected.emit(id)
	zoom_changed.emit(true)


func zoom_out() -> void:
	if not zoomed_in:
		return
	if _zoom_tween != null:
		_zoom_tween.kill()
	_zoom_progress = 0.0
	_finish_zoom_out()


func _finish_zoom_out() -> void:
	zoomed_in = false
	selected_id = &""
	_preview_texture = null
	zoom_changed.emit(false)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var primary_press := (event is InputEventMouseButton \
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
		and (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
	if primary_press:
		var frame := Engine.get_process_frames()
		if frame == _press_frame:
			accept_event()
			return
		_press_frame = frame
	if zoomed_in:
		# The local preview is intentionally smaller than this control on wide screens.
		# Treat its surrounding field as a generous Back target for mouse and touch.
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
				and event.pressed and not _preview_rect().has_point(event.position):
			zoom_out()
			accept_event()
		elif event is InputEventScreenTouch and event.pressed \
				and not _preview_rect().has_point(event.position):
			zoom_out()
			accept_event()
		return
	if event is InputEventMouseMotion:
		_hovered_id = _site_from_point(event.position)
		_update_tooltip(_hovered_id)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed:
		_zoom_at(event.position)
	elif event is InputEventScreenTouch and event.pressed:
		_zoom_at(event.position)


func _zoom_at(point: Vector2) -> void:
	var id := _site_from_point(point)
	if id == &"":
		return
	zoom_to(id)
	accept_event()


func _site_from_point(point: Vector2) -> StringName:
	var rect := _overview_rect()
	if not rect.has_point(point):
		return &""
	var local := point - rect.position
	var x := clampi(int(local.x / rect.size.x * Realm.REGION_WIDTH), 0, Realm.REGION_WIDTH - 1)
	var y := clampi(int(local.y / rect.size.y * Realm.REGION_HEIGHT), 0, Realm.REGION_HEIGHT - 1)
	return Realm.region_id(Vector2i(x, y))


func _update_tooltip(id: StringName) -> void:
	if id == &"":
		tooltip_text = ""
		return
	var row := Realm.site(id)
	var biome_id := StringName(row.get("biome", Biomes.DEFAULT_ID))
	var biome := tr(Biomes.name_key(biome_id))
	tooltip_text = L10n.t(&"REALM_INSPECT_TOOLTIP", [row.get("name", id), biome])


func _overview_rect() -> Rect2:
	var padding := 7.0
	var available := size - Vector2.ONE * padding * 2.0
	var aspect := float(Realm.REGION_WIDTH) / float(Realm.REGION_HEIGHT)
	var wanted := available
	if wanted.x / wanted.y > aspect:
		wanted.x = wanted.y * aspect
	else:
		wanted.y = wanted.x / aspect
	return Rect2((size - wanted) * 0.5, wanted)


func _preview_rect() -> Rect2:
	var side := minf(size.x, size.y) - 14.0
	return Rect2((size - Vector2.ONE * side) * 0.5, Vector2.ONE * side)


func _region_rect(id: StringName) -> Rect2:
	var row := Realm.site(id)
	if row.is_empty():
		return Rect2()
	var overview := _overview_rect()
	var cell := overview.size / Vector2(Realm.REGION_WIDTH, Realm.REGION_HEIGHT)
	return Rect2(overview.position + Vector2(row["coord"]) * cell, cell)


func _region_center(id: StringName) -> Vector2:
	return _region_rect(id).get_center()


func _draw() -> void:
	if Realm.sites.is_empty():
		return
	_draw_overview(1.0 - _zoom_progress * 0.62)
	if zoomed_in and _preview_texture != null and selected_id != &"":
		var from := _region_rect(selected_id)
		var to := _preview_rect()
		var preview_rect := Rect2(
			from.position.lerp(to.position, _zoom_progress),
			from.size.lerp(to.size, _zoom_progress))
		draw_rect(preview_rect.grow(3.0), Color("080c11"), true)
		draw_texture_rect(_preview_texture, preview_rect, false,
			Color(1.0, 1.0, 1.0, _zoom_progress))
		draw_rect(preview_rect, Color(0.82, 0.74, 0.52, _zoom_progress * 0.86), false, 2.0)


func _draw_overview(alpha: float) -> void:
	var rect := _overview_rect()
	draw_rect(rect.grow(3.0), Color(0.02, 0.04, 0.06, alpha), true)
	if Realm.macro_texture != null:
		draw_texture_rect(Realm.macro_texture, rect, false, Color(1.0, 1.0, 1.0, alpha))

	var drawn := {}
	for id: StringName in Realm.colonies:
		var ledger: ColonyLedger = Realm.colonies[id]
		if ledger.fallen:
			continue
		for other: StringName in ledger.connections:
			if not Realm.settled(other):
				continue
			var key_parts := [String(id), String(other)]
			key_parts.sort()
			var key := "%s:%s" % key_parts
			if drawn.has(key):
				continue
			drawn[key] = true
			draw_line(_region_center(id), _region_center(other),
				Color(1.0, 0.76, 0.37, 0.68 * alpha), 2.0)

	for route in Realm.active_routes():
		if route.status != &"in_transit" \
				or (route.source_id != Realm.awake_id and route.destination_id != Realm.awake_id):
			continue
		for i in range(route.path.size() - 1):
			draw_dashed_line(_region_center(route.path[i]), _region_center(route.path[i + 1]),
				Color(0.94, 0.82, 0.53, 0.72 * alpha), 1.0, 3.0)
		var phase_fraction := Sim.phase_progress() / float(maxi(route.arrival_day - route.departure_day, 1))
		var caravan_progress := clampf(route.progress(Sim.day) + phase_fraction, 0.0, 1.0)
		var caravan_point := _route_point(route.path, caravan_progress)
		draw_circle(caravan_point, 3.2, Color(0.12, 0.08, 0.05, alpha))
		draw_circle(caravan_point, 2.0, Color(1.0, 0.72, 0.26, alpha))

	var cell_size := rect.size / Vector2(Realm.REGION_WIDTH, Realm.REGION_HEIGHT)
	for id: StringName in Realm.colonies:
		var ledger: ColonyLedger = Realm.colonies[id]
		var center := _region_center(id)
		var radius := minf(cell_size.x, cell_size.y) * 0.20
		var marker := Color("f6bd5a")
		if ledger.fallen:
			marker = Color("6f5963")
		elif ledger.purified:
			marker = Color("8fd5a6")
		elif id == Realm.awake_id:
			marker = Color("fff0b0")
		if not ledger.purified and ledger.corruption > 0.005:
			var corruption_alpha := clampf(0.10 + ledger.corruption * 0.34, 0.10, 0.28) * alpha
			draw_arc(center, radius + 3.5, -PI * 0.8,
				-PI * 0.8 + TAU * clampf(ledger.corruption * 1.8, 0.12, 0.94),
				18, Color(0.72, 0.24, 0.52, corruption_alpha), 1.5)
		draw_circle(center, radius + 2.0, Color(0.09, 0.07, 0.08, alpha))
		draw_circle(center, radius, Color(marker, alpha))
		if ledger.is_heart:
			draw_circle(center, radius * 0.44, Color(0.90, 0.43, 0.26, alpha))
		if ledger.fallen:
			draw_line(center - Vector2.ONE * radius * 0.6,
				center + Vector2.ONE * radius * 0.6, Color(0.83, 0.65, 0.65, alpha), 2.0)
			draw_line(center + Vector2(-radius, radius) * 0.6,
				center + Vector2(radius, -radius) * 0.6, Color(0.83, 0.65, 0.65, alpha), 2.0)

	if _hovered_id != &"" and not zoomed_in:
		# Show the exact region a click opens; the overview and its hit target now agree.
		var hovered_rect := _region_rect(_hovered_id)
		draw_rect(hovered_rect, Color(1.0, 0.72, 0.30, 0.10 * alpha), true)
		draw_rect(hovered_rect.grow(-0.5), Color(1.0, 0.86, 0.58, 0.88 * alpha), false, 1.0)
	draw_rect(rect, Color(0.68, 0.74, 0.72, 0.48 * alpha), false, 1.0)


func _route_point(path: Array[StringName], progress: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	if path.size() == 1:
		return _region_center(path[0])
	var scaled := clampf(progress, 0.0, 1.0) * float(path.size() - 1)
	var segment := mini(floori(scaled), path.size() - 2)
	return _region_center(path[segment]).lerp(_region_center(path[segment + 1]),
		scaled - float(segment))
