extends Node
## Realm-wide calendar and deterministic per-region weather.
##
## Weather is a pure function of world seed, region seed and day. That matters for sleeping
## colonies: they can apply the same rain, drought or snow without requiring a hidden live scene.
## Only player-created mitigation is mutable and therefore saved.

signal changed

const DAYS_PER_SEASON := 5
const SEASONS: Array[StringName] = [&"spring", &"summer", &"autumn", &"winter"]
const WEATHER_IDS: Array[StringName] = [
	&"clear", &"rain", &"storm", &"fog", &"drought", &"snow", &"heatwave",
]

const WEATHER_EFFECTS := {
	&"clear": {
		"light": 1.0, "farm": 1.0, "gather": 1.0, "blight": 1.0,
		"threat": 1.0, "thirst": 1.0, "move": 1.0, "mood": 0.0,
	},
	&"rain": {
		"light": 0.91, "farm": 1.22, "gather": 1.08, "blight": 1.12,
		"threat": 1.0, "thirst": 0.90, "move": 0.94, "mood": 1.0,
	},
	&"storm": {
		"light": 0.66, "farm": 0.82, "gather": 0.84, "blight": 1.28,
		"threat": 1.14, "thirst": 0.92, "move": 0.80, "mood": -4.0,
	},
	&"fog": {
		"light": 0.74, "farm": 0.94, "gather": 0.92, "blight": 1.16,
		"threat": 1.17, "thirst": 0.96, "move": 0.88, "mood": -1.0,
	},
	&"drought": {
		"light": 1.04, "farm": 0.56, "gather": 0.72, "blight": 0.84,
		"threat": 0.96, "thirst": 1.42, "move": 0.96, "mood": -3.0,
	},
	&"snow": {
		"light": 0.88, "farm": 0.52, "gather": 0.80, "blight": 0.68,
		"threat": 0.91, "thirst": 0.86, "move": 0.76, "mood": -2.0,
	},
	&"heatwave": {
		"light": 1.03, "farm": 0.70, "gather": 0.82, "blight": 0.90,
		"threat": 1.06, "thirst": 1.30, "move": 0.91, "mood": -3.0,
	},
}

const SEASON_EFFECTS := {
	&"spring": {"farm": 1.12, "gather": 1.05, "blight": 1.07, "thirst": 0.95},
	&"summer": {"farm": 1.05, "gather": 1.0, "blight": 1.02, "thirst": 1.09},
	&"autumn": {"farm": 0.96, "gather": 1.14, "blight": 0.96, "thirst": 1.0},
	&"winter": {"farm": 0.68, "gather": 0.86, "blight": 0.76, "thirst": 0.90,
		"move": 0.90},
}

## Weighted tables keep weather compatible with the land without hard-coding one outcome.
const BIOME_WEATHER := {
	&"coast": {&"clear": 18, &"rain": 31, &"storm": 23, &"fog": 18, &"drought": 3,
		&"snow": 5, &"heatwave": 2},
	&"grassland": {&"clear": 34, &"rain": 25, &"storm": 10, &"fog": 9,
		&"drought": 10, &"snow": 6, &"heatwave": 6},
	&"forest": {&"clear": 20, &"rain": 30, &"storm": 12, &"fog": 23,
		&"drought": 3, &"snow": 8, &"heatwave": 4},
	&"marsh": {&"clear": 12, &"rain": 34, &"storm": 17, &"fog": 30,
		&"drought": 2, &"snow": 4, &"heatwave": 1},
	&"highland": {&"clear": 25, &"rain": 13, &"storm": 19, &"fog": 12,
		&"drought": 8, &"snow": 19, &"heatwave": 4},
	&"badlands": {&"clear": 30, &"rain": 7, &"storm": 8, &"fog": 5,
		&"drought": 27, &"snow": 3, &"heatwave": 20},
	&"tundra": {&"clear": 20, &"rain": 8, &"storm": 14, &"fog": 15,
		&"drought": 3, &"snow": 37, &"heatwave": 3},
}

