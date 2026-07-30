extends Node
## Captures every title-screen state for visual regression checks. Run with:
##   Godot_v4.7-stable_win64_console.exe --path . res://scenes/dev/menu_screenshot.tscn

const OUT_DIR := "user://shots"
const MENU_SCENE := preload("res://scenes/ui/main_menu.tscn")


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var menu := MENU_SCENE.instantiate()
	add_child(menu)
	await get_tree().process_frame
	await get_tree().process_frame
	var probe: Button = menu.get_node("Center/Root/Rows/OptionsButton")
	print("theme probe: root=%d button=%d" % [
		get_tree().root.theme.get_font_size("font_size", "Button"),
		probe.get_theme_font_size("font_size"),
	])

	var names := ["07_menu", "08_new_world", "09_options", "10_credits"]
	for screen in names.size():
		menu.call("_show", screen)
		await get_tree().create_timer(0.25).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, names[screen]]
		img.save_png(path)
		print("wrote %s  (%s)" % [ProjectSettings.globalize_path(path), img.get_size()])

	get_tree().quit(0)
