class_name BlightStructures
extends RefCounted
## Catalog of the Blight's own buildings, loaded from res://content/blight/ on first use.
## Same lazily-scanned static pattern as Jobs, Buildings, Powers, Monsters and Tomes.

const BLIGHT_DIR := "res://content/blight"

static var _catalog: Dictionary = {}
static var _ordered: Array[BlightStructureDef] = []
static var _loaded: bool = false


static func get_structure(id: StringName) -> BlightStructureDef:
	_ensure_loaded()
	return _catalog.get(id)


static func all() -> Array[BlightStructureDef]:
	_ensure_loaded()
	return _ordered


## Weighted pick among the kinds eligible on this night. Returns null before anything is.
##
## Mirrors the threat director's own composition roll rather than inventing a second way to choose
## content, so `min_night` and `weight` mean the same thing here as they do for monsters.
static func roll(night: int, rng: RandomNumberGenerator = null) -> BlightStructureDef:
	var eligible: Array[BlightStructureDef] = []
	var total := 0.0
	for def: BlightStructureDef in all():
		if def.min_night <= night and def.weight > 0.0:
			eligible.append(def)
			total += def.weight
	if eligible.is_empty():
		return null
	var pick := (rng.randf() if rng != null else randf()) * total
	for def: BlightStructureDef in eligible:
		pick -= def.weight
		if pick <= 0.0:
			return def
	return eligible[eligible.size() - 1]


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(BLIGHT_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(BLIGHT_DIR + "/" + fname)
		if res is BlightStructureDef:
			var def: BlightStructureDef = res
			if def.id.is_empty():
				push_warning("BlightStructures: %s has no id — skipped" % fname)
				continue
			_catalog[def.id] = def
			_ordered.append(def)
	_ordered.sort_custom(func(a: BlightStructureDef, b: BlightStructureDef) -> bool:
		return a.order < b.order)
