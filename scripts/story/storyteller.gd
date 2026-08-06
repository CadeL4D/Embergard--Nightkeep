extends Node
## Deterministic pressure-aware world events with explicit player choices.
##
## Events happen at dawn every two or three days, never stack, and always offer one choice
## that needs no resources. The pending card is part of the run save, so closing the game is
## not a way to reroll or escape a hard decision.

const EVENT_IDS: Array[StringName] = [
	&"caravan", &"refugees", &"blight_surge", &"stormfront", &"drought",
	&"lost_caravan", &"emberglass_peddler", &"road_wardens", &"broken_wheel",
	&"harvest_fair", &"separated_family", &"orphaned_band", &"returning_scouts",
	&"healers_pilgrimage", &"oathbound_rangers", &"creeping_roots", &"silent_totem",
	&"infected_well", &"hollow_chant", &"besieged_outpost", &"lightning_harvest",
	&"flooded_storehouse", &"fogbound_patrol", &"hail_on_roofs", &"ashfall",
	&"failed_harvest", &"dry_cistern", &"herb_bloom", &"ration_dispute", &"emberwind",
]

const EVENT_FAMILY := {
	&"caravan": &"caravan", &"lost_caravan": &"caravan",
	&"emberglass_peddler": &"caravan", &"road_wardens": &"caravan",
	&"broken_wheel": &"caravan", &"harvest_fair": &"caravan",
	&"refugees": &"refugees", &"separated_family": &"refugees",
	&"orphaned_band": &"refugees", &"returning_scouts": &"refugees",
	&"healers_pilgrimage": &"refugees", &"oathbound_rangers": &"refugees",
	&"blight_surge": &"blight_surge", &"creeping_roots": &"blight_surge",
	&"silent_totem": &"blight_surge", &"infected_well": &"blight_surge",
	&"hollow_chant": &"blight_surge", &"besieged_outpost": &"blight_surge",
	&"stormfront": &"stormfront", &"lightning_harvest": &"stormfront",
	&"flooded_storehouse": &"stormfront", &"fogbound_patrol": &"stormfront",
	&"hail_on_roofs": &"stormfront", &"ashfall": &"stormfront",
	&"drought": &"drought", &"failed_harvest": &"drought", &"dry_cistern": &"drought",
	&"herb_bloom": &"drought", &"ration_dispute": &"drought", &"emberwind": &"drought",
}

const EVENT_TAGS := {
	&"lost_caravan": [&"route"], &"road_wardens": [&"route"],
	&"broken_wheel": [&"route", &"weather"], &"harvest_fair": [&"region"],
	&"emberglass_peddler": [&"faith", &"region"],
	&"separated_family": [&"household"], &"orphaned_band": [&"household"],
	&"returning_scouts": [&"route"], &"healers_pilgrimage": [&"faith", &"household"],
	&"oathbound_rangers": [&"blight", &"route"],
	&"creeping_roots": [&"blight"], &"silent_totem": [&"blight"],
	&"infected_well": [&"blight", &"region"], &"hollow_chant": [&"blight", &"faith"],
	&"besieged_outpost": [&"blight", &"route"],
	&"lightning_harvest": [&"weather", &"faith"],
	&"flooded_storehouse": [&"weather"], &"fogbound_patrol": [&"weather", &"route"],
	&"hail_on_roofs": [&"weather", &"region"], &"ashfall": [&"weather", &"blight"],
	&"failed_harvest": [&"region"], &"dry_cistern": [&"weather"],
	&"herb_bloom": [&"region"], &"ration_dispute": [&"household"],
	&"emberwind": [&"faith", &"blight"],
}

var world_seed: int = 0
var next_event_day: int = 3
var event_serial: int = 0
var resolved_count: int = 0
var pending: Dictionary = {}


func _ready() -> void:
	Events.day_advanced.connect(_on_day_advanced)


func reset(seed_value: int) -> void:
	world_seed = seed_value
	next_event_day = 2 + posmod(seed_value, 2)
	event_serial = 0
	resolved_count = 0
	pending.clear()


func _on_day_advanced(day: int) -> void:
	if not Sim.running or not pending.is_empty() or day < next_event_day:
		return
	_create_event(_choose_event(day))


func _choose_event(day: int) -> StringName:
	var weights := {}
	for id in EVENT_IDS:
		weights[id] = _event_weight(id)
	var rng := _rng_for(day, event_serial)
	var total := 0
	for id: StringName in EVENT_IDS:
		total += int(weights[id])
	var roll := rng.randi_range(1, maxi(total, 1))
	for id: StringName in EVENT_IDS:
		roll -= int(weights[id])
		if roll <= 0:
			return id
	return &"caravan"


