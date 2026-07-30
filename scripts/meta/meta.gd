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
const SCHEMA_VERSION := 1

var shards: int = 0
var unlocked: Array[StringName] = []
var ascension: int = 0
var best_day: int = 0
var runs_played: int = 0
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


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "version", SCHEMA_VERSION)
	cfg.set_value(SECTION, "shards", shards)
	cfg.set_value(SECTION, "ascension", ascension)
	cfg.set_value(SECTION, "best_day", best_day)
	cfg.set_value(SECTION, "runs_played", runs_played)
	cfg.set_value(SECTION, "last_difficulty", String(last_difficulty))
	cfg.set_value(SECTION, "unlocked", unlocked)
	cfg.save(SAVE_PATH)


## Remember the player's tier choice. Written straight through rather than batched,
## because the profile is also what survives a crash.
func set_last_difficulty(id: StringName) -> void:
	if id == &"" or id == last_difficulty:
		return
	last_difficulty = id
	save_profile()


func _migrate(_cfg: ConfigFile, _from_version: int) -> void:
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
