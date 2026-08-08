extends Node
## Versioned Update 2d parity ledger and cross-catalog validator.
##
## Content remains authored in ordinary Godot resources. This service builds one immutable
## inspection surface, records the verification state of every row, and catches the expensive
## class of errors where a consumer exists without a producer, an upgrade points at nothing, a
## tower has no ammunition, localization is missing, or two definitions share an id.

const TARGET_VERSION := "Rise to Ruins Update 2d"
const LEDGER_PATH := "res://content/parity/update2d_manifest.json"

var manifest: Dictionary = {}
var validation_issues := PackedStringArray()
var ledger_entries: Array[Dictionary] = []


func _ready() -> void:
	_load_manifest()
	_build_ledger()
	validation_issues.append_array(validate_all())
	for issue in validation_issues:
		push_error("BalanceCatalog: %s" % issue)
	assert(validation_issues.is_empty(), "Update 2d balance catalogs are structurally invalid")


func _load_manifest() -> void:
	if not FileAccess.file_exists(LEDGER_PATH):
		validation_issues.append("missing parity ledger %s" % LEDGER_PATH)
		return
	var file := FileAccess.open(LEDGER_PATH, FileAccess.READ)
	if file == null:
		validation_issues.append("cannot open parity ledger")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		validation_issues.append("parity ledger is not a dictionary")
		return
	manifest = parsed


func validate_all() -> PackedStringArray:
	var issues := PackedStringArray()
	if manifest.is_empty():
		issues.append("Update 2d parity manifest did not load")
	elif String(manifest.get("target_version", "")) != TARGET_VERSION:
		issues.append("parity manifest targets the wrong release")
	_validate_unique_catalog(Resources.all(), "resource", issues)
	_validate_unique_catalog(Jobs.all(), "job", issues)
	_validate_unique_catalog(Buildings.all(), "building", issues)
	_validate_unique_catalog(Powers.all(), "power", issues)
	_validate_unique_catalog(Monsters.all(), "creature", issues)
	_validate_recipes(issues)
	_validate_upgrades(issues)
	_validate_towers(issues)
	_validate_localization(issues)
	return issues


func is_valid() -> bool:
	return validation_issues.is_empty()


func source_for(key: String) -> Dictionary:
	return manifest.get("constants", {}).get(key, {})


func mobile_deviations() -> Array:
	return manifest.get("mobile_deviations", [])


func entries(kind: StringName = &"") -> Array[Dictionary]:
	if kind.is_empty():
		return ledger_entries.duplicate(true)
	var out: Array[Dictionary] = []
	for row in ledger_entries:
		if StringName(row.get("kind", &"")) == kind:
			out.append(row.duplicate(true))
	return out


func get_entry(kind: StringName, id: StringName) -> Dictionary:
	for row in ledger_entries:
		if StringName(row.get("kind", &"")) == kind and StringName(row.get("id", &"")) == id:
			return row.duplicate(true)
	return {}


## Structurally implemented rows whose Update 2d numbers have not been checked against an
## observable build/tool-tip. Tests can run with these rows; a parity release cannot sign off.
func verification_blockers() -> Array[Dictionary]:
	var statuses: Array = manifest.get("catalog_policy", {}).get("blocking_statuses", [])
	var out: Array[Dictionary] = []
	for row in ledger_entries:
		if String(row.get("status", "unknown")) in statuses:
			out.append(row.duplicate(true))
	return out


func _build_ledger() -> void:
	ledger_entries.clear()
	for resource: ResourceDef in Resources.all():
		_add_entry(&"resource", resource.id, resource.resource_path)
	for job: JobDef in Jobs.all():
		_add_entry(&"job", job.id, job.resource_path)
		if not job.cycle_cost.is_empty() or not job.cycle_yield.is_empty() \
				or not job.loose_yield_kind.is_empty() or not job.item_yield.is_empty():
			_add_entry(&"recipe", job.id, job.resource_path)
	for building: BuildingDef in Buildings.all():
		_add_entry(&"building", building.id, building.resource_path)
		if not building.upgrades_from.is_empty():
			_add_entry(&"upgrade", building.id, building.resource_path)
	for power: PowerDef in Powers.all():
		_add_entry(&"power", power.id, power.resource_path)
	for creature: MonsterDef in Monsters.all():
		_add_entry(&"creature", creature.id, creature.resource_path)
	for event_id: StringName in Storyteller.EVENT_IDS:
		_add_entry(&"event", event_id, "res://scripts/story/storyteller.gd")
	for biome_id: StringName in [&"forest", &"desert", &"marsh", &"dry_lands", &"haven", &"outlands"]:
		_add_entry(&"biome", biome_id, "res://scripts/world/biomes.gd")
	for goal: Dictionary in Chronicle.all():
		_add_entry(&"goal", StringName(goal["id"]), "res://scripts/meta/chronicle.gd")


