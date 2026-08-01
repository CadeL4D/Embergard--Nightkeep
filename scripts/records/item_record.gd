class_name ItemRecord
extends RefCounted
## Serializable runtime item. Kept out of the scene tree even when equipped.

var uid: String = ""
var def_id: StringName = &""
var durability: int = 0
var modifiers: Dictionary = {}


static func create(item_def: ItemDef, stable_uid: String) -> ItemRecord:
	var record := ItemRecord.new()
	record.uid = stable_uid
	if item_def != null:
		record.def_id = item_def.id
		record.durability = item_def.max_durability
	return record


func to_dict() -> Dictionary:
	return {
		"uid": uid,
		"def": def_id,
		"durability": durability,
		"modifiers": modifiers.duplicate(true),
	}


static func from_dict(data: Dictionary) -> ItemRecord:
	var record := ItemRecord.new()
	record.uid = String(data.get("uid", ""))
	record.def_id = StringName(data.get("def", &""))
	var item_def := Items.get_item(record.def_id)
	record.durability = int(data.get("durability", item_def.max_durability if item_def != null else 0))
	record.modifiers = data.get("modifiers", {}).duplicate(true)
	return record
