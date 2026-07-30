extends Node
## Autoload: applies the game's Theme to the root window.
##
## An autoload rather than a line in each screen's _ready because the theme has to reach
## every Control in every scene — the run scene, the summary card, the menus, and the dev
## scenes — and a per-scene call is a rule someone will forget the first time they add a
## screen. The root Window covers ordinary descendants; `apply()` also bridges every
## Node and CanvasLayer boundary, including Controls added later.
##
## Deliberately NOT project.godot's gui/theme/custom: that field wants a .tres on disk,
## and the theme is built from UiPalette at runtime so the palette stays the only place a
## colour is written down. See UiTheme.

var theme: Theme = null


func _ready() -> void:
	theme = UiTheme.build()
	apply()
	# A plain Node or CanvasLayer breaks Control theme inheritance. Catch each
	# place it restarts, including runtime-built HUD rows and buttons.
	get_tree().node_added.connect(_on_node_added)
	# Re-apply if the window is recreated. Cheap insurance — losing the theme leaves the
	# game looking like a stock Godot project, which is a bug report waiting to happen.
	get_tree().root.ready.connect(apply)


func apply() -> void:
	var root := get_tree().root
	if root != null and theme != null:
		root.theme = theme
		_apply_below(root)


func _on_node_added(node: Node) -> void:
	if theme == null or not node is Control:
		return
	var control := node as Control
	if not control.get_parent() is Control and control.theme == null:
		control.theme = theme


## Assign the shared Theme where inheritance restarts after a non-Control node.
## Descendant Controls inherit normally, so they do not each need a copy.
func _apply_below(node: Node) -> void:
	for child in node.get_children():
		if child is Control and not node is Control:
			var control := child as Control
			if control.theme == null:
				control.theme = theme
		_apply_below(child)
