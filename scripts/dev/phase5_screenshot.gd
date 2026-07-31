extends Node
## Visual QA for contextual onboarding and the expanded end-of-run card.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const OUT_DIR := "res://artifacts"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var profile := {
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
	var tutorial_enabled := Accessibility.tutorials_enabled
	var tutorial_seen := Accessibility.tutorial_seen.duplicate()
	Accessibility.tutorials_enabled = true
	Accessibility.tutorial_seen.clear()
	NewRunRequest.set_request(7302026, &"harried", false)
	var run := RUN_SCENE.instantiate()
	add_child(run)
	await _settle()
	_capture("phase5_onboarding")

	var onboarding := run.get_node("Onboarding")
	onboarding.call("_dismiss")
	onboarding.call("_dismiss")
	onboarding.call("_dismiss")
	run.ascend()
	await _settle()
	_capture("phase5_summary")

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
	Accessibility.tutorials_enabled = tutorial_enabled
	Accessibility.tutorial_seen.assign(tutorial_seen)
	Accessibility.save_settings()
	RunSave.clear()
	get_tree().quit(0)


func _settle() -> void:
	for _i in 12:
		await get_tree().process_frame


func _capture(name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	image.save_png(path)
	print("wrote %s" % ProjectSettings.globalize_path(path))
