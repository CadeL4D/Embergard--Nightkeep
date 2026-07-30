class_name Difficulties
extends RefCounted
## Catalog of difficulty tiers, loaded from res://content/difficulties/ on first use.
## Same lazily-scanned static pattern as Powers and Buildings.
##
## Also holds the tier the CURRENT run is being played on. That lives here as static
## state rather than in a new autoload because it is one value read from a handful of
## places, and because a run's difficulty is settled the moment the world is created and
## never changes again — there is nothing for an autoload's lifecycle to manage.
##
## Call sites use the terse accessors at the bottom (threat_mult(), needs_mult(), …)
## rather than touching `current` directly. They fall back to 1.0 when nothing has been
## selected, which keeps every headless test and dev scene working without having to
## know difficulty exists.

const DIFFICULTY_DIR := "res://content/difficulties"

## The tier every run defaults to if nothing chooses one.
const DEFAULT_ID := &"harried"

static var _catalog: Dictionary = {}
static var _ordered: Array[DifficultyDef] = []
static var _loaded: bool = false

## The tier the current run is on. Null until a world is created.
static var current: DifficultyDef = null


static func get_difficulty(id: StringName) -> DifficultyDef:
	_ensure_loaded()
	return _catalog.get(id)


## Every tier in menu order, easiest first.
static func all() -> Array[DifficultyDef]:
	_ensure_loaded()
	return _ordered


## Choose the tier for a run. Falls back to the default, then to the first tier on
## file, so a bad id can never leave a run with no difficulty at all.
static func select(id: StringName) -> DifficultyDef:
	_ensure_loaded()
	var def: DifficultyDef = _catalog.get(id)
	if def == null:
		def = _catalog.get(DEFAULT_ID)
	if def == null and not _ordered.is_empty():
		def = _ordered[0]
	current = def
	return current


static func current_id() -> StringName:
	return current.id if current != null else DEFAULT_ID


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(DIFFICULTY_DIR)
	if dir == null:
		push_error("Difficulties: cannot open %s" % DIFFICULTY_DIR)
		return
	for f in dir.get_files():
		# Exported builds list some resources with a .remap suffix — strip it or the
		# catalog comes up empty outside the editor.
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(DIFFICULTY_DIR + "/" + fname)
		if res is DifficultyDef:
			var def: DifficultyDef = res
			if def.id.is_empty():
				push_warning("Difficulties: %s has no id — skipped" % fname)
				continue
			_catalog[def.id] = def
			_ordered.append(def)
	_ordered.sort_custom(func(a: DifficultyDef, b: DifficultyDef) -> bool: return a.order < b.order)


# --- Accessors -------------------------------------------------------------------------
# All default to the neutral value when no tier is selected, so nothing has to null-check.

static func threat_mult() -> float:
	return current.threat_mult if current != null else 1.0


static func blight_mult() -> float:
	return current.blight_mult if current != null else 1.0


static func needs_mult() -> float:
	return current.needs_mult if current != null else 1.0


static func migration_mult() -> float:
	return current.migration_mult if current != null else 1.0


static func shard_mult() -> float:
	return current.shard_mult if current != null else 1.0


static func start_pop_bonus() -> int:
	return current.start_pop_bonus if current != null else 0


static func monster_night_shift() -> int:
	return current.monster_night_shift if current != null else 0
