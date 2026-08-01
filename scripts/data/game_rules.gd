class_name GameRules
extends Resource
## Complete, serializable rules for one realm. Presets are ordinary resources, while Custom
## realms save an owned copy so a later balance patch never changes an existing world.

@export var id: StringName = &"survival"
@export var display_name: String = "DIFFICULTY_SURVIVAL"
@export_multiline var description: String = "DIFFICULTY_SURVIVAL_DESC"

@export_group("Calendar")
@export var day_seconds: float = 240.0
@export var dusk_seconds: float = 60.0
@export var night_seconds: float = 120.0
@export var dawn_seconds: float = 45.0
@export_range(1, 30) var season_length: int = 5

@export_group("Simulation")
@export var needs_mult: float = 1.0
@export var threat_mult: float = 1.0
@export var blight_mult: float = 1.0
@export var yield_mult: float = 1.0
@export var migration_mult: float = 1.0
@export var monster_night_shift: int = 0
@export var start_pop_bonus: int = 0

@export_group("Mode")
@export var hostile_spawning: bool = true
@export var progression_awards: bool = true
@export var sandbox_tools: bool = false
@export var custom_mode: bool = false

@export_group("Fixed mobile-safe caps")
@export var max_villagers: int = 64
@export var max_hostiles: int = 120
@export var max_enemy_workers: int = 16
@export var max_player_buildings: int = 160

@export_group("Reward and menu")
@export var shard_mult: float = 1.0
@export var order: int = 0
@export var color: Color = Color.WHITE
@export var visible_in_menu: bool = true


func phase_duration(phase: int) -> float:
	match phase:
		0: return day_seconds
		1: return dusk_seconds
		2: return night_seconds
		3: return dawn_seconds
	return day_seconds


func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"day_seconds": day_seconds,
		"dusk_seconds": dusk_seconds,
		"night_seconds": night_seconds,
		"dawn_seconds": dawn_seconds,
		"season_length": season_length,
		"needs_mult": needs_mult,
		"threat_mult": threat_mult,
		"blight_mult": blight_mult,
		"yield_mult": yield_mult,
		"migration_mult": migration_mult,
		"monster_night_shift": monster_night_shift,
		"start_pop_bonus": start_pop_bonus,
		"hostile_spawning": hostile_spawning,
		"progression_awards": progression_awards,
		"sandbox_tools": sandbox_tools,
		"custom_mode": custom_mode,
		"max_villagers": max_villagers,
		"max_hostiles": max_hostiles,
		"max_enemy_workers": max_enemy_workers,
		"max_player_buildings": max_player_buildings,
		"shard_mult": shard_mult,
	}


static func from_dict(data: Dictionary) -> GameRules:
	var rules := GameRules.new()
	rules.id = StringName(data.get("id", "custom"))
	rules.day_seconds = maxf(float(data.get("day_seconds", 240.0)), 15.0)
	rules.dusk_seconds = maxf(float(data.get("dusk_seconds", 60.0)), 10.0)
	rules.night_seconds = maxf(float(data.get("night_seconds", 120.0)), 15.0)
	rules.dawn_seconds = maxf(float(data.get("dawn_seconds", 45.0)), 10.0)
	rules.season_length = clampi(int(data.get("season_length", 5)), 1, 30)
	rules.needs_mult = clampf(float(data.get("needs_mult", 1.0)), 0.1, 4.0)
	rules.threat_mult = clampf(float(data.get("threat_mult", 1.0)), 0.0, 4.0)
	rules.blight_mult = clampf(float(data.get("blight_mult", 1.0)), 0.0, 4.0)
	rules.yield_mult = clampf(float(data.get("yield_mult", 1.0)), 0.1, 4.0)
	rules.migration_mult = clampf(float(data.get("migration_mult", 1.0)), 0.0, 4.0)
	rules.monster_night_shift = clampi(int(data.get("monster_night_shift", 0)), -10, 20)
	rules.start_pop_bonus = clampi(int(data.get("start_pop_bonus", 0)), -4, 12)
	rules.hostile_spawning = bool(data.get("hostile_spawning", true))
	rules.progression_awards = bool(data.get("progression_awards", true))
	rules.sandbox_tools = bool(data.get("sandbox_tools", false))
	rules.custom_mode = bool(data.get("custom_mode", rules.id == &"custom"))
	# Custom rules may tune pacing, never the performance envelope.
	rules.max_villagers = clampi(int(data.get("max_villagers", 64)), 2, 64)
	rules.max_hostiles = clampi(int(data.get("max_hostiles", 120)), 0, 120)
	rules.max_enemy_workers = clampi(int(data.get("max_enemy_workers", 16)), 0, 16)
	rules.max_player_buildings = clampi(int(data.get("max_player_buildings", 160)), 1, 160)
	rules.shard_mult = clampf(float(data.get("shard_mult", 1.0)), 0.0, 4.0)
	return rules
