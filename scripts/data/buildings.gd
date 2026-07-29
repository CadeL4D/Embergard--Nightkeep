class_name Buildings
extends RefCounted
## Catalog of every building, loaded from res://content/buildings/ on first use.
## Same lazily-scanned static pattern as Jobs.

const BUILDING_DIR := "res://content/buildings"

static var _catalog: Dictionary = {}        # StringName -> BuildingDef
static var _ordered: Array[BuildingDef] = []
static var _loaded: bool = false


static func get_building(id: StringName) -> BuildingDef:
	_ensure_loaded()
	return _catalog.get(id)


## Every building in build-menu order.
static func all() -> Array[BuildingDef]:
	_ensure_loaded()
	return _ordered


## Buildings the player may place right now. The Hearth is excluded — it is placed
## once by the run itself and cannot be built again — as is anything still locked
## behind Relic Shards.
static func placeable() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for def: BuildingDef in all():
		if def.id == &"hearth":
			continue
		if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
			continue
		out.append(def)
	return out


## Everything still behind a shard cost, for the end-of-run screen.
static func locked() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for def: BuildingDef in all():
		if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
			out.append(def)
	return out


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(BUILDING_DIR)
	if dir == null:
		push_error("Buildings: cannot open %s" % BUILDING_DIR)
		return
	for f in dir.get_files():
		# Exported builds list some resources with a .remap suffix — strip it or
		# the catalog comes up empty outside the editor.
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(BUILDING_DIR + "/" + fname)
		if res is BuildingDef:
			var def: BuildingDef = res
			if def.id.is_empty():
				push_warning("Buildings: %s has no id — skipped" % fname)
				continue
			_catalog[def.id] = def
			_ordered.append(def)
	_ordered.sort_custom(func(a: BuildingDef, b: BuildingDef) -> bool: return a.order < b.order)
