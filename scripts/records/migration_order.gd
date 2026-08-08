class_name MigrationOrder
extends RefCounted
## Next-dawn founding order with explicit migrants and Courier Golem cargo.

var order_id: int = 0
var source_id: StringName = &""
var destination_id: StringName = &""
var migrants: Array[Dictionary] = []
var courier_golems: int = 0
var cargo: Dictionary = {}
var ordered_day: int = 0
var departure_day: int = 0
var status: StringName = &"scheduled"


func to_dict() -> Dictionary:
	return {
		"id": order_id, "source": source_id, "destination": destination_id,
		"migrants": migrants.duplicate(true), "courier_golems": courier_golems,
		"cargo": cargo.duplicate(true), "ordered_day": ordered_day,
		"departure_day": departure_day, "status": status,
	}


static func from_dict(data: Dictionary) -> MigrationOrder:
	var order := MigrationOrder.new()
	order.order_id = int(data.get("id", 0))
	order.source_id = StringName(data.get("source", &""))
	order.destination_id = StringName(data.get("destination", &""))
	order.migrants.assign(data.get("migrants", []))
	order.courier_golems = maxi(int(data.get("courier_golems", 0)), 0)
	order.cargo = data.get("cargo", {}).duplicate(true)
	order.ordered_day = maxi(int(data.get("ordered_day", 0)), 0)
	order.departure_day = maxi(int(data.get("departure_day", order.ordered_day + 1)), 0)
	order.status = StringName(data.get("status", &"scheduled"))
	return order
