extends Node
## Autoload: the persistent profile that outlives any single run — Relic Shards,
## unlocks and lifetime stats.
##
## Uses ConfigFile under user://, matching the existing persistence style. Kept
## strictly separate from the run save: this file must survive a corrupted or
## abandoned run, because losing meta-progression is the one failure a rogue-lite
## player will not forgive.

const SAVE_PATH := "user://profile.cfg"
const SECTION := "profile"
const SCHEMA_VERSION := 5
const HISTORY_LIMIT := 24
const ACHIEVEMENT_TOTAL := 117

var shards: int = 0
var god_experience: int:
	get: return shards
	set(value): shards = maxi(value, 0)
var unlocked_chest_slots: int = 0
var chest_progress: float = 0.0
var chests: Array[Dictionary] = []
var god_perks: Dictionary = {}
var unlocked: Array[StringName] = []
var ascension: int = 0
var best_day: int = 0
var runs_played: int = 0
var run_history: Array[Dictionary] = []
var lifetime_stats: Dictionary = {
	"days": 0,
	"buildings": 0,
	"nests": 0,
	"monsters": 0,
	"villagers_lost": 0,
	"realms_completed": 0,
	"events": 0,
	"resources_hauled": 0,
	"powers_cast": 0,
	"colonies_founded": 0,
}
var achievements: Array[StringName] = []
var chronicle_completed: Array[StringName] = []
var equipped_doctrines: Array[StringName] = []
## The tier the player last chose, so the New World screen opens on it rather than
## making them re-pick every session. Profile state, not run state — the run's own
## difficulty is saved with the run.
var last_difficulty: StringName = &"harried"


func _ready() -> void:
	load_profile()


# --- Persistence -------------------------------------------------------------------

func load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	var version: int = cfg.get_value(SECTION, "version", 0)
	if version != SCHEMA_VERSION:
		_reset_progression()
		return
	shards = cfg.get_value(SECTION, "shards", 0)
	ascension = cfg.get_value(SECTION, "ascension", 0)
	best_day = cfg.get_value(SECTION, "best_day", 0)
	runs_played = cfg.get_value(SECTION, "runs_played", 0)
	last_difficulty = StringName(cfg.get_value(SECTION, "last_difficulty", "harried"))
	unlocked.assign(cfg.get_value(SECTION, "unlocked", []))
	run_history.assign(cfg.get_value(SECTION, "run_history", []))
	lifetime_stats.merge(cfg.get_value(SECTION, "lifetime_stats", {}), true)
	achievements.assign(cfg.get_value(SECTION, "achievements", []))
	chronicle_completed.assign(cfg.get_value(SECTION, "chronicle_completed", []))
	unlocked_chest_slots = int(cfg.get_value(SECTION, "unlocked_chest_slots", 0))
	chest_progress = float(cfg.get_value(SECTION, "chest_progress", 0.0))
	chests.assign(cfg.get_value(SECTION, "chests", []))
	god_perks = cfg.get_value(SECTION, "god_perks", {}).duplicate(true)
	equipped_doctrines = Doctrines.sanitize(cfg.get_value(SECTION, "equipped_doctrines", []))


func save_profile() -> void:
	var cfg := ConfigFile.new()
	# Audio, accessibility, tutorials and remapped controls share this file. Merge before
	# writing or earning one shard would reset every preference.
	cfg.load(SAVE_PATH)
	cfg.set_value(SECTION, "version", SCHEMA_VERSION)
	cfg.set_value(SECTION, "shards", shards)
	cfg.set_value(SECTION, "ascension", ascension)
	cfg.set_value(SECTION, "best_day", best_day)
	cfg.set_value(SECTION, "runs_played", runs_played)
	cfg.set_value(SECTION, "last_difficulty", String(last_difficulty))
	cfg.set_value(SECTION, "unlocked", unlocked)
	cfg.set_value(SECTION, "run_history", run_history)
	cfg.set_value(SECTION, "lifetime_stats", lifetime_stats)
	cfg.set_value(SECTION, "achievements", achievements)
	cfg.set_value(SECTION, "chronicle_completed", chronicle_completed)
	cfg.set_value(SECTION, "unlocked_chest_slots", unlocked_chest_slots)
	cfg.set_value(SECTION, "chest_progress", chest_progress)
	cfg.set_value(SECTION, "chests", chests)
	cfg.set_value(SECTION, "god_perks", god_perks)
	cfg.set_value(SECTION, "equipped_doctrines", equipped_doctrines)
	cfg.save(SAVE_PATH)


