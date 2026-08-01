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
@export var attack_type: StringName = &"crushing"
@export var resistances: Dictionary = {}
@export var behavior_tags: Array[StringName] = []
@export var statuses_inflicted: Array[StringName] = []
@export var status_duration: float = 18.0

@export_group("Special behavior")
## Splitting and death bursts are resolved as scheduled simulation effects. They do not create
## physics bodies or one-shot scene effects, which keeps a large mobile wave deterministic.
@export var split_into: StringName = &""
@export_range(0, 6) var split_count: int = 0
@export var death_burst_damage: float = 0.0
@export var death_burst_radius: float = 0.0
@export var death_burst_type: StringName = &"fire"
@export var support_heal: float = 0.0
@export var support_radius: float = 0.0
@export var support_cooldown: float = 3.0

@export_group("Boss")
@export var is_boss: bool = false
@export var presentation_scale: float = 1.0
@export var presentation_tint: Color = Color.WHITE
@export var boss_reward: int = 0

@export_group("Reward")
## Faith granted for destroying one of these.
##
## The reward for fighting WELL. Before this, monsters dropped nothing and every survivor
## burned off at dawn anyway, so a night spent slaughtering a wave and a night spent barely
## holding on were mechanically identical — the only difference was how many villagers you
## buried. Feeding kills into Faith makes an aggressive, well-lit, well-towered defence pay for
## the miracles that made it possible.
##
## Scaled off threat_cost by convention: a Spitter costs the director twice a Shambler and is
## worth roughly twice as much to kill.
@export var faith_on_death: float = 1.0

@export_group("Director")
## What one of these costs out of a night's threat budget.
@export var threat_cost: float = 1.0
## Earliest night this kind can appear, so the roster unfolds over a run.
@export var min_night: int = 1
## Relative likelihood of being picked once eligible.
@export var weight: float = 1.0

## Ignores walls entirely — comes up through the ground instead of walking round.
##
## Implemented as "does not read the flow field" rather than as a second, wall-free field. The
## shared field is the reason a hundred monsters cost almost nothing, and adding a per-creature
## cost function would either double that work or fork it. A tunneller has no use for pathfinding
## anyway: it goes straight at the colony, which is both cheaper and exactly what it should look
## like.
##
## This is the answer to a player who thinks a closed wall is a solution.
@export var tunnels: bool = false

@export_group("Light")
## Damage per second taken while standing in bright light. This is what makes
## torches and the Ember genuinely defensive rather than just visibility.
@export var burn_per_second: float = 0.0
## Light level above which burning starts, 0-255.
@export_range(0, 255) var burn_threshold: int = 180


func is_ranged() -> bool:
	return attack_range > 1.5


func has_behavior(tag: StringName) -> bool:
	return tag in behavior_tags or (tag == &"boss" and is_boss)
