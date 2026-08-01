class_name TradeRoute
extends RefCounted
## A deterministic ledger-only caravan. Cargo leaves its source once, remains represented here
## while travelling, and reaches exactly one destination or an explicit loss record.

var route_id: int = 0
var source_id: StringName = &""
var destination_id: StringName = &""
var path: Array[StringName] = []
var cargo_policy: StringName = &"once"       ## once or maintain
var cargo: Dictionary = {}
var daily_amount: int = 0
var capacity: int = 40
var escort: int = 0
var settlers: Array[Dictionary] = []
var departure_day: int = 1
var arrival_day: int = 2
var risk: float = 0.0
var risk_label: StringName = &"safe"
var outcome_roll: float = 1.0
var status: StringName = &"scheduled"        ## scheduled/in_transit/arrived/lost/failed/cancelled
var intercepted: bool = false
var cargo_departed: bool = false
var lost_cargo: Dictionary = {}
var result: StringName = &""


func active() -> bool:
	return status in [&"scheduled", &"in_transit"]


func progress(day: int) -> float:
	if status == &"scheduled":
		return 0.0
	if status not in [&"in_transit"]:
		return 1.0
	return clampf(float(day - departure_day) / float(maxi(arrival_day - departure_day, 1)),
		0.0, 1.0)


func to_dict() -> Dictionary:
	return {
		"route_id": route_id,
		"source_id": String(source_id),
		"destination_id": String(destination_id),
		"path": path.map(func(value: StringName) -> String: return String(value)),
		"cargo_policy": String(cargo_policy),
		"cargo": cargo.duplicate(true),
		"daily_amount": daily_amount,
		"capacity": capacity,
		"escort": escort,
		"settlers": settlers.duplicate(true),
		"departure_day": departure_day,
		"arrival_day": arrival_day,
		"risk": risk,
		"risk_label": String(risk_label),
		"outcome_roll": outcome_roll,
		"status": String(status),
		"intercepted": intercepted,
		"cargo_departed": cargo_departed,
		"lost_cargo": lost_cargo.duplicate(true),
		"result": String(result),
	}


static func from_dict(data: Dictionary) -> TradeRoute:
	var route := TradeRoute.new()
	route.route_id = int(data.get("route_id", 0))
	route.source_id = StringName(data.get("source_id", ""))
	route.destination_id = StringName(data.get("destination_id", ""))
	for value in data.get("path", []):
		route.path.append(StringName(value))
	route.cargo_policy = StringName(data.get("cargo_policy", "once"))
	route.cargo = data.get("cargo", {}).duplicate(true)
	route.daily_amount = int(data.get("daily_amount", 0))
	route.capacity = maxi(int(data.get("capacity", 40)), 1)
	route.escort = maxi(int(data.get("escort", 0)), 0)
	route.settlers.assign(data.get("settlers", []).duplicate(true))
	route.departure_day = int(data.get("departure_day", 1))
	route.arrival_day = maxi(int(data.get("arrival_day", route.departure_day + 1)),
		route.departure_day + 1)
	route.risk = clampf(float(data.get("risk", 0.0)), 0.0, 0.95)
	route.risk_label = StringName(data.get("risk_label", "safe"))
	route.outcome_roll = clampf(float(data.get("outcome_roll", 1.0)), 0.0, 1.0)
	route.status = StringName(data.get("status", "scheduled"))
	route.intercepted = bool(data.get("intercepted", false))
	route.cargo_departed = bool(data.get("cargo_departed", route.status != &"scheduled"))
	route.lost_cargo = data.get("lost_cargo", {}).duplicate(true)
	route.result = StringName(data.get("result", ""))
	return route
