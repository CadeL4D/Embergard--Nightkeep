class_name InventoryRecord
extends RefCounted
## Serializable numeric stacks plus lightweight item records.

var capacity: int = 0
var resources: Dictionary = {}
var items: Array[ItemRecord] = []


func to_dict() -> Dictionary:
	var packed_items: Array = []
	for item in items:
		packed_items.append(item.to_dict())
	return {
		"capacity": capacity,
		"resources": resources.duplicate(true),
		"items": packed_items,
	}


static func from_dict(data: Dictionary) -> InventoryRecord:
	var record := InventoryRecord.new()
	record.capacity = int(data.get("capacity", 0))
	record.resources = data.get("resources", {}).duplicate(true)
	for row in data.get("items", []):
		if typeof(row) == TYPE_DICTIONARY:
			record.items.append(ItemRecord.from_dict(row))
	return record
