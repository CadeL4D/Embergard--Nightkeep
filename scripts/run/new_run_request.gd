class_name NewRunRequest
extends RefCounted
## What the main menu asks the run scene to do when it loads.
##
## `change_scene_to_file` takes no arguments, so a menu that wants to say "start seed 4812
## on Besieged, and let me pick the site" needs somewhere to leave the note. This is that
## somewhere — three static fields, explicitly named, consumed exactly once.
##
## Deliberately not an autoload and deliberately not tacked onto Meta: this is transient
## handoff state, and putting it in the profile would risk writing it to disk, where a
## stale "start a new run" flag is a genuinely nasty bug.

static var pending: bool = false
static var seed_value: int = 0
static var difficulty: StringName = &""
static var pick_site: bool = true
static var doctrines: Array[StringName] = []


static func set_request(new_seed: int, difficulty_id: StringName, choose_site: bool,
		doctrine_ids: Array = []) -> void:
	pending = true
	seed_value = new_seed
	difficulty = difficulty_id
	pick_site = choose_site
	doctrines = Doctrines.sanitize(doctrine_ids)


## Read and clear. Consuming on read is what stops a returning player being dropped into a
## brand new world because the flag was still set from last time.
static func consume() -> Dictionary:
	var out := {
		"pending": pending,
		"seed": seed_value,
		"difficulty": difficulty,
		"pick_site": pick_site,
		"doctrines": doctrines.duplicate(),
	}
	pending = false
	doctrines.clear()
	return out
