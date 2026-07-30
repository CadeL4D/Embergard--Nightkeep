class_name Tomes
extends RefCounted
## Catalog of Tome archetypes, loaded from res://content/tomes/ on first use.
## Same lazily-scanned static pattern as Jobs, Buildings, Powers and Monsters.

const TOME_DIR := "res://content/tomes"

static var _catalog: Dictionary = {}
static var _ordered: Array[TomeDef] = []
static var _loaded: bool = false


static func get_tome(id: StringName) -> TomeDef:
	_ensure_loaded()
	return _catalog.get(id)


static func all() -> Array[TomeDef]:
	_ensure_loaded()
	return _ordered


## A random archetype, for a priest's next write. Uniform: which BOOK you get is meant to be luck,
## and the thing priests actually shift the odds of is its TIER (see Divine.scribe_tome).
static func random_archetype() -> TomeDef:
	var list := all()
	if list.is_empty():
		return null
	return list[randi() % list.size()]


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(TOME_DIR)
	if dir == null:
		# Not an error worth shouting about: a project with no tomes yet is a valid state, and the
		# Temple simply produces nothing until archetypes exist.
		return
	for f in dir.get_files():
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(TOME_DIR + "/" + fname)
		if res is TomeDef:
			var def: TomeDef = res
			if def.id.is_empty():
				push_warning("Tomes: %s has no id — skipped" % fname)
				continue
			_catalog[def.id] = def
			_ordered.append(def)
	_ordered.sort_custom(func(a: TomeDef, b: TomeDef) -> bool: return a.order < b.order)