func _add_entry(kind: StringName, id: StringName, implementation_source: String) -> void:
	var catalog_row: Dictionary = manifest.get("catalogs", {}).get(String(kind), {})
	var override: Dictionary = manifest.get("entry_overrides", {}).get(
		"%s:%s" % [kind, id], {})
	var source_key := String(override.get("source", "project_definition"))
	var source := String(manifest.get("sources", {}).get(source_key, implementation_source))
	ledger_entries.append({
		"kind": kind,
		"id": id,
		"target_version": TARGET_VERSION,
		"unit": String(override.get("unit", catalog_row.get("unit", "definition"))),
		"status": String(override.get("status", catalog_row.get("status", "unknown"))),
		"source": source,
		"implementation_source": implementation_source,
		"verified_on": String(override.get("verified_on", manifest.get("verified_on", ""))),
	})


func _validate_unique_catalog(rows: Array, label: String, issues: PackedStringArray) -> void:
	var seen: Dictionary = {}
	for row in rows:
		if row == null:
			issues.append("null %s definition" % label)
			continue
		var id: StringName = row.id
		if id.is_empty():
			issues.append("%s definition has an empty id" % label)
		elif seen.has(id):
			issues.append("duplicate %s id %s" % [label, id])
		else:
			seen[id] = true


func _validate_recipes(issues: PackedStringArray) -> void:
	var produced: Dictionary = {}
	for resource: ResourceDef in Resources.all():
		if resource.category == &"raw":
			produced[resource.id] = true
	for job: JobDef in Jobs.all():
		for raw_kind in job.cycle_yield:
			produced[StringName(raw_kind)] = true
		if not job.loose_yield_kind.is_empty() and job.loose_yield_kind != &"essence":
			produced[job.loose_yield_kind] = true
	for job: JobDef in Jobs.all():
		for raw_kind in job.cycle_cost:
			var kind := StringName(raw_kind)
			if Resources.get_resource(kind) == null:
				issues.append("job %s consumes unknown resource %s" % [job.id, kind])
			elif not produced.has(kind):
				issues.append("resource %s is consumed but has no producer" % kind)
	for building: BuildingDef in Buildings.all():
		if not building.ammo_kind.is_empty() and not produced.has(building.ammo_kind):
			issues.append("tower %s consumes %s but no job produces it" % [
				building.id, building.ammo_kind])


func _validate_upgrades(issues: PackedStringArray) -> void:
	for building: BuildingDef in Buildings.all():
		if building.upgrades_from.is_empty():
			continue
		var parent := Buildings.get_building(building.upgrades_from)
		if parent == null:
			issues.append("upgrade %s has missing parent %s" % [building.id, building.upgrades_from])
			continue
		if parent.footprint != building.footprint:
			issues.append("upgrade %s changes footprint from %s" % [building.id, parent.id])
		var seen: Dictionary = {building.id: true}
		var cursor: BuildingDef = parent
		while cursor != null and not cursor.upgrades_from.is_empty():
			if seen.has(cursor.id):
				issues.append("upgrade cycle reaches %s" % cursor.id)
				break
			seen[cursor.id] = true
			cursor = Buildings.get_building(cursor.upgrades_from)


func _validate_towers(issues: PackedStringArray) -> void:
	for building: BuildingDef in Buildings.all():
		if building.attack_damage <= 0.0:
			continue
		if building.ammo_per_shot > 0 and building.ammo_kind.is_empty():
			issues.append("tower %s consumes unnamed ammunition" % building.id)
		if not building.ammo_kind.is_empty() and Resources.get_resource(building.ammo_kind) == null:
			issues.append("tower %s references unknown ammunition %s" % [
				building.id, building.ammo_kind])
		if building.energy_per_shot < 0:
			issues.append("tower %s has invalid Energy cost" % building.id)


func _validate_localization(issues: PackedStringArray) -> void:
	for resource: ResourceDef in Resources.all():
		_validate_key(resource.display_name, "resource %s" % resource.id, issues)
	for job: JobDef in Jobs.all():
		_validate_key(job.display_name, "job %s" % job.id, issues)
	for building: BuildingDef in Buildings.all():
		_validate_key(building.display_name, "building %s" % building.id, issues)
		_validate_key(building.description, "building %s description" % building.id, issues)
	for power: PowerDef in Powers.all():
		_validate_key(power.display_name, "power %s" % power.id, issues)
		_validate_key(power.description, "power %s description" % power.id, issues)
	for creature: MonsterDef in Monsters.all():
		_validate_key(creature.display_name, "creature %s" % creature.id, issues)


func _validate_key(key: String, owner: String, issues: PackedStringArray) -> void:
	if key.is_empty() or not Locale.has_key(StringName(key)):
		issues.append("%s has missing localization %s" % [owner, key])
