class_name MonsterDef
extends Resource
## One kind of Blight creature. Lives as a .tres in res://content/monsters/.

@export var id: StringName = &""
@export var display_name: String = ""
@export var sprite: Texture2D

@export_group("Body")
@export var max_health: float = 40.0
@export var move_speed: float = 18.0

@export_group("Attack")
@export var damage: float = 8.0
## Tiles. Above 1.5 the creature is effectively ranged and will stop short of its
## target rather than closing to touch it.
@export var attack_range: float = 1.2
@export var attack_cooldown: float = 1.2
## Damage multiplier against structures. Brutes exist to break walls; spitters do
## not, so they route around rather than chewing through.
@export var structure_damage_scale: float = 1.0

@export_group("Director")
## What one of these costs out of a night's threat budget.
@export var threat_cost: float = 1.0
## Earliest night this kind can appear, so the roster unfolds over a run.
@export var min_night: int = 1
## Relative likelihood of being picked once eligible.
@export var weight: float = 1.0

@export_group("Light")
## Damage per second taken while standing in bright light. This is what makes
## torches and the Ember genuinely defensive rather than just visibility.
@export var burn_per_second: float = 0.0
## Light level above which burning starts, 0-255.
@export_range(0, 255) var burn_threshold: int = 180


func is_ranged() -> bool:
	return attack_range > 1.5