var world_seed: int = 0
var season: StringName = &"spring"
var weather: StringName = &"clear"
var severity: float = 0.0
var biome: StringName = Biomes.DEFAULT_ID
var effects: Dictionary = WEATHER_EFFECTS[&"clear"].duplicate()
## kind -> last day on which its protection applies.
var mitigations: Dictionary = {}
var _forced_weather: StringName = &""
var _forced_severity: float = 0.0


func _ready() -> void:
	Events.day_advanced.connect(func(_day: int) -> void: refresh())
	Events.colony_awakened.connect(func(_id: StringName) -> void: refresh())
	Events.run_started.connect(func(seed_value: int) -> void:
		if world_seed == 0:
			world_seed = seed_value
		refresh()
	)


func reset(seed_value: int) -> void:
	world_seed = seed_value
	season = &"spring"
	weather = &"clear"
	severity = 0.0
	biome = Biomes.DEFAULT_ID
	effects = WEATHER_EFFECTS[&"clear"].duplicate()
	mitigations.clear()
	_forced_weather = &""


func refresh() -> void:
	if Realm.awake_id == &"" or Realm.sites.is_empty():
		return
	var site := Realm.site(Realm.awake_id)
	if site.is_empty():
		return
	biome = StringName(site.get("biome", Biomes.DEFAULT_ID))
	var snapshot := daily_snapshot(world_seed, int(site.get("seed", World.seed_value)),
		Sim.day, biome)
	season = snapshot["season"]
	weather = _forced_weather if _forced_weather != &"" else snapshot["weather"]
	severity = _forced_severity if _forced_weather != &"" else float(snapshot["severity"])
	effects = _compose_effects(season, weather, severity, biome, Sim.day, mitigations)
	_prune_mitigations()
	changed.emit()
	Events.climate_changed.emit(season, weather, severity)


static func season_for_day(day: int) -> StringName:
	var index := (maxi(day, 1) - 1) / Difficulties.season_length()
	return SEASONS[index % SEASONS.size()]


static func daily_snapshot(seed_value: int, region_seed: int, day: int,
		biome_id: StringName) -> Dictionary:
	var day_season := season_for_day(day)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ (region_seed * 104729) ^ (day * 8191) ^ 0x51A7E
	var weights: Dictionary = BIOME_WEATHER.get(biome_id, BIOME_WEATHER[Biomes.DEFAULT_ID]).duplicate()
	match day_season:
		&"spring":
			weights[&"rain"] = int(weights.get(&"rain", 0)) + 12
			weights[&"fog"] = int(weights.get(&"fog", 0)) + 5
		&"summer":
			weights[&"clear"] = int(weights.get(&"clear", 0)) + 9
			weights[&"drought"] = int(weights.get(&"drought", 0)) + 10
			weights[&"heatwave"] = int(weights.get(&"heatwave", 0)) + 8
		&"autumn":
			weights[&"storm"] = int(weights.get(&"storm", 0)) + 8
			weights[&"fog"] = int(weights.get(&"fog", 0)) + 8
		&"winter":
			weights[&"snow"] = int(weights.get(&"snow", 0)) + 28
			weights[&"heatwave"] = 0
	var selected := _weighted_pick(weights, rng)
	var selected_severity := 0.62 + rng.randf() * 0.34 \
		if selected != &"clear" else rng.randf() * 0.22
	return {
		"season": day_season,
		"weather": selected,
		"severity": selected_severity,
		"effects": _compose_effects(day_season, selected, selected_severity,
			biome_id, day, {}),
	}


static func _weighted_pick(weights: Dictionary, rng: RandomNumberGenerator) -> StringName:
	var total := 0
	for id: StringName in WEATHER_IDS:
		total += maxi(int(weights.get(id, 0)), 0)
	if total <= 0:
		return &"clear"
	var roll := rng.randi_range(1, total)
	for id: StringName in WEATHER_IDS:
		roll -= maxi(int(weights.get(id, 0)), 0)
		if roll <= 0:
			return id
	return &"clear"


