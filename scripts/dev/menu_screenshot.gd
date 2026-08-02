extends Node
## Captures every title-screen state for visual regression checks. Run with:
##   Godot_v4.7-stable_win64_console.exe --path . res://scenes/dev/menu_screenshot.tscn

const OUT_DIR := "res://artifacts"
const MENU_SCENE := preload("res://scenes/ui/main_menu.tscn")


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var old_history := Meta.run_history.duplicate(true)
	var old_achievements := Meta.achievements.duplicate()
	var old_stats := Meta.lifetime_stats.duplicate(true)
	var old_palette := Accessibility.palette_mode
	Accessibility.set_palette_mode(0)
	Meta.run_history = [
		{"seed": 7302026, "difficulty": "harried", "day": 12, "colonies": 4,
			"population": 21, "monsters": 86, "shards": 94, "realm_completed": true},
		{"seed": 424242, "difficulty": "besieged", "day": 7, "colonies": 2,
			"population": 11, "monsters": 43, "shards": 58, "ascended": true},
	]
	Meta.achievements.assign([&"first_night", &"builder", &"network"])
	Meta.lifetime_stats = {"days": 52, "monsters": 248, "buildings": 63}
	var menu := MENU_SCENE.instantiate()
	add_child(menu)
	await get_tree().process_frame
	await get_tree().process_frame
	var probe: Button = menu.get_node("Center/Root/Rows/OptionsButton")
	print("theme probe: root=%d button=%d" % [
		get_tree().root.theme.get_font_size("font_size", "Button"),
		probe.get_theme_font_size("font_size"),
	])

	# Difficulty catalogs grow over time. Keep the primary action beside the form and
	# prove that another added row cannot silently push it beneath a short phone screen.
	menu.call("_show", 1)
	await _settle_frames()
	var begin_button := menu.get_node("Center/Create/Body/Actions/BeginButton") as Button
	var form := menu.get_node("Center/Create/Body/Rows") as VBoxContainer
	var viewport_size := get_viewport().get_visible_rect().size
	var mobile_safe_rect := Rect2(Vector2(8, 8), viewport_size - Vector2(16, 16))
	assert(mobile_safe_rect.encloses(begin_button.get_global_rect()),
		"New World primary action must remain inside the mobile viewport")
	assert(begin_button.global_position.x >= form.get_global_rect().end.x,
		"New World primary action must remain in the right-hand action rail")

	var screens := [
		[0, "phase5_menu"],
		[1, "phase5_new_world"],
		[2, "phase5_options_audio"],
		[3, "phase5_chronicle"],
		[4, "phase5_credits"],
	]
	for row: Array in screens:
		menu.call("_show", int(row[0]))
		await _settle_frames()
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, row[1]]
		var save_error := img.save_png(path)
		assert(save_error == OK, "Could not write %s: %s" % [path, error_string(save_error)])
		print("wrote %s  (%s)" % [ProjectSettings.globalize_path(path), img.get_size()])

	menu.call("_show", 2)
	var settings := menu.get_node("Center/Options/Rows/Settings") as SettingsPanel
	for tab_index in [1, 2]:
		settings.set_tab(tab_index)
		await _settle_frames()
		var image := get_viewport().get_texture().get_image()
		var suffix := "accessibility" if tab_index == 1 else "controls"
		var path := "%s/phase5_options_%s.png" % [OUT_DIR, suffix]
		var save_error := image.save_png(path)
		assert(save_error == OK, "Could not write %s: %s" % [path, error_string(save_error)])
		print("wrote %s  (%s)" % [ProjectSettings.globalize_path(path), image.get_size()])

	# Exercise the screen-space accessibility shader in a real renderer, not only its
	# settings data and material setup in headless tests.
	menu.call("_show", 0)
	Accessibility.set_palette_mode(1)
	await _settle_frames()
	var palette_image := get_viewport().get_texture().get_image()
	var palette_path := "%s/phase5_palette_red_green.png" % OUT_DIR
	var palette_error := palette_image.save_png(palette_path)
	assert(palette_error == OK,
		"Could not write %s: %s" % [palette_path, error_string(palette_error)])
	print("wrote %s  (%s)" % [
		ProjectSettings.globalize_path(palette_path), palette_image.get_size()])

	Accessibility.set_palette_mode(old_palette)
	Meta.run_history.assign(old_history)
	Meta.achievements.assign(old_achievements)
	Meta.lifetime_stats = old_stats
	get_tree().quit(0)


func _settle_frames() -> void:
	for _i in 8:
		await get_tree().process_frame
