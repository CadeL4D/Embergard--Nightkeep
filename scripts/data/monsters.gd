class_name Monsters
extends RefCounted
## Catalog of every monster, loaded from res://content/monsters/ on first use.

const MONSTER_DIR := "res://content/monsters"

static var _catalog: Dictionary = {}
static var _ordered: Array[MonsterDef] = []
static var _loaded: bool = false


static func get_monster(id: StringName) -> MonsterDef:
	_ensure_loaded()
	return _catalog.get(id)


static func all() -> Array[MonsterDef]:
	_ensure_loaded()
	return _ordered


## Everything the director may spend budget on tonight.
static func eligible(night: int) -> Array[MonsterDef]:
	var out: Array[MonsterDef] = []
	for def: MonsterDef in all():
		if night >= def.min_night:
			out.append(def)
	return out


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(MONSTER_DIR)
	if dir == null:
		push_error("Monsters: cannot open %s" % MONSTER_DIR)
		return
	for f in dir.get_files():
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(MONSTER_DIR + "/" + fname)
		if res is MonsterDef:
			var def: MonsterDef = res
			if def.id.is_empty():
				push_warning("Monsters: %s has no id — skipped" % fname)
				continue
			_catalog[def.id] = def
			_ordered.append(def)
	_ordered.sort_custom(func(a: MonsterDef, b: MonsterDef) -> bool:
		return a.threat_cost < b.threat_cost)