## Remember the player's tier choice. Written straight through rather than batched,
## because the profile is also what survives a crash.
func set_last_difficulty(id: StringName) -> void:
	if id == &"" or id == last_difficulty:
		return
	last_difficulty = id
	save_profile()


func _migrate(_cfg: ConfigFile, _from_version: int) -> void:
	# Schema 2 only adds fields with safe defaults. Keeping migration explicit documents that
	# old profiles are retained rather than treated as invalid.
	pass


func _reset_progression() -> void:
	shards = 0
	unlocked.clear()
	ascension = 0
	best_day = 0
	runs_played = 0
	run_history.clear()
	lifetime_stats = {
		"days": 0, "buildings": 0, "nests": 0, "monsters": 0,
		"villagers_lost": 0, "realms_completed": 0, "events": 0,
		"resources_hauled": 0, "powers_cast": 0, "colonies_founded": 0,
	}
	achievements.clear()
	chronicle_completed.clear()
	equipped_doctrines.clear()
	unlocked_chest_slots = 0
	chest_progress = 0.0
	chests.clear()
	god_perks.clear()


# --- Unlocks -----------------------------------------------------------------------

func is_unlocked(id: StringName) -> bool:
	return id in unlocked


func unlock(id: StringName) -> void:
	if id in unlocked:
		return
	unlocked.append(id)
	save_profile()


## A world seen through to a deliberate end. Raises baseline difficulty for every future run.
##
## Kept as its own call rather than folded into award() because the two answer different questions:
## award() records that a run HAPPENED, this records that one was COMPLETED. Only the second should
## make the next world harder.
func record_ascension() -> void:
	ascension += 1
	save_profile()


func award(amount: int, day_reached: int) -> void:
	shards += amount
	best_day = maxi(best_day, day_reached)
	runs_played += 1
	save_profile()


func set_equipped_doctrines(ids: Array) -> void:
	var clean := Doctrines.sanitize(ids)
	if clean == equipped_doctrines:
		return
	equipped_doctrines = clean
	save_profile()


## Add one immutable result card to history and update lifetime counters/achievements.
## The shard payout is recorded here but awarded separately, so existing run-end ordering and
## summary animation remain unchanged.
func record_run(record: Dictionary) -> Array[StringName]:
	var clean := record.duplicate(true)
	clean["timestamp"] = int(Time.get_unix_time_from_system())
	run_history.push_front(clean)
	if run_history.size() > HISTORY_LIMIT:
		run_history.resize(HISTORY_LIMIT)
	lifetime_stats["days"] = int(lifetime_stats.get("days", 0)) + int(clean.get("day", 0))
	lifetime_stats["buildings"] = int(lifetime_stats.get("buildings", 0)) \
		+ int(clean.get("buildings", 0))
	lifetime_stats["nests"] = int(lifetime_stats.get("nests", 0)) + int(clean.get("nests", 0))
	lifetime_stats["monsters"] = int(lifetime_stats.get("monsters", 0)) \
		+ int(clean.get("monsters", 0))
	lifetime_stats["villagers_lost"] = int(lifetime_stats.get("villagers_lost", 0)) \
		+ int(clean.get("villagers_lost", 0))
	lifetime_stats["events"] = int(lifetime_stats.get("events", 0)) \
		+ int(clean.get("events", 0))
	if bool(clean.get("realm_completed", false)):
		lifetime_stats["realms_completed"] = int(lifetime_stats.get("realms_completed", 0)) + 1

	var newly_unlocked: Array[StringName] = []
	_unlock_achievement(&"first_night", int(clean.get("day", 0)) >= 2, newly_unlocked)
	_unlock_achievement(&"builder", int(clean.get("buildings", 0)) >= 10, newly_unlocked)
	_unlock_achievement(&"purifier", int(clean.get("nests", 0)) >= 4, newly_unlocked)
	_unlock_achievement(&"survivor", int(clean.get("day", 0)) >= 10, newly_unlocked)
	_unlock_achievement(&"realmkeeper", bool(clean.get("realm_completed", false)), newly_unlocked)
	_unlock_achievement(&"network", int(clean.get("colonies", 0)) >= 4, newly_unlocked)
	_unlock_achievement(&"weathered", int(clean.get("day", 0)) >= 21, newly_unlocked)
	_unlock_achievement(&"chronicler", int(clean.get("events", 0)) >= 4, newly_unlocked)
	clean["new_achievements"] = newly_unlocked
	var new_goals: Array[StringName] = []
	if bool(clean.get("progression_awards", true)):
		for goal: Dictionary in Chronicle.evaluate(lifetime_stats, chronicle_completed):
			var goal_id := StringName(goal["id"])
			new_goals.append(goal_id)
			god_experience += int(goal.get("god_xp", goal.get("shards", 0)))
			add_chest_progress(float(goal.get("god_xp", goal.get("shards", 0))))
			if goal_id not in achievements:
				achievements.append(goal_id)
			unlocked_chest_slots += int(goal.get("chest_slots", 0))
			var doctrine_id := StringName(goal.get("unlock", &""))
			if doctrine_id != &"" and doctrine_id not in unlocked:
				unlocked.append(doctrine_id)
	clean["new_goals"] = new_goals
	save_profile()
	return newly_unlocked


