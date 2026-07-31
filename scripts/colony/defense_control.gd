extends Node
## Per-colony safety orders, painted work boundaries, stockpile policy, and cleansing.
##
## The live arrays belong to the awake map. Abstractor packs them into that colony's ledger and
## Reconstitutor restores them, so travelling never leaks one settlement's orders into another.

signal changed
signal paint_mode_changed(mode: int)

enum PaintMode { NONE, FORBIDDEN, WORK, GUARD, ERASE }
enum StockFilter { ALL, FOOD, MATERIALS, FINISHED }

const CLEANSE_COST := {&"stone": 30, &"tools": 18}
const CLEANSE_FAITH := 30.0
const CLEANSE_DAWNS := 3
const CLEANSE_MAX_COVERAGE := 0.20
const SAFE_LIGHT := 110

var forbidden: PackedByteArray = PackedByteArray()
var work: PackedByteArray = PackedByteArray()
var guard: PackedByteArray = PackedByteArray()
var paint_mode: PaintMode = PaintMode.NONE
var shelter_active: bool = false
var dusk_lock: bool = true
var cleanse_dawns_left: int = 0
var cleanse_completed: bool = false
## stockpile centre cell -> {"filter": StockFilter, "priority": 1..3}
var stockpile_rules: Dictionary = {}

var _work_count := 0
var _guard_count := 0


func _ready() -> void:
	Events.phase_changed.connect(_on_phase_changed)
	Events.nest_destroyed.connect(_on_nest_destroyed)
	reset_for_map()


func reset_for_map() -> void:
	var count := World.grid.cell_count
	forbidden = PackedByteArray()
	forbidden.resize(count)
	work = PackedByteArray()
	work.resize(count)
	guard = PackedByteArray()
	guard.resize(count)
	paint_mode = PaintMode.NONE
	shelter_active = false
	dusk_lock = true
	cleanse_dawns_left = 0
	cleanse_completed = false
	stockpile_rules.clear()
	_work_count = 0
	_guard_count = 0
	changed.emit()
	paint_mode_changed.emit(paint_mode)


func to_dict() -> Dictionary:
	return {
		"forbidden": forbidden.duplicate(),
		"work": work.duplicate(),
		"guard": guard.duplicate(),
		"shelter_active": shelter_active,
		"dusk_lock": dusk_lock,
		"cleanse_dawns_left": cleanse_dawns_left,
		"cleanse_completed": cleanse_completed,
		"stockpile_rules": stockpile_rules.duplicate(true),
	}


func load_dict(data: Dictionary) -> void:
	reset_for_map()
	_copy_mask(data.get("forbidden", PackedByteArray()), forbidden)
	_copy_mask(data.get("work", PackedByteArray()), work)
	_copy_mask(data.get("guard", PackedByteArray()), guard)
	shelter_active = bool(data.get("shelter_active", false))
	dusk_lock = bool(data.get("dusk_lock", true))
	cleanse_dawns_left = int(data.get("cleanse_dawns_left", 0))
	cleanse_completed = bool(data.get("cleanse_completed", false))
	stockpile_rules = data.get("stockpile_rules", {}).duplicate(true)
	_recount()
	changed.emit()


func _copy_mask(source: PackedByteArray, target: PackedByteArray) -> void:
	for i in mini(source.size(), target.size()):
		target[i] = source[i]


func _recount() -> void:
	_work_count = 0
	_guard_count = 0
	for value in work:
		if value != 0:
			_work_count += 1
	for value in guard:
		if value != 0:
			_guard_count += 1


func set_paint_mode(value: PaintMode) -> void:
	paint_mode = PaintMode.NONE if paint_mode == value else value
	paint_mode_changed.emit(paint_mode)
	changed.emit()


func cancel_paint() -> void:
	if paint_mode != PaintMode.NONE:
		paint_mode = PaintMode.NONE
		paint_mode_changed.emit(paint_mode)
		changed.emit()


func paint(cell: int) -> bool:
	if paint_mode == PaintMode.NONE or not World.grid.is_valid_index(cell):
		return false
	var before_work := work[cell]
	var before_guard := guard[cell]
	match paint_mode:
		PaintMode.FORBIDDEN:
			forbidden[cell] = 1
		PaintMode.WORK:
			work[cell] = 1
		PaintMode.GUARD:
			guard[cell] = 1
		PaintMode.ERASE:
			forbidden[cell] = 0
			work[cell] = 0
			guard[cell] = 0
	if before_work != work[cell]:
		_work_count += 1 if work[cell] != 0 else -1
	if before_guard != guard[cell]:
		_guard_count += 1 if guard[cell] != 0 else -1
	changed.emit()
	return true


func allows_civilian(cell: int) -> bool:
	return World.grid.is_valid_index(cell) and forbidden[cell] == 0


func allows_work(cell: int) -> bool:
	return allows_civilian(cell) and (_work_count == 0 or work[cell] != 0)


func path_allowed(path: PackedInt32Array, is_guard: bool, allow_dark: bool = false) -> bool:
	if is_guard:
		return true
	for cell in path:
		if not allows_civilian(cell):
			return false
		if not allow_dark and dusk_lock and Sim.is_dark() and World.light_at(cell) < SAFE_LIGHT:
			return false
	return true


func should_shelter(villager: Node) -> bool:
	if villager == null or not is_instance_valid(villager):
		return false
	var def := Jobs.get_job(villager.job)
	if def != null and def.defends:
		return false
	return shelter_active or (dusk_lock and Sim.is_dark() and World.light_at(villager.cell()) < SAFE_LIGHT)


