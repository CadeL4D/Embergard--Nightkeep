class_name Doctrines
extends RefCounted
## Optional realm-shaping sidegrades. A realm may equip at most three; core systems never depend
## on them. Every doctrine has a benefit and a cost so the Chronicle opens choices, not power creep.

const MAX_EQUIPPED := 3

class Entry extends RefCounted:
	var id: StringName
	var display_name: String
	var description: String
	var shard_cost: int
	var order: int
	var starter: bool
	var modifiers: Dictionary
	var bonuses: Dictionary

	func _init(row: Dictionary, index: int) -> void:
		id = StringName(row["id"])
		display_name = String(row["name"])
		description = String(row["description"])
		shard_cost = int(row.get("cost", 50 + index * 5))
		order = index
		starter = bool(row.get("starter", false))
		modifiers = row.get("modifiers", {}).duplicate(true)
		bonuses = row.get("bonuses", {}).duplicate(true)

const ROWS := [
	{"id": &"doc_hearth_compact", "name": "Hearth Compact", "starter": true,
		"description": "+1 founder; needs rise 5% faster.",
		"modifiers": {&"needs": 1.05}, "bonuses": {&"start_pop": 1}},
	{"id": &"doc_lean_tables", "name": "Lean Tables", "starter": true,
		"description": "Needs fall 10% slower; migration falls 10%.",
		"modifiers": {&"needs": 0.90, &"migration": 0.90}},
	{"id": &"doc_forager_levy", "name": "Forager Levy", "starter": true,
		"description": "Regional yields rise 10%; threat rises 5%.",
		"modifiers": {&"yield": 1.10, &"threat": 1.05}},
	{"id": &"doc_guild_measures", "name": "Guild Measures",
		"description": "Production yields rise 8%; settlers arrive 8% slower.",
		"modifiers": {&"yield": 1.08, &"migration": 0.92}},
	{"id": &"doc_sealed_granaries", "name": "Sealed Granaries",
		"description": "Spoilage falls 22%; construction yields fall 4%.",
		"modifiers": {&"spoilage": 0.78, &"yield": 0.96}},
	{"id": &"doc_open_gates", "name": "Open Gates",
		"description": "Migration rises 20%; nightly threat rises 8%.",
		"modifiers": {&"migration": 1.20, &"threat": 1.08}},
	{"id": &"doc_tower_drill", "name": "Tower Drill",
		"description": "Tower damage rises 10%; Blight develops 5% faster.",
		"modifiers": {&"tower_damage": 1.10, &"blight": 1.05}},
	{"id": &"doc_patient_crews", "name": "Patient Crews",
		"description": "Tower reload falls 10%; tower damage falls 5%.",
		"modifiers": {&"tower_reload": 0.90, &"tower_damage": 0.95}},
	{"id": &"doc_stone_vow", "name": "Stone Vow",
		"description": "Repairs rise 18%; gather yield falls 5%.",
		"modifiers": {&"repair": 1.18, &"yield": 0.95}},
	{"id": &"doc_ember_parapets", "name": "Ember Parapets",
		"description": "Blight spread falls 8%; passive Faith falls 8%.",
		"modifiers": {&"blight": 0.92, &"faith_rate": 0.92}},
	{"id": &"doc_deep_magazines", "name": "Deep Magazines",
		"description": "Towers reload 6% faster; needs rise 4% faster.",
		"modifiers": {&"tower_reload": 0.94, &"needs": 1.04}},
	{"id": &"doc_gatewardens", "name": "Gatewardens",
		"description": "Tower damage rises 6%; migration falls 12%.",
		"modifiers": {&"tower_damage": 1.06, &"migration": 0.88}},
	{"id": &"doc_morning_litany", "name": "Morning Litany",
		"description": "Passive Faith rises 12%; Burden rises 8%.",
		"modifiers": {&"faith_rate": 1.12, &"burden": 1.08}},
	{"id": &"doc_burden_rite", "name": "Burden Rite",
		"description": "Divine Burden falls 10%; needs rise 5% faster.",
		"modifiers": {&"burden": 0.90, &"needs": 1.05}},
	{"id": &"doc_ashen_choir", "name": "Ashen Choir",
		"description": "Faith rises 8%; Blight pressure rises 5%.",
		"modifiers": {&"faith_rate": 1.08, &"blight": 1.05}},
	{"id": &"doc_humble_flame", "name": "Humble Flame",
		"description": "Faith rises 6%; tower damage falls 5%.",
		"modifiers": {&"faith_rate": 1.06, &"tower_damage": 0.95}},
	{"id": &"doc_last_light", "name": "Last Light",
		"description": "Threat falls 7%; regional yields fall 7%.",
		"modifiers": {&"threat": 0.93, &"yield": 0.93}},
	{"id": &"doc_kindled_labor", "name": "Kindled Labor",
		"description": "Repair and yield rise 5%; Burden rises 10%.",
		"modifiers": {&"repair": 1.05, &"yield": 1.05, &"burden": 1.10}},
	{"id": &"doc_road_oath", "name": "Road Oath",
		"description": "Route risk falls 22%; caravans travel 8% slower.",
		"modifiers": {&"route_risk": 0.78, &"route_speed": 1.08}},
	{"id": &"doc_swift_axles", "name": "Swift Axles",
		"description": "Caravans travel 20% faster; route risk rises 12%.",
		"modifiers": {&"route_speed": 0.80, &"route_risk": 1.12}},
	{"id": &"doc_armed_wagons", "name": "Armed Wagons",
		"description": "Route risk falls 30%; capacity falls 18%.",
		"modifiers": {&"route_risk": 0.70, &"route_capacity": 0.82}},
	{"id": &"doc_regional_barter", "name": "Regional Barter",
		"description": "Route capacity rises 25%; local yield falls 4%.",
		"modifiers": {&"route_capacity": 1.25, &"yield": 0.96}},
	{"id": &"doc_warded_milestones", "name": "Warded Milestones",
		"description": "Route risk falls 14%; passive Faith falls 6%.",
		"modifiers": {&"route_risk": 0.86, &"faith_rate": 0.94}},
	{"id": &"doc_settlers_pact", "name": "Settlers' Pact",
		"description": "Migration rises 10%; route risk falls 8%; needs rise 5%.",
		"modifiers": {&"migration": 1.10, &"route_risk": 0.92, &"needs": 1.05}},
]

