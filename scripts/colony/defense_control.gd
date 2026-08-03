extends Node
## Per-colony safety orders, painted work boundaries, stockpile policy, and cleansing.
##
## The live arrays belong to the awake map. Abstractor packs them into that colony's ledger and
## Reconstitutor restores them, so travelling never leaks one settlement's orders into another.

signal changed
signal paint_mode_changed(mode: int)
signal gather_mode_changed(job_id: StringName, erasing: bool, radius: int)

enum PaintMode { NONE, FORBIDDEN, WORK, GUARD, ERASE }
enum StockFilter { ALL, FOOD, MATERIALS, FINISHED }

const CLEANSE_COST := {&"stone": 30, &"tools": 18}
const CLEANSE_FAITH := 30.0
const CLEANSE_DAWNS := 3
const CLEANSE_MAX_COVERAGE := 0.20
const SAFE_LIGHT := 110
const GATHER_RADIUS_MIN := 1
const GATHER_RADIUS_MAX := 6

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
## Per-field-job resource orders. A set byte means that specific resource cell may
## be harvested by that job. Empty masks are intentional: gathering never starts
## until the player paints an order.
var gather_designations: Dictionary = {}
var gather_job: StringName = &""
var gather_erasing: bool = false
var gather_radius: int = 2

var _work_count := 0
var _guard_count := 0


func _ready() -> void:
	Events.phase_changed.connect(_on_phase_changed)
	Events.nest_destroyed.connect(_on_nest_destroyed)
	Events.terrain_changed.connect(_on_terrain_changed)
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
	gather_designations.clear()
	for job: JobDef in Jobs.all():
		if job.target_features.is_empty():
			continue
		var mask := PackedByteArray()
		mask.resize(count)
		gather_designations[job.id] = mask
	gather_job = &""
	gather_erasing = false
	gather_radius = 2
	_work_count = 0
	_guard_count = 0
	changed.emit()
	paint_mode_changed.emit(paint_mode)
	gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)


func to_dict() -> Dictionary:
	var packed_gather := {}
	for job_id in gather_designations:
		var mask: PackedByteArray = gather_designations[job_id]
		packed_gather[String(job_id)] = mask.duplicate()
	return {
		"forbidden": forbidden.duplicate(),
		"work": work.duplicate(),
		"guard": guard.duplicate(),
		"shelter_active": shelter_active,
		"dusk_lock": dusk_lock,
		"cleanse_dawns_left": cleanse_dawns_left,
		"cleanse_completed": cleanse_completed,
		"stockpile_rules": stockpile_rules.duplicate(true),
		"gather_designations": packed_gather,
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
	var saved_gather: Dictionary = data.get("gather_designations", {})
	for raw_job_id in saved_gather:
		var job_id := StringName(raw_job_id)
		if not gather_designations.has(job_id):
			continue
		var target: PackedByteArray = gather_designations[job_id]
		var source: PackedByteArray = saved_gather[raw_job_id]
		_copy_mask(source, target)
		gather_designations[job_id] = target
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
	if gather_job != &"":
		gather_job = &""
		gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)
	paint_mode = PaintMode.NONE if paint_mode == value else value
	paint_mode_changed.emit(paint_mode)
	changed.emit()


func cancel_paint() -> void:
	if paint_mode != PaintMode.NONE:
		paint_mode = PaintMode.NONE
		paint_mode_changed.emit(paint_mode)
		changed.emit()


# --- Gathering designations -----------------------------------------------------------

## Enter the resource brush for one field job. Selecting the active job again exits
## the mode, which makes the small Area button work as both open and close.
func set_gather_mode(job_id: StringName) -> void:
	var job := Jobs.get_job(job_id)
	if job == null or job.target_features.is_empty():
		return
	if paint_mode != PaintMode.NONE:
		paint_mode = PaintMode.NONE
		paint_mode_changed.emit(paint_mode)
	gather_job = &"" if gather_job == job_id else job_id
	gather_erasing = false
	gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)
	changed.emit()


