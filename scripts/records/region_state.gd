class_name RegionState
extends RefCounted
## Stable 45-region campaign record, independent from the rendered world-map scene.

enum Status { UNSETTLED, SETTLED, LOST, PURIFIED }

var id: StringName = &""
var display_name: String = ""
var index: int = -1
var coord: Vector2i = Vector2i.ZERO
var biome: StringName = &"forest"
var connections: Array[StringName] = []
var status: Status = Status.UNSETTLED
var local_seed: int = 0
var threat_modifier: float = 1.0
var settlement_day: int = 0
var state: Dictionary = {}


func to_dict() -> Dictionary:
	return {
		"id": id, "name": display_name, "index": index, "coord": coord, "biome": biome,
		"connections": connections.duplicate(), "status": int(status), "seed": local_seed,
		"threat_modifier": threat_modifier, "settlement_day": settlement_day,
		"state": state.duplicate(true),
	}


static func from_dict(data: Dictionary) -> RegionState:
	var region := RegionState.new()
	region.id = StringName(data.get("id", &""))
	region.display_name = String(data.get("name", region.id))
	region.index = int(data.get("index", -1))
	region.coord = data.get("coord", Vector2i.ZERO)
	region.biome = StringName(data.get("biome", &"forest"))
	region.connections.assign(data.get("connections", []))
	region.status = clampi(int(data.get("status", Status.UNSETTLED)), 0, Status.size() - 1) as Status
	region.local_seed = int(data.get("seed", 0))
	region.threat_modifier = maxf(float(data.get("threat_modifier", 1.0)), 0.0)
	region.settlement_day = maxi(int(data.get("settlement_day", 0)), 0)
	region.state = data.get("state", {}).duplicate(true)
	return region