func _event_weight(id: StringName) -> int:
	var family := StringName(EVENT_FAMILY.get(id, id))
	var weight := 5
	match family:
		&"caravan": weight = 10
		&"refugees": weight = 9 if Colony.population() < 18 else 4
		&"blight_surge": weight = 5 + int(round(World.blight_field.coverage() * 22.0))
		&"stormfront": weight = 13 if Climate.weather in [&"storm", &"rain", &"fog", &"snow"] else 2
		&"drought": weight = 14 if Climate.weather in [&"drought", &"heatwave"] else 2
	var tags: Array = EVENT_TAGS.get(id, [])
	if &"route" in tags:
		weight += mini(Realm.active_routes().size() * 5, 15)
	if &"weather" in tags and Climate.weather != &"clear":
		weight += 7
	if &"faith" in tags:
		weight += 6 if Divine.faith < Divine.faith_max() * 0.45 else 2
	if &"blight" in tags:
		weight += int(round(World.blight_field.coverage() * 35.0))
	if &"household" in tags:
		var households := {}
		for villager in Colony.villagers:
			if is_instance_valid(villager) and not villager.profile.household_id.is_empty():
				households[villager.profile.household_id] = true
		weight += mini(households.size() * 2, 10)
	if &"region" in tags:
		var identity: Dictionary = Realm.site(Realm.awake_id).get("economic_identity", {})
		if not identity.is_empty():
			weight += 6
	return maxi(weight, 1)


func force_event(id: StringName) -> bool:
	if id not in EVENT_IDS or not pending.is_empty():
		return false
	_create_event(id)
	return true


func _create_event(id: StringName) -> void:
	if id not in EVENT_IDS:
		return
	event_serial += 1
	var rng := _rng_for(Sim.day, event_serial)
	var family := StringName(EVENT_FAMILY.get(id, id))
	pending = _payload_for(family, rng)
	pending["id"] = id
	pending["family"] = family
	pending["serial"] = event_serial
	if id != family:
		var prefix := "STORY_EVENT_" + String(id).to_upper()
		pending["title"] = tr(StringName(prefix + "_TITLE"))
		pending["body"] = tr(StringName(prefix + "_BODY"))
	_present_pending()


func _payload_for(id: StringName, rng: RandomNumberGenerator) -> Dictionary:
	match id:
		&"caravan":
			return {
				"title": tr(&"STORY_CARAVAN_TITLE"),
				"body": tr(&"STORY_CARAVAN_BODY"),
				"choices": [
					_choice(&"tools", &"STORY_CARAVAN_TOOLS", &"STORY_CARAVAN_TOOLS_DETAIL",
						{&"food": 18}, 0.0, true),
					_choice(&"provisions", &"STORY_CARAVAN_PROVISIONS",
						&"STORY_CARAVAN_PROVISIONS_DETAIL", {&"wood": 24}),
					_choice(&"pass", &"STORY_PASS", &"STORY_PASS_DETAIL"),
				],
			}
		&"refugees":
			var count := rng.randi_range(1, 3)
			return {
				"title": tr(&"STORY_REFUGEES_TITLE"),
				"body": L10n.t(&"STORY_REFUGEES_BODY", [count]),
				"count": count,
				"choices": [
					_choice(&"welcome", &"STORY_REFUGEES_WELCOME",
						&"STORY_REFUGEES_WELCOME_DETAIL", {}, 0.0, true),
					_choice(&"provision", &"STORY_REFUGEES_PROVISION",
						&"STORY_REFUGEES_PROVISION_DETAIL", {&"food": count * 8}),
					_choice(&"refuse", &"STORY_REFUGEES_REFUSE",
						&"STORY_REFUGEES_REFUSE_DETAIL"),
				],
			}
		&"blight_surge":
			return {
				"title": tr(&"STORY_BLIGHT_TITLE"),
				"body": tr(&"STORY_BLIGHT_BODY"),
				"choices": [
					_choice(&"faith_ward", &"STORY_BLIGHT_WARD", &"STORY_BLIGHT_WARD_DETAIL",
						{}, 25.0, true),
					_choice(&"stockade", &"STORY_BLIGHT_STOCKADE",
						&"STORY_BLIGHT_STOCKADE_DETAIL", {&"boards": 10}),
					_choice(&"endure", &"STORY_BLIGHT_ENDURE", &"STORY_BLIGHT_ENDURE_DETAIL"),
				],
			}
		&"stormfront":
			return {
				"title": tr(&"STORY_STORM_TITLE"),
				"body": tr(&"STORY_STORM_BODY"),
				"choices": [
					_choice(&"reinforce", &"STORY_STORM_REINFORCE",
						&"STORY_STORM_REINFORCE_DETAIL", {&"wood": 20}, 0.0, true),
					_choice(&"shelter", &"STORY_STORM_SHELTER",
						&"STORY_STORM_SHELTER_DETAIL"),
					_choice(&"work_on", &"STORY_STORM_WORK", &"STORY_STORM_WORK_DETAIL"),
				],
			}
		&"drought":
			return {
				"title": tr(&"STORY_DROUGHT_TITLE"),
				"body": tr(&"STORY_DROUGHT_BODY"),
				"choices": [
					_choice(&"cistern", &"STORY_DROUGHT_CISTERN",
						&"STORY_DROUGHT_CISTERN_DETAIL", {&"stone": 16}, 0.0, true),
					_choice(&"ration", &"STORY_DROUGHT_RATION",
						&"STORY_DROUGHT_RATION_DETAIL"),
					_choice(&"endure", &"STORY_DROUGHT_ENDURE",
						&"STORY_DROUGHT_ENDURE_DETAIL"),
				],
			}
	return {}


