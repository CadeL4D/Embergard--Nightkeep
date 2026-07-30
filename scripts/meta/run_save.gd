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
## 2 added nest_hp. Nests became destructible, and a half-worn nest that healed back to
## full every time the player backgrounded the app would quietly undo hours of siege.
const SCHEMA_VERSION := 2


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
		"difficulty": String(Difficulties.current_id()),
		"tick": Sim.tick,
		"day": Sim.day,
		"phase": int(Sim.phase),
		"phase_elapsed": Sim.phase_elapsed,

		# Feature and blight are the only world layers the player actually changes.
		"feature": World.feature,
		"blight": World.blight,
		# Which nests are ALIVE is derived from the feature layer, but how worn down
		# they are is not recoverable from anything else.
		"nest_hp": World.nest_hp.duplicate(),
		# The Blight's own settlement. Not derivable from anything else: the generator lays out
		# nests, not what grew around them, so without this a reload hands the player back a map the
		# enemy had never developed — and the threat budget that came with it.
		"blight_structures": World.blight_structures.duplicate(true),
		"blight_growth": Threat.growth_progress(),

		"stock": Colony.stock.duplicate(),
		"reserved": Colony.reserved.duplicate(),
		"quotas": Colony.quotas.duplicate(),
		# Losing this on every autosave would mean a colony that saves each phase change
		# never quite reaches its next arrival.
		"migration_progress": Colony.migration_progress,

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
			"food": v.food, "water": v.water, "rest": v.rest, "mood": v.mood,
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

	# Difficulty first: it is read while the world and colony are being rebuilt, and a
	# run resumed on the wrong tier would silently change its own balance mid-play.
	Difficulties.select(StringName(data.get("difficulty", Difficulties.DEFAULT_ID)))

	# Regenerate the world from the seed, then overlay what the player changed.
	World.generate(int(data["seed"]))
	World.feature = data["feature"]
	World.blight = data["blight"]
	# Re-derive which nests survived from the overlaid feature layer, THEN restore how
	# worn each one was. Order matters: rebuild_nest_hp resets everything it finds to
	# full, so applying the saved values first would simply be overwritten.
	World.rebuild_nest_hp()
	for cell in data.get("nest_hp", {}):
		var key := int(cell)
		if World.nest_hp.has(key):
			World.nest_hp[key] = float(data["nest_hp"][cell])
	World.blight_field.rebuild_frontier()
	World.resources.setup(World)
	World.cost_dirty = true
	World.rebuild_move_cost()


	Colony.reset()
	Colony.stock = data["stock"].duplicate()
	Colony.reserved = data.get("reserved", {}).duplicate()
	Colony.quotas = data["quotas"].duplicate()
	Colony.migration_progress = float(data.get("migration_progress", 0.0))
	Colony.set_spawn_parent(entities)

	Divine.reset()
	Threat.reset()
	Threat.set_spawn_parent(entities)
	Threat.night_index = int(data.get("night_index", 0))
	Threat.set_growth_progress(float(data.get("blight_growth", 0.0)))

	# The Blight's settlement, restored AFTER Threat.reset() and not before.
	#
	# reset() clears World.blight_structures — it has to, or a previous world's spires would carry
	# into the next one as threat budget and as occupancy on empty ground. So this has to come after
	# it, and putting it up beside the nest_hp restore where it naturally belongs would have had
	# every structure silently wiped a few lines later.
	#
	# Rebuilt through add_blight_structure rather than by assigning the dictionary, so each one
	# re-stamps its occupancy and re-adds its glow; a direct assignment would leave the enemy's
	# buildings visible but walk-through — obstacles in the save and not in the world.
	for cell in data.get("blight_structures", {}):
		var at := int(cell)
		var row: Dictionary = data["blight_structures"][cell]
		var struct_def := BlightStructures.get_structure(StringName(row["kind"]))
		if struct_def == null or not World.add_blight_structure(at, struct_def):
			continue
		# Wear applied after, for the same reason nest_hp is: raising one sets it to full.
		World.blight_structures[at]["hp"] = float(row.get("hp", struct_def.max_hp))

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
		v.water = float(row.get("water", 80.0))
		v.rest = float(row.get("rest", 80.0))
		v.mood = float(row.get("mood", 60.0))
		v.health = float(row.get("health", v.max_health))
