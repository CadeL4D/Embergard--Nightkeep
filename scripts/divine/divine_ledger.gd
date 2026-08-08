extends Node
## Authoritative Update 2d divine economy.
##
## Personal Faith belongs to villagers. Influence is the player's available/reserved casting
## capacity. Essence remains physical on the map and buildings retain local Energy inventories.

signal changed(available: float, maximum: float, reserved: float)

const BASE_INFLUENCE := 40.0
const CHILD_MAX := 16.0
const ADULT_MAX := 40.0
const ELDER_MAX := 50.0
const NEPHILIM_MAX := 65.0
const MINIMUM_SHARE := 0.20
const ANIMAL_INFLUENCE := 5.0
const DOGGO_INFLUENCE := 20.0
const DOOFY_DOGGO_INFLUENCE := 50.0

var available: float = 20.0
var reserved: float = 0.0
var animal_contributions: Dictionary = {}


func reset() -> void:
	available = 20.0
	reserved = 0.0
	animal_contributions.clear()
	_emit_changed()


func maximum() -> float:
	var total := BASE_INFLUENCE
	for villager in Colony.villagers:
		if not is_instance_valid(villager) or not villager.alive:
			continue
		var profile: VillagerRecord = villager.profile
		var potential := ADULT_MAX
		match profile.villager_type:
			&"child": potential = CHILD_MAX
			&"elder": potential = ELDER_MAX
			&"nephilim": potential = NEPHILIM_MAX
		var ratio := clampf(profile.faith / 100.0, MINIMUM_SHARE, 1.0)
		total += potential * ratio
	for kind in animal_contributions:
		total += float(animal_contributions[kind]) * _animal_value(StringName(kind))
	for building in Colony.buildings:
		if is_instance_valid(building) and not building.is_site():
			total += building.def.faith_capacity
	return maxf(total - reserved, 0.0)


func total_capacity() -> float:
	return maximum() + reserved


func set_available(value: float) -> void:
	available = clampf(value, 0.0, maximum())
	_emit_changed()


func add(amount: float) -> float:
	var before := available
	set_available(available + amount)
	return available - before


func can_spend(cost: float) -> bool:
	return cost >= 0.0 and available + 0.001 >= cost


func spend(cost: float) -> bool:
	if not can_spend(cost):
		return false
	set_available(available - cost)
	return true


func reserve(amount: float) -> bool:
	if amount < 0.0 or amount > maximum():
		return false
	reserved += amount
	available = minf(available, maximum())
	_emit_changed()
	return true


func release(amount: float) -> void:
	reserved = maxf(reserved - maxf(amount, 0.0), 0.0)
	_emit_changed()


func register_animal(kind: StringName, delta: int) -> void:
	var next := maxi(int(animal_contributions.get(kind, 0)) + delta, 0)
	if next == 0:
		animal_contributions.erase(kind)
	else:
		animal_contributions[kind] = next
	available = minf(available, maximum())
	_emit_changed()


func to_dict() -> Dictionary:
	return {
		"available_influence": available,
		"reserved_influence": reserved,
		"animal_contributions": animal_contributions.duplicate(true),
	}


func load_dict(data: Dictionary) -> void:
	reserved = maxf(float(data.get("reserved_influence", 0.0)), 0.0)
	animal_contributions = data.get("animal_contributions", {}).duplicate(true)
	available = clampf(float(data.get("available_influence", 20.0)), 0.0, maximum())
	_emit_changed()


func _animal_value(kind: StringName) -> float:
	match kind:
		&"doggo": return DOGGO_INFLUENCE
		&"doofy_doggo": return DOOFY_DOGGO_INFLUENCE
		_: return ANIMAL_INFLUENCE


func _emit_changed() -> void:
	changed.emit(available, maximum(), reserved)
	Events.faith_changed.emit(available)
