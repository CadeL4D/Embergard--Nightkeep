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
const SCHEMA_VERSION := 3
const HISTORY_LIMIT := 24
const ACHIEVEMENT_TOTAL := 8

var shards: int = 0
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
}
var achievements: Array[StringName] = []
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
	if version < SCHEMA_VERSION:
		_migrate(cfg, version)
	shards = cfg.get_value(SECTION, "shards", 0)
	ascension = cfg.get_value(SECTION, "ascension", 0)
	best_day = cfg.get_value(SECTION, "best_day", 0)
	runs_played = cfg.get_value(SECTION, "runs_played", 0)
	last_difficulty = StringName(cfg.get_value(SECTION, "last_difficulty", "harried"))
	unlocked.assign(cfg.get_value(SECTION, "unlocked", []))
	run_history.assign(cfg.get_value(SECTION, "run_history", []))
	lifetime_stats.merge(cfg.get_value(SECTION, "lifetime_stats", {}), true)
	achievements.assign(cfg.get_value(SECTION, "achievements", []))


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
	save_profile()
	return newly_unlocked


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
