extends CanvasLayer
## Mobile-first, full-screen management workspaces. Desktop keys remain optional shortcuts.

const WORKSPACE_IDS: Array[StringName] = [
	&"jobs", &"construction", &"harvest", &"terrain",
	&"spells", &"console", &"world", &"goals",
]
const WORKSPACE_NAMES := {
	&"jobs": "Jobs", &"construction": "Construction", &"harvest": "Harvest",
	&"terrain": "Terrain", &"spells": "Spells", &"console": "Console",
	&"world": "World", &"goals": "Goals",
}

var current: StringName = &"jobs"
var _screen: Control
var _title: Label
var _rows: VBoxContainer
var _tool_bar: PanelContainer
var _tool_status: Label
var _tool_shape: Button
var _tool_minus: Button
var _tool_plus: Button
var _tool_mode: StringName = &""
var _reset_entry: LineEdit
var _destructive_pending: int = -1
var _refresh_elapsed := 0.0

@onready var _placement: Node = get_node_or_null("../PlacementController")
@onready var _god_hand: Node = get_node_or_null("../GodHand")
@onready var _realm_map: Node = get_node_or_null("../RealmMap")


func _ready() -> void:
	layer = 18
	_build_screen()
	_build_tool_bar()
	WorkOrders.tool_changed.connect(_on_work_tool_changed)
	DefenseControl.gather_mode_changed.connect(_on_gather_tool_changed)
	set_process(true)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed < 0.5:
		return
	_refresh_elapsed = 0.0
	if _screen.visible and current in [&"jobs", &"console"]:
		_rebuild()
	if _tool_bar.visible:
		_refresh_tool_bar()


func open(id: StringName = &"jobs") -> void:
	var resolved := _resolve_id(id)
	if resolved not in WORKSPACE_IDS:
		resolved = &"jobs"
	current = resolved
	_destructive_pending = -1
	_screen.visible = true
	_tool_bar.visible = false
	_title.text = String(WORKSPACE_NAMES[current])
	_rebuild()


func close() -> void:
	_screen.visible = false
	if _tool_mode == &"":
		_tool_bar.visible = false
	_sync_parent_management_pause()


func is_open() -> bool:
	return _screen != null and _screen.visible


func cancel_all() -> void:
	DefenseControl.cancel_gather_paint()
	WorkOrders.cancel_tool()
	_tool_mode = &""
	_tool_bar.visible = false
	_screen.visible = false
	_sync_parent_management_pause()


func _sync_parent_management_pause() -> void:
	var hud := get_node_or_null("../Hud")
	if hud != null and hud.has_method("_sync_management_pause"):
		hud._sync_management_pause()


func _resolve_id(id: StringName) -> StringName:
	match id:
		&"build": return &"construction"
		&"powers": return &"spells"
		&"concerns", &"control", &"library", &"hand": return &"console"
		&"realm": return &"world"
	return id