## Chest progress and slots are profile state, so Doom World cannot erase an earned reward.
func add_chest_progress(amount: float) -> void:
	if amount <= 0.0:
		return
	chest_progress += amount
	while chest_progress >= 100.0 and chests.size() < unlocked_chest_slots:
		chest_progress -= 100.0
		chests.append(_roll_chest(chests.size() + achievements.size()))
	chest_progress = minf(chest_progress, 100.0 if chests.size() >= unlocked_chest_slots else INF)


func open_chest(slot: int) -> Dictionary:
	if slot < 0 or slot >= chests.size():
		return {}
	var reward: Dictionary = chests[slot].duplicate(true)
	chests.remove_at(slot)
	match StringName(reward.get("kind", &"")):
		&"god_xp":
			god_experience += int(reward.get("amount", 0))
		&"chest_slot":
			unlocked_chest_slots += int(reward.get("amount", 1))
		&"perk_point":
			god_perks[&"unspent"] = int(god_perks.get(&"unspent", 0)) \
				+ int(reward.get("amount", 1))
	save_profile()
	return reward


func purchase_perk(id: StringName, xp_cost: int, max_rank: int = 5) -> bool:
	var rank := int(god_perks.get(id, 0))
	if id.is_empty() or rank >= max_rank or god_experience < xp_cost:
		return false
	god_experience -= xp_cost
	god_perks[id] = rank + 1
	save_profile()
	return true


func perk_rank(id: StringName) -> int:
	return int(god_perks.get(id, 0))


func _roll_chest(serial: int) -> Dictionary:
	var roll := posmod(serial * 1103515245 + runs_played * 8191 + best_day, 100)
	if roll < 12:
		return {"kind": &"chest_slot", "amount": 1, "rarity": &"rare"}
	if roll < 42:
		return {"kind": &"perk_point", "amount": 1, "rarity": &"uncommon"}
	return {"kind": &"god_xp", "amount": 25 + (roll % 4) * 10, "rarity": &"common"}


func _unlock_achievement(id: StringName, condition: bool,
		newly_unlocked: Array[StringName]) -> void:
	if not condition or id in achievements:
		return
	achievements.append(id)
	newly_unlocked.append(id)


## Shards earned for a run. Rewards depth of play, not just survival time, so a
## short ambitious run can out-earn a long turtled one — losing must be a payout,
## never a wasted evening.
func shards_for_run(day_reached: int, buildings_built: int, nests_cleared: int) -> int:
	return day_reached * 3 + buildings_built + nests_cleared * 15


## Baseline difficulty rises with the size of the player's library. Run 20 with
## everything unlocked should be harder and stranger than run 1, not trivial —
## this is the single most important anti-boredom lever in the meta.
func threat_dial() -> float:
	return 1.0 + float(unlocked.size()) * 0.03 + float(ascension) * 0.15