static var _catalog: Dictionary = {}
static var _all: Array[Entry] = []


static func all() -> Array[Entry]:
	_ensure()
	return _all


static func get_doctrine(id: StringName) -> Entry:
	_ensure()
	return _catalog.get(id)


static func available() -> Array[Entry]:
	_ensure()
	var out: Array[Entry] = []
	for doctrine in _all:
		if doctrine.starter or Meta.is_unlocked(doctrine.id):
			out.append(doctrine)
	return out


static func sanitize(ids: Array) -> Array[StringName]:
	_ensure()
	var out: Array[StringName] = []
	for raw_id in ids:
		var id := StringName(raw_id)
		var doctrine: Entry = _catalog.get(id)
		if doctrine != null and (doctrine.starter or Meta.is_unlocked(id)) and id not in out:
			out.append(id)
			if out.size() >= MAX_EQUIPPED:
				break
	return out


static func modifier(key: StringName, fallback: float = 1.0) -> float:
	_ensure()
	var value := fallback
	for id in Realm.selected_doctrines:
		var doctrine: Entry = _catalog.get(id)
		if doctrine != null:
			value *= float(doctrine.modifiers.get(key, 1.0))
	return value


static func bonus(key: StringName) -> int:
	_ensure()
	var value := 0
	for id in Realm.selected_doctrines:
		var doctrine: Entry = _catalog.get(id)
		if doctrine != null:
			value += int(doctrine.bonuses.get(key, 0))
	return value


static func _ensure() -> void:
	if not _all.is_empty():
		return
	for i in ROWS.size():
		var doctrine := Entry.new(ROWS[i], i)
		_catalog[doctrine.id] = doctrine
		_all.append(doctrine)
