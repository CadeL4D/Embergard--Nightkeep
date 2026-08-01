class_name ItemDef
extends Resource
## Lightweight equipment/consumable definition. Runtime instances are ItemRecord values.

@export var id: StringName = &""
@export var display_name: String = ""
@export var slot: StringName = &"tool"
@export var max_durability: int = 100
@export var modifiers: Dictionary = {}
@export var damage: Dictionary = {}
@export var resistances: Dictionary = {}
@export var job_tags: Array[StringName] = []
@export var consumable_effect: Dictionary = {}
@export var order: int = 0


func supports_job(tags: Array[StringName]) -> bool:
	if job_tags.is_empty():
		return true
	for tag in tags:
		if tag in job_tags:
			return true
	return false
