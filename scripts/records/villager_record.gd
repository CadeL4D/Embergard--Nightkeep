class_name VillagerRecord
extends RefCounted
## Persistent identity and life history, separate from the awake Villager Node.

var stable_id: String = ""
var display_name: String = ""
var age_days: int = 0
var adult_age_days: int = 6
var max_age_days: int = 80
var household_id: String = ""
var partner_id: String = ""
var traits: Array[StringName] = []
var strength: float = 1.0
var agility: float = 1.0
var wisdom: float = 1.0
var wounds: Dictionary = {}
var statuses: Dictionary = {}
var equipment: Dictionary = {}
var equipment_policy: StringName = &"best_available"
var birth_cooldown_until_day: int = 0
var memorial: Dictionary = {}


func to_dict() -> Dictionary:
	return {
		"id": stable_id,
		"name": display_name,
		"age_days": age_days,
		"adult_age_days": adult_age_days,
		"max_age_days": max_age_days,
		"household": household_id,
		"partner": partner_id,
		"traits": traits.duplicate(),
		"strength": strength,
		"agility": agility,
		"wisdom": wisdom,
		"wounds": wounds.duplicate(true),
		"statuses": statuses.duplicate(true),
		"equipment": equipment.duplicate(true),
		"equipment_policy": equipment_policy,
		"birth_cooldown_until_day": birth_cooldown_until_day,
		"memorial": memorial.duplicate(true),
	}


static func from_dict(data: Dictionary) -> VillagerRecord:
	var record := VillagerRecord.new()
	record.stable_id = String(data.get("id", ""))
	record.display_name = String(data.get("name", ""))
	record.age_days = int(data.get("age_days", 0))
	record.adult_age_days = int(data.get("adult_age_days", 6))
	record.max_age_days = int(data.get("max_age_days", 80))
	record.household_id = String(data.get("household", ""))
	record.partner_id = String(data.get("partner", ""))
	record.traits.assign(data.get("traits", []))
	record.strength = float(data.get("strength", 1.0))
	record.agility = float(data.get("agility", 1.0))
	record.wisdom = float(data.get("wisdom", 1.0))
	record.wounds = data.get("wounds", {}).duplicate(true)
	record.statuses = data.get("statuses", {}).duplicate(true)
	record.equipment = data.get("equipment", {}).duplicate(true)
	record.equipment_policy = StringName(data.get("equipment_policy", &"best_available"))
	record.birth_cooldown_until_day = int(data.get("birth_cooldown_until_day", 0))
	record.memorial = data.get("memorial", {}).duplicate(true)
	return record
