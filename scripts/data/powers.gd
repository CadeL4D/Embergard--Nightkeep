class_name Powers
extends RefCounted
## Catalog of divine powers, loaded from res://content/powers/ on first use.

const POWER_DIR := "res://content/powers"

static var _catalog: Dictionary = {}
static var _ordered: Array[PowerDef] = []
static var _loaded: bool = false


static func get_power(id: StringName) -> PowerDef:
	_ensure_loaded()
	return _catalog.get(id)


static func all() -> Array[PowerDef]:
	_ensure_loaded()
	return _ordered


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(POWER_DIR)
	if dir == null:
		push_error("Powers: cannot open %s" % POWER_DIR)
		return
	for f in dir.get_files():
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(POWER_DIR + "/" + fname)
		if res is PowerDef:
			var def: PowerDef = res
			if def.id.is_empty():
				push_warning("Powers: %s has no id — skipped" % fname)
				continue
			_catalog[def.id] = def
			_ordered.append(def)
	_ordered.sort_custom(func(a: PowerDef, b: PowerDef) -> bool: return a.order < b.order)