func _choice(id: StringName, label_key: StringName, detail_key: StringName,
		cost: Dictionary = {}, faith_cost: float = 0.0, recommended: bool = false) -> Dictionary:
	return {
		"id": id,
		"label": tr(label_key),
		"detail": tr(detail_key),
		"cost": cost.duplicate(true),
		"faith_cost": faith_cost,
		"enabled": Colony.can_afford(cost) and Divine.faith >= faith_cost,
		"recommended": recommended,
	}


func _present_pending() -> void:
	if pending.is_empty():
		return
	var event_id := StringName(pending.get("id", &""))
	Events.storyteller_event.emit(event_id, pending.duplicate(true))
	if DisplayServer.get_name() == "headless":
		resolve_event(_automatic_choice())


func present_pending() -> void:
	if not pending.is_empty():
		_present_pending()


func _automatic_choice() -> StringName:
	for choice: Dictionary in pending.get("choices", []):
		if bool(choice.get("enabled", false)) and bool(choice.get("recommended", false)):
			return StringName(choice.get("id", &""))
	for choice: Dictionary in pending.get("choices", []):
		if bool(choice.get("enabled", false)):
			return StringName(choice.get("id", &""))
	return &""


func resolve_event(choice_id: StringName) -> bool:
	if pending.is_empty():
		return false
	var selected: Dictionary = {}
	for choice: Dictionary in pending.get("choices", []):
		if StringName(choice.get("id", &"")) == choice_id:
			selected = choice
			break
	if selected.is_empty() or not bool(selected.get("enabled", false)):
		return false
	var cost: Dictionary = selected.get("cost", {})
	var faith_cost := float(selected.get("faith_cost", 0.0))
	if not Colony.can_afford(cost) or Divine.faith < faith_cost:
		return false
	if not cost.is_empty():
		Colony.spend(cost)
	if faith_cost > 0.0:
		Divine.faith -= faith_cost
		Events.faith_changed.emit(Divine.faith)

	var event_id := StringName(pending.get("id", &""))
	var family := StringName(pending.get("family", EVENT_FAMILY.get(event_id, event_id)))
	_apply_choice(family, choice_id, pending)
	resolved_count += 1
	pending.clear()
	_schedule_next()
	Events.storyteller_resolved.emit(event_id, choice_id)
	Events.notice.emit(tr(&"STORY_RESOLVED"), 0)
	return true


func _apply_choice(event_id: StringName, choice_id: StringName, payload: Dictionary) -> void:
	match event_id:
		&"caravan":
			if choice_id == &"tools":
				Colony.add(&"tools", 3)
				Colony.add(&"boards", 8)
			elif choice_id == &"provisions":
				Colony.add(&"food", 30)
		&"refugees":
			if choice_id == &"welcome":
				Colony.admit_event_survivors(int(payload.get("count", 1)))
			elif choice_id == &"provision":
				Divine.faith = minf(Divine.faith + 14.0, Divine.faith_max())
				Events.faith_changed.emit(Divine.faith)
				Colony.adjust_mood(3.0)
			elif choice_id == &"refuse":
				Colony.adjust_mood(-4.0)
		&"blight_surge":
			if choice_id == &"faith_ward":
				World.repel_blight(34)
			elif choice_id == &"stockade":
				World.repel_blight(18)
			else:
				World.seed_blight_surge(8)
		&"stormfront":
			if choice_id == &"reinforce":
				Climate.set_mitigation(&"storm_ward", Sim.day + 1)
			elif choice_id == &"shelter":
				Climate.set_mitigation(&"storm_ward", Sim.day)
				Colony.adjust_mood(1.5)
			else:
				World.seed_blight_surge(4)
		&"drought":
			if choice_id == &"cistern":
				Climate.set_mitigation(&"drought_relief", Sim.day + 2)
			elif choice_id == &"ration":
				Climate.set_mitigation(&"rationing", Sim.day + 1)
				Colony.adjust_mood(-2.0)
			else:
				Colony.adjust_mood(-3.0)


func _schedule_next() -> void:
	var rng := _rng_for(Sim.day, event_serial + 97)
	next_event_day = Sim.day + rng.randi_range(2, 3)


func _rng_for(day: int, serial: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ (day * 104729) ^ (serial * 8191) ^ 0x57027
	return rng


func to_dict() -> Dictionary:
	return {
		"world_seed": world_seed,
		"next_event_day": next_event_day,
		"event_serial": event_serial,
		"resolved_count": resolved_count,
		"pending": pending.duplicate(true),
	}


func load_dict(data: Dictionary) -> void:
	world_seed = int(data.get("world_seed", Realm.world_seed))
	next_event_day = int(data.get("next_event_day", Sim.day + 2))
	event_serial = int(data.get("event_serial", 0))
	resolved_count = int(data.get("resolved_count", 0))
	pending = data.get("pending", {}).duplicate(true)
	if not pending.is_empty():
		call_deferred("present_pending")