## Select a harvest brush without toggle-to-close semantics. The consolidated
## Wood/Stone/Berries bar uses this while Done remains the one explicit exit.
func select_gather_mode(job_id: StringName) -> void:
	var job := Jobs.get_job(job_id)
	if job == null or job.target_features.is_empty():
		return
	if paint_mode != PaintMode.NONE:
		paint_mode = PaintMode.NONE
		paint_mode_changed.emit(paint_mode)
	gather_job = job_id
	gather_erasing = false
	gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)
	changed.emit()


func cancel_gather_paint() -> void:
	if gather_job == &"":
		return
	gather_job = &""
	gather_erasing = false
	gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)
	changed.emit()


func set_gather_erasing(value: bool) -> void:
	if gather_job == &"":
		return
	gather_erasing = value
	gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)
	changed.emit()


func adjust_gather_radius(delta: int) -> void:
	var next := clampi(gather_radius + delta, GATHER_RADIUS_MIN, GATHER_RADIUS_MAX)
	if next == gather_radius:
		return
	gather_radius = next
	gather_mode_changed.emit(gather_job, gather_erasing, gather_radius)
	changed.emit()


## Apply the current circular brush. Adding only marks resources that this job can
## actually harvest; erasing clears every marked cell under the brush.
func paint_gather(center_cell: int, erase_override: int = -1) -> bool:
	if gather_job == &"" or not World.grid.is_valid_index(center_cell):
		return false
	var job := Jobs.get_job(gather_job)
	if job == null:
		return false
	var erasing := gather_erasing if erase_override < 0 else erase_override != 0
	var center := World.grid.coord(center_cell)
	var changed_any := false
	# A resource category is one player order even when both the basic and advanced
	# versions of a job can work it. Mirror the brush into every job sharing a
	# target feature so a Lumberer never ignores an area marked for Woodcutters.
	for related_job: JobDef in _related_gather_jobs(job):
		var mask: PackedByteArray = gather_designations.get(
			related_job.id, PackedByteArray())
		if mask.size() != World.grid.cell_count:
			mask.resize(World.grid.cell_count)
		for dy in range(-gather_radius, gather_radius + 1):
			for dx in range(-gather_radius, gather_radius + 1):
				if dx * dx + dy * dy > gather_radius * gather_radius:
					continue
				var point := center + Vector2i(dx, dy)
				if not World.grid.is_valid_v(point):
					continue
				var cell := World.grid.index_v(point)
				var next := 0 if erasing else (
					1 if related_job.harvests(World.feature_at(cell)) else int(mask[cell]))
				if int(mask[cell]) == next:
					continue
				mask[cell] = next
				changed_any = true
		gather_designations[related_job.id] = mask
	if changed_any:
		for villager in Colony.villagers:
			if is_instance_valid(villager) \
					and villager.job in gather_designations:
				villager.think_urgent = true
		changed.emit()
	return changed_any


func _related_gather_jobs(active: JobDef) -> Array[JobDef]:
	var related: Array[JobDef] = []
	for candidate: JobDef in Jobs.all():
		if candidate.target_features.is_empty():
			continue
		for feature in active.target_features:
			if feature in candidate.target_features:
				related.append(candidate)
				break
	return related


func gathering_is_designated(job_id: StringName, cell: int) -> bool:
	if not World.grid.is_valid_index(cell) or not gather_designations.has(job_id):
		return false
	var mask: PackedByteArray = gather_designations[job_id]
	return cell < mask.size() and mask[cell] != 0


func gathering_count(job_id: StringName) -> int:
	if not gather_designations.has(job_id):
		return 0
	var total := 0
	var mask: PackedByteArray = gather_designations[job_id]
	for value in mask:
		if value != 0:
			total += 1
	return total


func _on_terrain_changed(cell: int) -> void:
	if not World.grid.is_valid_index(cell) \
			or World.feature_at(cell) != Terrain.Feature.NONE:
		return
	var changed_any := false
	for job_id in gather_designations:
		var mask: PackedByteArray = gather_designations[job_id]
		if cell < mask.size() and mask[cell] != 0:
			mask[cell] = 0
			gather_designations[job_id] = mask
			changed_any = true
	if changed_any:
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
