class_name DamageTypes
extends RefCounted
## Shared typed-damage rules for creatures, villagers, buildings, towers and miracles.

const ALL: Array[StringName] = [
	&"piercing", &"crushing", &"fire", &"holy", &"blight", &"elemental",
]


static func apply(amount: float, resistances: Dictionary, damage_type: StringName) -> float:
	var resistance := clampf(float(resistances.get(damage_type, 0.0)), -1.5, 0.95)
	return maxf(amount, 0.0) * (1.0 - resistance)


static func valid(damage_type: StringName) -> bool:
	return damage_type in ALL