static func _compose_effects(day_season: StringName, weather_id: StringName,
		weather_severity: float, biome_id: StringName, day: int,
		active_mitigations: Dictionary) -> Dictionary:
	var result := {
		"light": 1.0, "farm": 1.0, "gather": 1.0, "blight": 1.0,
		"threat": 1.0, "thirst": 1.0, "move": 1.0, "mood": 0.0,
	}
	var season_row: Dictionary = SEASON_EFFECTS.get(day_season, {})
	for key in season_row:
		result[key] = float(result.get(key, 1.0)) * float(season_row[key])
	var weather_row: Dictionary = WEATHER_EFFECTS.get(weather_id, WEATHER_EFFECTS[&"clear"])
	var blend := clampf(weather_severity, 0.0, 1.0)
	for key in weather_row:
		if key == "mood":
			result[key] = float(result.get(key, 0.0)) + float(weather_row[key]) * blend
		else:
			result[key] = float(result.get(key, 1.0)) * lerpf(1.0, float(weather_row[key]), blend)
	result["blight"] = float(result["blight"]) * Biomes.blight_multiplier(biome_id)
	result["threat"] = float(result["threat"]) * Biomes.threat_multiplier(biome_id)
	if int(active_mitigations.get("storm_ward", 0)) >= day and weather_id == &"storm":
		result["light"] = maxf(float(result["light"]), 0.88)
		result["move"] = maxf(float(result["move"]), 0.93)
		result["blight"] = minf(float(result["blight"]), 1.02)
	if int(active_mitigations.get("drought_relief", 0)) >= day \
			and weather_id in [&"drought", &"heatwave"]:
		result["farm"] = maxf(float(result["farm"]), 0.92)
		result["thirst"] = minf(float(result["thirst"]), 1.05)
	if int(active_mitigations.get("rationing", 0)) >= day:
		result["thirst"] = float(result["thirst"]) * 0.82
		result["farm"] = float(result["farm"]) * 0.92
	return result


func light_multiplier() -> float:
	return float(effects.get("light", 1.0))


func farm_multiplier() -> float:
	return float(effects.get("farm", 1.0)) * Difficulties.yield_mult()


func gather_multiplier(feature: int) -> float:
	return float(effects.get("gather", 1.0)) * Biomes.yield_multiplier(biome, feature) \
		* Difficulties.yield_mult()


func blight_multiplier() -> float:
	return float(effects.get("blight", 1.0))


func threat_multiplier() -> float:
	return float(effects.get("threat", 1.0))


func thirst_multiplier() -> float:
	return float(effects.get("thirst", 1.0))


func movement_multiplier(terrain_type: int) -> float:
	return float(effects.get("move", 1.0)) * Biomes.movement_multiplier(biome, terrain_type)


func mood_offset() -> float:
	return float(effects.get("mood", 0.0))


func production_multiplier(job: JobDef, resource: StringName) -> float:
	if job != null and job.workplace == &"farm" and resource == &"food":
		return farm_multiplier()
	return 1.0


func name_of_season(id: StringName = season) -> String:
	return tr(StringName("SEASON_" + String(id).to_upper()))


func name_of_weather(id: StringName = weather) -> String:
	return tr(StringName("WEATHER_" + String(id).to_upper()))


func hud_text() -> String:
	return L10n.t(&"CLIMATE_HUD", [name_of_season(), name_of_weather()])


func set_mitigation(kind: StringName, until_day: int) -> void:
	mitigations[String(kind)] = maxi(int(mitigations.get(String(kind), 0)), until_day)
	refresh()


func force_weather(id: StringName, forced_severity: float = 0.85) -> void:
	_forced_weather = id if id in WEATHER_IDS else &""
	_forced_severity = clampf(forced_severity, 0.0, 1.0)
	refresh()


func clear_forced_weather() -> void:
	_forced_weather = &""
	refresh()


func _prune_mitigations() -> void:
	for key in mitigations.keys():
		if int(mitigations[key]) < Sim.day:
			mitigations.erase(key)


func to_dict() -> Dictionary:
	return {
		"world_seed": world_seed,
		"mitigations": mitigations.duplicate(true),
	}


func load_dict(data: Dictionary) -> void:
	world_seed = int(data.get("world_seed", Realm.world_seed))
	mitigations = data.get("mitigations", {}).duplicate(true)
	_forced_weather = &""
	refresh()
