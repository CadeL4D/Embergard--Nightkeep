extends Node
## Persistent spatial labor orders shared by touch brushes, desktop controls and Waymaker AI.

signal changed
signal tool_changed(active_kind: int, brush_size: int, shape: WorkOrder.Shape)

var orders: Array[WorkOrder] = []
var _claims: Dictionary = {} # cell -> worker instance id
var _next_id: int = 1
var active_kind: int = -1
var active_brush_size: int = 2
var active_shape: WorkOrder.Shape = WorkOrder.Shape.CIRCLE
var active_priority: int = 0
var active_road_tier: int = 1


func reset() -> void:
	orders.clear()
	_claims.clear()
	_next_id = 1
	cancel_tool()
	changed.emit()


func begin_tool(kind: WorkOrder.Kind, brush_size: int = 2,
		shape: WorkOrder.Shape = WorkOrder.Shape.CIRCLE, priority: int = 0,
		road_tier: int = 1) -> void:
	DefenseControl.cancel_gather_paint()
	DefenseControl.cancel_paint()
	active_kind = int(kind)
	active_brush_size = clampi(brush_size, 1, 12)
	active_shape = shape
	active_priority = priority
	active_road_tier = clampi(road_tier, 1, 3)
	tool_changed.emit(active_kind, active_brush_size, active_shape)


func cancel_tool() -> void:
	if active_kind == -1:
		return
	active_kind = -1
	tool_changed.emit(active_kind, active_brush_size, active_shape)


func adjust_active_brush(delta: int) -> void:
	active_brush_size = clampi(active_brush_size + delta, 1, 12)
	tool_changed.emit(active_kind, active_brush_size, active_shape)


func toggle_active_shape() -> void:
	active_shape = WorkOrder.Shape.SQUARE if active_shape == WorkOrder.Shape.CIRCLE \
		else WorkOrder.Shape.CIRCLE
	tool_changed.emit(active_kind, active_brush_size, active_shape)


func paint_active(center: int, cancel_override: bool = false) -> WorkOrder:
	if active_kind < 0:
		return null
	var kind := WorkOrder.Kind.CANCEL if cancel_override else active_kind as WorkOrder.Kind
	return paint(kind, center, active_brush_size, active_shape, active_priority,
		&"", active_road_tier)


func paint(kind: WorkOrder.Kind, center: int, brush_size: int = 1,
		shape: WorkOrder.Shape = WorkOrder.Shape.CIRCLE, priority: int = 0,
		resource_filter: StringName = &"", road_tier: int = 1) -> WorkOrder:
	if not World.grid.is_valid_index(center):
		return null
	var cells := brush_cells(center, brush_size, shape)
	if kind == WorkOrder.Kind.CANCEL:
		cancel_cells(cells)
		return null
	if kind == WorkOrder.Kind.HARVEST:
		DefenseControl.designate_gather_cells(resource_filter, cells, false)
		return null
	var order := WorkOrder.new()
	order.order_id = _next_id
	_next_id += 1
	order.kind = kind
	order.cells = cells
	order.shape = shape
	order.brush_size = clampi(brush_size, 1, 12)
	order.resource_filter = resource_filter
	order.road_tier = clampi(road_tier, 1, 3)
	order.priority = priority
	order.assigned_job = &"waymaker"
	orders.append(order)
	orders.sort_custom(func(a: WorkOrder, b: WorkOrder) -> bool:
		return a.priority > b.priority or (a.priority == b.priority and a.order_id < b.order_id))
	changed.emit()
	return order


