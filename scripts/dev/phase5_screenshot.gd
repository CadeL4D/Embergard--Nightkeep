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
		"chronicle_completed": Meta.chronicle_completed.duplicate(),
		"equipped_doctrines": Meta.equipped_doctrines.duplicate(),
	}
	var tutorial_enabled := Accessibility.tutorials_enabled
	var tutorial_seen := Accessibility.tutorial_seen.duplicate()
	var high_visibility := Accessibility.high_visibility_targets
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
	var pause_menu := run.get_node("PauseMenu")
	pause_menu.open()
	pause_menu.call("_show_settings")
	pause_menu.get_node("Center/Card/Views/Settings/SettingsPanel").set_tab(2)
	await _settle()
	_capture("phase5_accessibility")
	pause_menu.close()
	onboarding.call("_skip_all")
	Accessibility.high_visibility_targets = true
	var hand := run.get_node("GodHand")
	hand.call("_select", Colony.villagers[0])
	Threat._spawn_one(Monsters.get_monster(&"shambler"), 1.0)
	if not Threat.monsters.is_empty():
		Threat.monsters[-1].position = World.grid.to_world_index(World.keep_cell) + Vector2(42, 8)
	await _settle()
	_capture("phase5_high_visibility")
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
	Meta.chronicle_completed.assign(profile["chronicle_completed"])
	Meta.equipped_doctrines.assign(profile["equipped_doctrines"])
	Meta.save_profile()
	Accessibility.tutorials_enabled = tutorial_enabled
	Accessibility.tutorial_seen.assign(tutorial_seen)
	Accessibility.high_visibility_targets = high_visibility
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
