class_name Items
extends RefCounted
## Lazy catalog of durable equipment and one-use supplies.

const ITEM_DIR := "res://content/items"
static var _catalog: Dictionary = {}
static var _ordered: Array[ItemDef] = []
static var _loaded := false


static func get_item(id: StringName) -> ItemDef:
	_ensure_loaded()
	return _catalog.get(id)


static func all() -> Array[ItemDef]:
	_ensure_loaded()
	return _ordered


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(ITEM_DIR)
	if dir == null:
		push_error("Items: cannot open %s" % ITEM_DIR)
		return
	for file in dir.get_files():
		var filename := file.trim_suffix(".remap")
		if not filename.ends_with(".tres"):
			continue
		var loaded := load(ITEM_DIR + "/" + filename)
		if loaded is ItemDef and not loaded.id.is_empty():
			_catalog[loaded.id] = loaded
			_ordered.append(loaded)
	_ordered.sort_custom(func(a: ItemDef, b: ItemDef) -> bool: return a.order < b.order)