func brush_cells(center: int, brush_size: int,
		shape: WorkOrder.Shape = WorkOrder.Shape.CIRCLE) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not World.grid.is_valid_index(center):
		return out
	var radius := clampi(brush_size, 1, 12) - 1
	var origin := World.grid.coord(center)
	for y in range(origin.y - radius, origin.y + radius + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			var delta := Vector2i(x, y) - origin
			if shape == WorkOrder.Shape.CIRCLE and delta.length_squared() > radius * radius:
				continue
			var coord := Vector2i(x, y)
			if World.grid.is_valid_v(coord):
				out.append(World.grid.index_v(coord))
	return out


func cancel_cells(cells: PackedInt32Array) -> void:
	for order in orders.duplicate():
		var kept := PackedInt32Array()
		for cell in order.cells:
			if cell not in cells and cell not in order.completed_cells:
				kept.append(cell)
			else:
				_claims.erase(cell)
		order.cells = kept
		order.completed_cells = PackedInt32Array()
		if order.cells.is_empty():
			orders.erase(order)
	changed.emit()


func claim_nearest(from: int, who: Object) -> Dictionary:
	var best_order: WorkOrder = null
	var best_cell := -1
	var best_score := 0x7FFFFFFF
	for order in orders:
		for cell in order.cells:
			if cell in order.completed_cells or _claims.has(cell) or not _is_actionable(order, cell):
				continue
			var score := World.grid.dist_sq(from, cell) - order.priority * 10000
			if score < best_score:
				best_score = score
				best_order = order
				best_cell = cell
	if best_order == null:
		return {}
	_claims[best_cell] = who.get_instance_id()
	return {"order_id": best_order.order_id, "cell": best_cell,
		"work": work_required(best_order.kind)}


func release_claim(order_id: int, cell: int, who: Object) -> void:
	if int(_claims.get(cell, 0)) == who.get_instance_id():
		_claims.erase(cell)


func complete(order_id: int, cell: int, who: Object) -> bool:
	var order := _find_order(order_id)
	if order == null or cell not in order.cells:
		release_claim(order_id, cell, who)
		return false
	var completed := _apply(order, cell)
	_claims.erase(cell)
	if completed and cell not in order.completed_cells:
		order.completed_cells.append(cell)
	if order.completed_cells.size() >= order.cells.size():
		orders.erase(order)
	changed.emit()
	return completed


func work_required(kind: WorkOrder.Kind) -> float:
	match kind:
		WorkOrder.Kind.DIG: return 12.0
		WorkOrder.Kind.DESTROY_TERRAIN: return 9.0
		WorkOrder.Kind.BUILD_ROAD: return 6.0
		WorkOrder.Kind.REMOVE_ROAD: return 5.0
		WorkOrder.Kind.DISMANTLE: return 8.0
	return 4.0


func to_dict() -> Dictionary:
	var rows: Array = []
	for order in orders:
		rows.append(order.to_dict())
	return {"next_id": _next_id, "orders": rows}


func load_dict(data: Dictionary) -> void:
	orders.clear()
	_claims.clear()
	_next_id = maxi(int(data.get("next_id", 1)), 1)
	for row: Dictionary in data.get("orders", []):
		orders.append(WorkOrder.from_dict(row))
	changed.emit()


func _find_order(id: int) -> WorkOrder:
	for order in orders:
		if order.order_id == id:
			return order
	return null


func _is_actionable(order: WorkOrder, cell: int) -> bool:
	match order.kind:
		WorkOrder.Kind.DIG:
			return World.terrain_at(cell) not in [Terrain.Type.DEEP_WATER, Terrain.Type.WATER]
		WorkOrder.Kind.DESTROY_TERRAIN:
			return World.feature_at(cell) != Terrain.Feature.NONE
		WorkOrder.Kind.BUILD_ROAD:
			return World.path_tier[cell] < order.road_tier and World.is_walkable(cell)
		WorkOrder.Kind.REMOVE_ROAD:
			return World.path_tier[cell] > 0
		WorkOrder.Kind.DISMANTLE:
			return Colony.building_covering(cell) != null
	return false


func _apply(order: WorkOrder, cell: int) -> bool:
	match order.kind:
		WorkOrder.Kind.DIG:
			World.clear_feature(cell)
			World.set_terrain_type(cell, Terrain.Type.DIRT)
			return true
		WorkOrder.Kind.DESTROY_TERRAIN:
			World.clear_feature(cell)
			return true
		WorkOrder.Kind.BUILD_ROAD:
			var road_id: StringName = &"path" if order.road_tier <= 1 else &"road"
			var road := Buildings.get_building(road_id)
			return Colony.place_building(road, cell, Colony._spawn_parent) != null
		WorkOrder.Kind.REMOVE_ROAD:
			var road_building := Colony.building_covering(cell)
			if road_building != null and road_building.def.path_tier > 0:
				return Colony.demolish_building(road_building)
			World.set_path_tier(PackedInt32Array([cell]), 0)
			return true
		WorkOrder.Kind.DISMANTLE:
			return Colony.demolish_building(Colony.building_covering(cell))
	return false
