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


## Buildings that can EVER appear in the build menu, before in-run gates.
##
## Two things are filtered out, both derived from properties rather than from an id:
##   * the founding Village Center — a centre with no `upgrades_from` is the one the run itself
##     places, and it cannot be built a second time
##   * upgrade targets — those are reached by tapping the building they replace, so listing them
##     as separate cards would offer the player a Great Hall they cannot place anywhere
## and anything still behind Relic Shards.
static func in_menu() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for def: BuildingDef in all():
		if def.menu_hidden:
			continue
		if def.center_tier > 0 and def.upgrades_from.is_empty():
			continue
		if not def.upgrades_from.is_empty():
			continue
		if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
			continue
		out.append(def)
	return out


## Buildings the player may place right now — the menu list, minus anything the colony has not
## yet earned. Kept separate from in_menu() because a locked-by-tier card is still SHOWN, just
## disabled: a player has to be able to see that a Smelter exists and what it needs.
static func placeable() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for def: BuildingDef in in_menu():
		if not unlocked_in_run(def):
			continue
		out.append(def)
	return out


## Whether the colony has met this building's in-run gates: Village Center tier and headcount.
static func unlocked_in_run(def: BuildingDef) -> bool:
	if def == null:
		return false
	return def.tier <= Colony.center_tier() and def.min_population <= Colony.population()


## The definition that upgrades in place from `id`, or null. At most one per building by
## convention — a branching upgrade tree would need the player to choose, which is a whole
## second UI for very little.
static func upgrade_for(id: StringName) -> BuildingDef:
	if id.is_empty():
		return null
	for def: BuildingDef in all():
		if def.upgrades_from == id:
			return def
	return null


## Tab names in menu order, derived from the content rather than declared.
##
## Ordered by the lowest `order` in each category, so the same single number that sorts cards
## inside a tab also sorts the tabs themselves. Nothing to keep in step, and dropping in a
## building with a new category grows the tab strip on its own.
static func categories() -> Array[StringName]:
	var first: Dictionary = {}
	var out: Array[StringName] = []
	for def: BuildingDef in in_menu():
		var key := def.category if not def.category.is_empty() else &"logistics"
		if not first.has(key):
			first[key] = def.order
			out.append(key)
		else:
			first[key] = mini(first[key], def.order)
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return int(first[a]) < int(first[b]))
	return out


static func in_category(category: StringName) -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for def: BuildingDef in in_menu():
		var key := def.category if not def.category.is_empty() else &"logistics"
		if key == category:
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
