class_name WorkOrder
extends RefCounted
## Serializable spatial labor order shared by touch tools and villager AI.

enum Kind { HARVEST, CANCEL, DIG, DESTROY_TERRAIN, BUILD_ROAD, REMOVE_ROAD, DISMANTLE }
enum Shape { CIRCLE, SQUARE }

var order_id: int = 0
var kind: Kind = Kind.HARVEST
var cells: PackedInt32Array = PackedInt32Array()
var shape: Shape = Shape.CIRCLE
var brush_size: int = 1
var resource_filter: StringName = &""
var road_tier: int = 0
var priority: int = 0
var assigned_job: StringName = &""
var completed_cells: PackedInt32Array = PackedInt32Array()


func to_dict() -> Dictionary:
	return {
		"id": order_id, "kind": int(kind), "cells": cells, "shape": int(shape),
		"brush_size": brush_size, "resource_filter": resource_filter,
		"road_tier": road_tier, "priority": priority, "assigned_job": assigned_job,
		"completed_cells": completed_cells,
	}


static func from_dict(data: Dictionary) -> WorkOrder:
	var order := WorkOrder.new()
	order.order_id = int(data.get("id", 0))
	order.kind = clampi(int(data.get("kind", Kind.HARVEST)), 0, Kind.size() - 1) as Kind
	order.cells = PackedInt32Array(data.get("cells", []))
	order.shape = clampi(int(data.get("shape", Shape.CIRCLE)), 0, Shape.size() - 1) as Shape
	order.brush_size = clampi(int(data.get("brush_size", 1)), 1, 12)
	order.resource_filter = StringName(data.get("resource_filter", &""))
	order.road_tier = maxi(int(data.get("road_tier", 0)), 0)
	order.priority = int(data.get("priority", 0))
	order.assigned_job = StringName(data.get("assigned_job", &""))
	order.completed_cells = PackedInt32Array(data.get("completed_cells", []))
	return order
