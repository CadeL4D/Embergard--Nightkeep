class_name ResourceDef
extends Resource
## One stackable colony commodity. Content owns display order, spoilage, and storage routing.

@export var id: StringName = &""
@export var display_name: String = ""
@export var category: StringName = &"raw"
@export var icon: Texture2D
@export var stack_size: int = 100
@export_range(0.0, 1.0) var spoilage_per_day: float = 0.0
@export var storage_tags: Array[StringName] = []
@export var display_order: int = 0


func matches_storage(tags: Array[StringName]) -> bool:
	if tags.is_empty():
		return true
	if id in tags or category in tags:
		return true
	for tag in storage_tags:
		if tag in tags:
			return true
	return false
