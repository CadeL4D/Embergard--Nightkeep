extends Node
## Real-renderer QA for Phase 6 weather, HUD fit, and storyteller choices.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const OUT_DIR := "res://artifacts"

var _run: Node2D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var profile := _profile_snapshot()
	var tutorial_enabled := Accessibility.tutorials_enabled
	var tutorial_seen := Accessibility.tutorial_seen.duplicate()
	Accessibility.tutorials_enabled = false
	NewRunRequest.set_request(6072026, &"harried", false)
	_run = RUN_SCENE.instantiate()
	add_child(_run)
	await _settle(18)

	Sim.day = 13
	Climate.force_weather(&"storm", 1.0)
	await _settle(18)
	_capture("phase6_storm")

	Colony.add(&"food", 24)
	Storyteller.force_event(&"caravan")
	await _settle(12)
	_capture("phase6_story_event")

	_restore_profile(profile)
	Accessibility.tutorials_enabled = tutorial_enabled
	Accessibility.tutorial_seen.assign(tutorial_seen)
	Accessibility.save_settings()
	RunSave.clear()
	get_tree().quit(0)


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _capture(name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var error := image.save_png(path)
	if error != OK:
		push_error("could not write %s: %s" % [path, error_string(error)])
	print("wrote %s" % ProjectSettings.globalize_path(path))


func _profile_snapshot() -> Dictionary:
	return {
		"shards": Meta.shards,
		"unlocked": Meta.unlocked.duplicate(),
		"ascension": Meta.ascension,
		"best_day": Meta.best_day,
		"runs_played": Meta.runs_played,
		"last_difficulty": Meta.last_difficulty,
		"run_history": Meta.run_history.duplicate(true),
		"lifetime_stats": Meta.lifetime_stats.duplicate(true),
		"achievements": Meta.achievements.duplicate(),
	}


func _restore_profile(profile: Dictionary) -> void:
	Meta.shards = profile["shards"]
	Meta.unlocked.assign(profile["unlocked"])
	Meta.ascension = profile["ascension"]
	Meta.best_day = profile["best_day"]
	Meta.runs_played = profile["runs_played"]
	Meta.last_difficulty = profile["last_difficulty"]
	Meta.run_history.assign(profile["run_history"])
	Meta.lifetime_stats = profile["lifetime_stats"]
	Meta.achievements.assign(profile["achievements"])
	Meta.save_profile()
