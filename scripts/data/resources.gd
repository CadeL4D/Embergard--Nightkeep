class_name Resources
extends RefCounted
## Lazy data catalog for the Update 2d redesign's physical resource graph.

const RESOURCE_DIR := "res://content/resources"
static var _catalog: Dictionary = {}
static var _ordered: Array[ResourceDef] = []
static var _loaded := false


static func get_resource(id: StringName) -> ResourceDef:
	_ensure_loaded()
	return _catalog.get(id)


static func all() -> Array[ResourceDef]:
	_ensure_loaded()
	return _ordered


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(RESOURCE_DIR)
	if dir == null:
		push_error("Resources: cannot open %s" % RESOURCE_DIR)
		return
	for file in dir.get_files():
		var filename := file.trim_suffix(".remap")
		if not filename.ends_with(".tres"):
			continue
		var loaded := load(RESOURCE_DIR + "/" + filename)
		if loaded is ResourceDef and not loaded.id.is_empty():
			_catalog[loaded.id] = loaded
			_ordered.append(loaded)
	_ordered.sort_custom(func(a: ResourceDef, b: ResourceDef) -> bool:
		return a.display_order < b.display_order)
