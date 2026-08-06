class_name SupplyRequest
extends RefCounted
## A promise to move one resource from a physical store into one building buffer.
##
## `reserved` includes goods still on a shelf and goods already in a carrier's arms. Keeping
## those two legs under one promise is what prevents a second Worker from fetching the same
## ammunition while the first is walking it across the map. `shelf_reserved` is runtime-only
## bookkeeping used to keep two collectors away from the same stack; saves rebuild it from the
## villagers that were actually carrying goods.

var id: int = 0
var destination: int = -1
var resource: StringName = &""
var target: int = 0
var reserved: int = 0
var priority: int = 0
var shelf_reserved: int = 0
var source: int = -1


func to_dict() -> Dictionary:
	return {
		"id": id,
		"destination": destination,
		"resource": resource,
		"target": target,
		"reserved": reserved,
		"priority": priority,
	}


static func from_dict(row: Dictionary) -> SupplyRequest:
	var request := SupplyRequest.new()
	request.id = int(row.get("id", 0))
	request.destination = int(row.get("destination", -1))
	request.resource = StringName(row.get("resource", &""))
	request.target = maxi(int(row.get("target", 0)), 0)
	request.reserved = maxi(int(row.get("reserved", 0)), 0)
	request.priority = int(row.get("priority", 0))
	return request
