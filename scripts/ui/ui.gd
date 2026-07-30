extends Node
## Autoload: applies the game's Theme to the root window.
##
## An autoload rather than a line in each screen's _ready because the theme has to reach
## every Control in every scene — the run scene, the summary card, the menus, and the dev
## scenes — and a per-scene call is a rule someone will forget the first time they add a
## screen. Setting it on the root Window propagates down to everything, including nodes
## added later.
##
## Deliberately NOT project.godot's gui/theme/custom: that field wants a .tres on disk,
## and the theme is built from UiPalette at runtime so the palette stays the only place a
## colour is written down. See UiTheme.

var theme: Theme = null


func _ready() -> void:
	theme = UiTheme.build()
	apply()
	# Re-apply if the window is recreated. Cheap insurance — losing the theme leaves the
	# game looking like a stock Godot project, which is a bug report waiting to happen.
	get_tree().root.ready.connect(apply)


func apply() -> void:
	var root := get_tree().root
	if root != null and theme != null:
		root.theme = theme