func _build_screen() -> void:
	_screen = ColorRect.new()
	_screen.name = "WorkspaceScreen"
	_screen.color = Color(UiPalette.BG_DEEP, 0.985)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_screen.offset_top = 34.0
	_screen.visible = false
	add_child(_screen)

	var margin := MarginContainer.new()
	margin.name = "Safe"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in [&"margin_left", &"margin_top", &"margin_right", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	_screen.add_child(margin)
	var layout := VBoxContainer.new()
	layout.name = "Layout"
	layout.add_theme_constant_override("separation", 6)
	margin.add_child(layout)

	var header := HBoxContainer.new()
	layout.add_child(header)
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_font_size_override("font_size", 16)
	header.add_child(_title)
	var close_button := _button("Close", 64)
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var tabs := GridContainer.new()
	tabs.name = "WorkspaceTabs"
	tabs.columns = 4
	tabs.add_theme_constant_override("h_separation", 4)
	tabs.add_theme_constant_override("v_separation", 4)
	layout.add_child(tabs)
	for id in WORKSPACE_IDS:
		var tab := _button(String(WORKSPACE_NAMES[id]), 86)
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.pressed.connect(open.bind(id))
		tabs.add_child(tab)

	var scroll := ScrollContainer.new()
	scroll.name = "WorkspaceScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 5)
	scroll.add_child(_rows)


func _build_tool_bar() -> void:
	_tool_bar = PanelContainer.new()
	_tool_bar.name = "WorkspaceToolBar"
	_tool_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_tool_bar.position = Vector2(54, 310)
	_tool_bar.custom_minimum_size = Vector2(532, 42)
	_tool_bar.visible = false
	add_child(_tool_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_tool_bar.add_child(row)
	_tool_status = Label.new()
	_tool_status.custom_minimum_size = Vector2(210, 34)
	_tool_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_tool_status)
	_tool_minus = _button("−", 44)
	_tool_minus.pressed.connect(_adjust_tool.bind(-1))
	row.add_child(_tool_minus)
	_tool_shape = _button("Circle", 72)
	_tool_shape.pressed.connect(_toggle_tool_shape)
	row.add_child(_tool_shape)
	_tool_plus = _button("+", 44)
	_tool_plus.pressed.connect(_adjust_tool.bind(1))
	row.add_child(_tool_plus)
	var done := _button("Done", 64)
	done.pressed.connect(_finish_tool)
	row.add_child(done)


func _rebuild() -> void:
	_clear_rows()
	match current:
		&"jobs": _build_jobs()
		&"construction": _build_construction()
		&"harvest": _build_harvest()
		&"terrain": _build_terrain()
		&"spells": _build_spells()
		&"console": _build_console()
		&"world": _build_world()
		&"goals": _build_goals()


func _clear_rows() -> void:
	_reset_entry = null
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()


func _build_jobs() -> void:
	var total_assigned := 0
	for job: JobDef in Jobs.available():
		total_assigned += Colony.headcount_of(job.id)
	_add_note("Workers %d/%d • red rows are under-staffed" % [
		total_assigned, Colony.worker_count()])
	for job: JobDef in Jobs.available():
		var have := Colony.headcount_of(job.id)
		var want := Colony.quota_of(job.id)
		var active := 0
		for villager in Colony.villagers:
			if is_instance_valid(villager) and villager.alive and villager.job == job.id \
					and villager.state not in [Villager.State.IDLE, Villager.State.RESTING,
					Villager.State.SLEEPING]:
				active += 1
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 34
		var label := Label.new()
		label.text = "%s  %d/%d • %d active • %d idle" % [tr(job.display_name), have,
			want, active, maxi(have - active, 0)]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override("font_color",
			UiPalette.DANGER if have < want else job.color)
		row.add_child(label)
		var minus := _button("−", 42)
		minus.disabled = want <= 0
		minus.pressed.connect(_nudge_job.bind(job.id, -1))
		row.add_child(minus)
		var plus := _button("+", 42)
		plus.pressed.connect(_nudge_job.bind(job.id, 1))
		row.add_child(plus)
		_rows.add_child(row)


func _nudge_job(id: StringName, delta: int) -> void:
	Colony.set_quota(id, Colony.quota_of(id) + delta)
	call_deferred("_rebuild")


func _build_construction() -> void:
	_add_note("Building cap %d/%d • workers haul every material to each site" % [
		Colony.buildings.size(), Colony.building_cap()])
	var last_category := &""
	for def: BuildingDef in Buildings.revealed():
		if def.category != last_category:
			last_category = def.category
			_add_heading(String(def.category).capitalize())
		var cost := PackedStringArray()
		for kind: StringName in def.cost:
			cost.append("%s %d" % [L10n.resource(kind), int(def.cost[kind])])
		var button := _button("%s  —  %s" % [tr(def.display_name), ", ".join(cost)], 0)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.disabled = not Buildings.unlocked_in_run(def)
		button.tooltip_text = tr(def.description)
		button.pressed.connect(_begin_building.bind(def))
		_rows.add_child(button)


func _begin_building(def: BuildingDef) -> void:
	if _placement != null and _placement.has_method("begin"):
		_screen.visible = false
		_placement.begin(def)


func _build_harvest() -> void:
	_add_note("Choose a palette, then drag on the map. Hold to navigate with another finger.")
	_add_harvest_button("Wood", [&"woodcutting", &"lumberer"])
	_add_harvest_button("Stone", [&"quarrying", &"miner"])
	_add_harvest_button("Food", [&"foraging", &"farming"])
	_add_harvest_button("Crystal", [&"crystal_harvester"])


func _add_harvest_button(label_text: String, job_ids: Array[StringName]) -> void:
	var job: JobDef = null
	for id in job_ids:
		var candidate := Jobs.get_job(id)
		if candidate != null and not candidate.target_features.is_empty():
			job = candidate
			break
	var button := _button(label_text, 0)
	button.disabled = job == null
	if job != null:
		button.add_theme_color_override("font_color", job.color)
		button.pressed.connect(_begin_harvest.bind(job.id))
	_rows.add_child(button)


func _begin_harvest(job_id: StringName) -> void:
	WorkOrders.cancel_tool()
	DefenseControl.select_gather_mode(job_id)
	_tool_mode = &"harvest"
	_screen.visible = false
	_tool_bar.visible = true
	_refresh_tool_bar()


func _build_terrain() -> void:
	_add_note("Waymakers complete these orders physically. Destructive tools require two taps.")
	_add_terrain_button("Dig", WorkOrder.Kind.DIG, false)
	_add_terrain_button("Destroy terrain", WorkOrder.Kind.DESTROY_TERRAIN, true)
	_add_terrain_button("Build road", WorkOrder.Kind.BUILD_ROAD, false)
	_add_terrain_button("Remove road", WorkOrder.Kind.REMOVE_ROAD, true)
	_add_terrain_button("Dismantle building", WorkOrder.Kind.DISMANTLE, true)


func _add_terrain_button(label_text: String, kind: WorkOrder.Kind, destructive: bool) -> void:
	var confirm := destructive and _destructive_pending == int(kind)
	var button := _button("Confirm %s" % label_text if confirm else label_text, 0)
	button.add_theme_color_override("font_color", UiPalette.DANGER if destructive else UiPalette.TEXT)
	button.pressed.connect(_choose_terrain_tool.bind(kind, destructive))
	_rows.add_child(button)


func _choose_terrain_tool(kind: WorkOrder.Kind, destructive: bool) -> void:
	if destructive and _destructive_pending != int(kind):
		_destructive_pending = int(kind)
		_rebuild()
		return
	_destructive_pending = -1
	DefenseControl.cancel_gather_paint()
	WorkOrders.begin_tool(kind)
	_tool_mode = &"terrain"
	_screen.visible = false
	_tool_bar.visible = true
	_refresh_tool_bar()


func _build_spells() -> void:
	_add_note("Influence %.0f / %.0f • %.0f reserved • individual Faith changes the cap" % [
		DivineLedger.available, DivineLedger.total_capacity(), DivineLedger.reserved])
	for def: PowerDef in Powers.all():
		if not Divine.is_taken_up(def.id):
			continue
		var cooldown := Divine.cooldown_of(def.id)
		var suffix := " • %.0f Influence" % def.faith_cost
		if cooldown > 0.0:
			suffix += " • %ds" % ceili(cooldown)
		var button := _button("%s%s" % [tr(def.display_name), suffix], 0)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.disabled = not Divine.power_active(def) or cooldown > 0.0 \
			or not DivineLedger.can_spend(def.faith_cost)
		button.tooltip_text = tr(def.description)
		button.add_theme_color_override("font_color", def.color)
		button.pressed.connect(_arm_power.bind(def))
		_rows.add_child(button)


func _arm_power(def: PowerDef) -> void:
	if _god_hand != null and Divine.can_cast(def):
		cancel_all()
		_god_hand.arm(def)


func _build_console() -> void:
	var threat := Threat.pressure_breakdown()
	var energy := 0
	var storage_used := 0
	var storage_capacity := 0
	var towers := PackedStringArray()
	for building in Colony.buildings:
		if not is_instance_valid(building) or building.is_site():
			continue
		energy += building.stored_energy
		if building.def.inventory_capacity > 0:
			storage_used += building.inventory_used()
			storage_capacity += building.def.inventory_capacity
		if not building.def.ammo_kind.is_empty():
			towers.append("%s %d %s" % [tr(building.def.display_name),
				int(building.input_buffer.get(building.def.ammo_kind, 0)),
				L10n.resource(building.def.ammo_kind)])
	_add_heading("Colony")
	_add_note("Population %d/%d • housing %d free • buildings %d/%d" % [
		Colony.population(), Colony.workforce_cap(), Colony.beds_free(),
		Colony.buildings.size(), Colony.building_cap()])
	_add_note("Dirty water %d • clean water %d • Energy %d" % [
		Colony.amount_of(&"dirty_water"), Colony.amount_of(&"clean_water"), energy])
	_add_note("Storage %d/%d • work orders %d" % [storage_used, storage_capacity,
		WorkOrders.orders.size()])
	_add_heading("Corruption")
	_add_note("Threat %d%% • trend %s • enemy level %d • expected bodies %d" % [
		int(float(threat.get("current_pressure", 0.0)) * 100.0),
		"rising" if int(threat.get("trend", 0)) > 0 else (
			"falling" if int(threat.get("trend", 0)) < 0 else "steady"),
		int(threat.get("enemy_level", 1)), int(threat.get("expected_bodies", 0))])
	_add_note("Resistance %d%% • corrupt footprint %d%% • enemy works %d" % [
		int(float(threat.get("containment_ratio", 0.0)) * 100.0),
		int(float(threat.get("actual_coverage", 0.0)) * 100.0),
		int(threat.get("enemy_structure_count", 0))])
	_add_heading("Tower ammunition")
	_add_note("No ammunition towers built" if towers.is_empty() else "\n".join(towers))
	_add_heading("Update 2d parity ledger")
	_add_note("%d definitions validated • %d numeric/source rows still block parity sign-off" % [
		BalanceCatalog.ledger_entries.size(), BalanceCatalog.verification_blockers().size()])


func _build_world() -> void:
	_add_note("45 connected regions • Forest, Desert, Marsh, Dry Lands, Haven and Outlands")
	var map_button := _button("Open Region Map", 0)
	map_button.pressed.connect(_open_realm)
	_rows.add_child(map_button)
	_add_heading("Doom World")
	_add_note("This permanently resets all 45 regions. God XP, perks, goals and chest slots remain.")
	_reset_entry = LineEdit.new()
	_reset_entry.name = "ResetConfirmation"
	_reset_entry.placeholder_text = "Type RESET exactly"
	_reset_entry.custom_minimum_size.y = 34
	_rows.add_child(_reset_entry)
	var reset := _button("Reset all regions", 0)
	reset.add_theme_color_override("font_color", UiPalette.DANGER)
	reset.pressed.connect(_doom_world)
	_rows.add_child(reset)


func _open_realm() -> void:
	_screen.visible = false
	if _realm_map != null and _realm_map.has_method("open"):
		_realm_map.open()


func _doom_world() -> void:
	if _reset_entry == null or _reset_entry.text != "RESET":
		Events.notice.emit("Type RESET exactly to Doom this world", 2)
		return
	var run := get_parent()
	if run != null and run.has_method("doom_world") and run.doom_world(_reset_entry.text):
		cancel_all()


func _build_goals() -> void:
	_add_note("%d / 117 goals • God XP %d • chest slots %d • chests ready %d" % [
		Meta.chronicle_completed.size(), Meta.god_experience, Meta.unlocked_chest_slots,
		Meta.chests.size()])
	for i in Meta.chests.size():
		var chest: Dictionary = Meta.chests[i]
		var button := _button("Open %s chest" % String(chest.get("rarity", &"chest")).capitalize(), 0)
		button.pressed.connect(_open_chest.bind(i))
		_rows.add_child(button)
	var last_branch := &""
	for goal: Dictionary in Chronicle.all():
		var branch := StringName(goal["branch"])
		if branch != last_branch:
			last_branch = branch
			_add_heading(String(branch).capitalize())
		var completed := StringName(goal["id"]) in Meta.chronicle_completed
		var progress := int(Meta.lifetime_stats.get(goal["metric"], 0))
		var label := Label.new()
		label.text = "%s  %s  %d/%d  +%d XP" % ["✓" if completed else "○",
			String(goal["display_name"]), progress, int(goal["target"]), int(goal["god_xp"])]
		label.custom_minimum_size.y = 24
		label.add_theme_color_override("font_color", UiPalette.OK if completed else UiPalette.TEXT_DIM)
		_rows.add_child(label)


func _open_chest(index: int) -> void:
	var reward := Meta.open_chest(index)
	if not reward.is_empty():
		Events.notice.emit("Chest: %s +%d" % [String(reward.get("kind", &"")).capitalize(),
			int(reward.get("amount", 0))], 1)
	_rebuild()


func _adjust_tool(delta: int) -> void:
	if _tool_mode == &"harvest":
		DefenseControl.adjust_gather_radius(delta)
	elif _tool_mode == &"terrain":
		WorkOrders.adjust_active_brush(delta)


func _toggle_tool_shape() -> void:
	if _tool_mode == &"harvest":
		DefenseControl.toggle_gather_shape()
	elif _tool_mode == &"terrain":
		WorkOrders.toggle_active_shape()


func _finish_tool() -> void:
	DefenseControl.cancel_gather_paint()
	WorkOrders.cancel_tool()
	_tool_mode = &""
	_tool_bar.visible = false
	open(current)


func _on_work_tool_changed(kind: int, _size: int, _shape: WorkOrder.Shape) -> void:
	if kind < 0 and _tool_mode == &"terrain":
		_tool_mode = &""
		_tool_bar.visible = false
	else:
		_refresh_tool_bar()


func _on_gather_tool_changed(job_id: StringName, _erasing: bool, _radius: int) -> void:
	if job_id == &"" and _tool_mode == &"harvest":
		_tool_mode = &""
		_tool_bar.visible = false
	else:
		_refresh_tool_bar()


func _refresh_tool_bar() -> void:
	if _tool_mode == &"harvest":
		var job := Jobs.get_job(DefenseControl.gather_job)
		_tool_status.text = "%s • size %d" % [
			tr(job.display_name) if job != null else "Harvest", DefenseControl.gather_radius]
		_tool_shape.text = "Circle" if DefenseControl.gather_shape == WorkOrder.Shape.CIRCLE \
			else "Square"
		_tool_minus.disabled = DefenseControl.gather_radius <= DefenseControl.GATHER_RADIUS_MIN
		_tool_plus.disabled = DefenseControl.gather_radius >= DefenseControl.GATHER_RADIUS_MAX
	elif _tool_mode == &"terrain":
		_tool_status.text = "%s • size %d • hold to cancel" % [
			_terrain_tool_name(WorkOrders.active_kind), WorkOrders.active_brush_size]
		_tool_shape.text = "Circle" if WorkOrders.active_shape == WorkOrder.Shape.CIRCLE else "Square"
		_tool_minus.disabled = WorkOrders.active_brush_size <= 1
		_tool_plus.disabled = WorkOrders.active_brush_size >= 12


static func _terrain_tool_name(kind: int) -> String:
	match kind:
		WorkOrder.Kind.DIG: return "Dig"
		WorkOrder.Kind.DESTROY_TERRAIN: return "Destroy terrain"
		WorkOrder.Kind.BUILD_ROAD: return "Build road"
		WorkOrder.Kind.REMOVE_ROAD: return "Remove road"
		WorkOrder.Kind.DISMANTLE: return "Dismantle"
	return "Terrain"


func _add_heading(text_value: String) -> void:
	var label := Label.new()
	label.text = text_value
	label.custom_minimum_size.y = 25
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", UiPalette.ACCENT_PALE)
	_rows.add_child(label)


func _add_note(text_value: String) -> void:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", UiPalette.TEXT_DIM)
	_rows.add_child(label)


static func _button(text_value: String, minimum_width: float) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(minimum_width, 34)
	return button