func shelter_cell() -> int:
	var best := World.keep_cell
	var best_tier := -1
	for b in Colony.buildings:
		if not is_instance_valid(b) or b.is_site() or b.def.center_tier <= 0:
			continue
		if b.def.center_tier > best_tier:
			best_tier = b.def.center_tier
			best = b.work_cell()
	return World.nearest_walkable(best)


func nearest_guard_cell(from: int) -> int:
	if _guard_count == 0:
		return -1
	var best := -1
	var best_dist := 0x7FFFFFFF
	for cell in guard.size():
		if guard[cell] == 0 or not World.is_walkable(cell):
			continue
		var distance := World.grid.dist_sq(from, cell)
		if distance < best_dist:
			best_dist = distance
			best = cell
	return best


func is_guard_cell(cell: int) -> bool:
	return World.grid.is_valid_index(cell) and guard[cell] != 0


func has_guard_zone() -> bool:
	return _guard_count > 0


func toggle_shelter() -> void:
	shelter_active = not shelter_active
	if shelter_active:
		for villager in Colony.villagers:
			if is_instance_valid(villager):
				villager.think_urgent = true
	Events.notice.emit(tr(&"CONTROL_SHELTER_ON" if shelter_active else &"CONTROL_SHELTER_OFF"), 1)
	changed.emit()


func toggle_dusk_lock() -> void:
	dusk_lock = not dusk_lock
	changed.emit()


func stockpile_filter(cell: int) -> int:
	return int(_stockpile_rule(cell).get("filter", StockFilter.ALL))


func stockpile_priority(cell: int) -> int:
	return int(_stockpile_rule(cell).get("priority", 1))


func cycle_stockpile_filter(cell: int) -> void:
	var row := _stockpile_rule(cell)
	row["filter"] = (int(row["filter"]) + 1) % StockFilter.size()
	stockpile_rules[cell] = row
	changed.emit()


func cycle_stockpile_priority(cell: int) -> void:
	var row := _stockpile_rule(cell)
	row["priority"] = int(row["priority"]) % 3 + 1
	stockpile_rules[cell] = row
	changed.emit()


func _stockpile_rule(cell: int) -> Dictionary:
	return stockpile_rules.get(cell, {"filter": StockFilter.ALL, "priority": 1}).duplicate()


func stockpile_accepts(cell: int, kind: StringName) -> bool:
	if kind == &"":
		return true
	match stockpile_filter(cell):
		StockFilter.FOOD:
			return kind == &"food"
		StockFilter.MATERIALS:
			return kind in [&"wood", &"stone"]
		StockFilter.FINISHED:
			return kind in [&"boards", &"cut_stone", &"tools"]
		_:
			return true


func stockpile_filter_name(cell: int) -> String:
	var keys: Array[StringName] = [
		&"STORAGE_ALL", &"STORAGE_FOOD", &"STORAGE_MATERIALS", &"STORAGE_FINISHED"]
	return tr(keys[stockpile_filter(cell)])


func can_start_cleanse() -> Dictionary:
	if cleanse_dawns_left > 0:
		return {"ok": false, "reason": tr(&"CLEANSE_ALREADY_ACTIVE")}
	if cleanse_completed or _blighted_count() == 0:
		return {"ok": false, "reason": tr(&"CLEANSE_ALREADY_COMPLETE")}
	if not World.live_nest_cells().is_empty():
		return {"ok": false, "reason": tr(&"CLEANSE_NESTS_REMAIN")}
	if World.blight_field.coverage() > CLEANSE_MAX_COVERAGE:
		return {"ok": false, "reason": tr(&"CLEANSE_TOO_CORRUPTED")}
	if Divine.faith < CLEANSE_FAITH:
		return {"ok": false, "reason": L10n.t(&"CLEANSE_NEED_FAITH", [int(CLEANSE_FAITH)])}
	if not Colony.can_afford(CLEANSE_COST):
		return {"ok": false, "reason": tr(&"CLEANSE_NEED_SUPPLIES")}
	return {"ok": true, "reason": ""}


func start_cleanse() -> bool:
	var check := can_start_cleanse()
	if not bool(check["ok"]):
		Events.notice.emit(String(check["reason"]), 1)
		return false
	Colony.spend(CLEANSE_COST)
	Divine.pay(CLEANSE_FAITH)
	cleanse_dawns_left = CLEANSE_DAWNS
	Events.notice.emit(tr(&"CLEANSE_STARTED"), 0)
	changed.emit()
	return true


func _on_phase_changed(phase: int, _duration: float) -> void:
	if phase != Sim.Phase.DAWN or cleanse_dawns_left <= 0:
		return
	var remaining := _blighted_count()
	World.repel_blight(ceili(float(remaining) / float(cleanse_dawns_left)))
	cleanse_dawns_left -= 1
	if cleanse_dawns_left <= 0 or _blighted_count() == 0:
		World.repel_blight(World.grid.cell_count)
		cleanse_dawns_left = 0
		cleanse_completed = true
		Events.notice.emit(tr(&"CLEANSE_COMPLETE"), 0)
	else:
		Events.notice.emit(L10n.t(&"CLEANSE_PROGRESS", [cleanse_dawns_left]), 0)
	changed.emit()


func _on_nest_destroyed(_cell: int) -> void:
	changed.emit()


func _blighted_count() -> int:
	var count := 0
	for value in World.blight:
		if value > 0:
			count += 1
	return count


func nest_suppression_multiplier() -> float:
	if World.nest_cells.is_empty():
		return 1.0
	var live_ratio := float(World.live_nest_cells().size()) / float(World.nest_cells.size())
	# Each destroyed nest permanently slows spread; clearing all of them cuts it by 75%.
	return lerpf(0.25, 1.0, live_ratio)
