class_name RunSave
extends RefCounted
## Serialisation for an in-progress run.
##
## Android kills backgrounded apps without warning, and a rogue-lite that loses a
## forty-minute run to a phone call is a one-star review. So: autosave on every
## phase change and on application pause, and write to a temp file then rename, so
## a kill mid-write cannot corrupt the save.
##
## DERIVED STATE IS NEVER SAVED. Terrain regenerates from the seed; occupancy,
## move cost, the light grid, the flow field and the resource index are all rebuilt
## from the things that are saved. That halves the file and — more importantly —
## makes it impossible for a save to encode a world that disagrees with itself.

const SAVE_PATH := "user://run.dat"
const TEMP_PATH := "user://run.tmp"
const SCHEMA_VERSION := 1


static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


static func clear() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


# --- Writing ------------------------------------------------------------------------

static func save() -> bool:
	var data := {
		"version": SCHEMA_VERSION,
		"seed": World.seed_value,
		"tick": Sim.tick,
		"day": Sim.day,
		"phase": int(Sim.phase),
		"phase_elapsed": Sim.phase_elapsed,

		# Feature and blight are the only world layers the player actually changes.
		"feature": World.feature,
		"blight": World.blight,

		"stock": Colony.stock.duplicate(),
		"reserved": Colony.reserved.duplicate(),
		"quotas": Colony.quotas.duplicate(),

		"faith": Divine.faith,
		"ember_cell": Divine.ember_cell,

		"night_index": Threat.night_index,

		"villagers": _pack_villagers(),
		"buildings": _pack_buildings(),
	}

	# Temp-then-rename, so a process kill part way through leaves the previous save
	# intact rather than a half-written file that will not load.
	var f := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	if f == null:
		push_error("RunSave: cannot open %s" % TEMP_PATH)
		return false
	f.store_var(data)
	f.close()

	var dir := DirAccess.open("user://")
	if dir == null:
		return false
	if dir.file_exists("run.dat"):
		dir.remove("run.dat")
	return dir.rename("run.tmp", "run.dat") == OK


static func _pack_villagers() -> Array:
	var out: Array = []
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		out.append({
			"x": v.position.x, "y": v.position.y,
			"job": v.job,
			"food": v.food, "rest": v.rest, "mood": v.mood,
			"health": v.health,
		})
	return out


static func _pack_buildings() -> Array:
	var out: Array = []
	for b in Colony.buildings:
		if not is_instance_valid(b):
			continue
		out.append({
			"def": b.def.id,
			"anchor": b.anchor,
			"complete": b.state == Building.State.COMPLETE,
			"work": b.work_done,
			"hp": b.hp,
			"delivered": b.delivered.duplicate(),
		})
	return out


# --- Reading ------------------------------------------------------------------------

## Restore a run into the given scene. Returns false if there is nothing valid to
## load, in which case the caller should start fresh.
static func load_into(run: Node, entities: Node) -> bool:
	if not has_save():
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var data = f.get_var()
	f.close()

	if typeof(data) != TYPE_DICTIONARY:
		push_warning("RunSave: save file is not a dictionary — ignoring")
		return false
	if int(data.get("version", 0)) != SCHEMA_VERSION:
		# No migrations exist yet. Refusing to load an old save is correct while the
		# format is still moving; silently loading a mismatched one is not.
		push_warning("RunSave: schema %s does not match %d — ignoring" % [
			data.get("version", "?"), SCHEMA_VERSION])
		return false

	# Regenerate the world from the seed, then overlay what the player changed.
	World.generate(int(data["seed"]))
	World.feature = data["feature"]
	World.blight = data["blight"]
	World.blight_field.rebuild_frontier()
	World.resources.setup(World)
	World.cost_dirty = true
	World.rebuild_move_cost()

	Colony.reset()
	Colony.stock = data["stock"].duplicate()
	Colony.reserved = data.get("reserved", {}).duplicate()
	Colony.quotas = data["quotas"].duplicate()

	Divine.reset()
	Threat.reset()
	Threat.set_spawn_parent(entities)
	Threat.night_index = int(data.get("night_index", 0))

	_restore_buildings(data.get("buildings", []), entities)
	_restore_villagers(data.get("villagers", []), entities)

	Divine.place_ember(int(data.get("ember_cell", World.keep_cell)))
	Divine.faith = float(data.get("faith", 20.0))

	Sim.start_run()
	Sim.tick = int(data.get("tick", 0))
	Sim.day = int(data.get("day", 1))
	Sim.set_phase(int(data.get("phase", Sim.Phase.DAY)))
	Sim.phase_elapsed = float(data.get("phase_elapsed", 0.0))

	Events.map_generated.emit()
	return true


static func _restore_buildings(rows: Array, entities: Node) -> void:
	var scene: PackedScene = load("res://scenes/entities/building.tscn")
	for row: Dictionary in rows:
		var def := Buildings.get_building(row["def"])
		if def == null:
			continue
		var b: Node = scene.instantiate()
		b.setup(def, int(row["anchor"]))
		b.delivered = row.get("delivered", {}).duplicate()
		b.work_done = float(row.get("work", 0.0))
		b.position = Colony._building_origin(def, int(row["anchor"]))
		entities.add_child(b)
		if bool(row.get("complete", false)):
			b.complete()
			b.hp = float(row.get("hp", def.max_hp))


static func _restore_villagers(rows: Array, entities: Node) -> void:
	var scene: PackedScene = load("res://scenes/entities/villager.tscn")
	for row: Dictionary in rows:
		var v: Villager = scene.instantiate()
		v.position = Vector2(float(row["x"]), float(row["y"]))
		entities.add_child(v)
		# Set after adding, because _ready resets health to max.
		v.job = row.get("job", &"")
		v.food = float(row.get("food", 80.0))
		v.rest = float(row.get("rest", 80.0))
		v.mood = float(row.get("mood", 60.0))
		v.health = float(row.get("health", v.max_health))
