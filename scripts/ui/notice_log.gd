extends VBoxContainer
## The toast log: the one thing that actually listens to Events.notice.
##
## Before this existed, `Events.notice` had exactly one subscriber — the end-of-run card,
## which kept only urgency-2 lines and showed them after the run was already over. So
## "The Blight stirs — night 3" and "The night holds." were emitted every single night and
## never once reached the player. This is that fix.
##
## Toasts stack downward, newest last, and expire on their own. Urgency drives colour and
## lifetime, not position: a player scanning for the alarm should find it by colour, and
## reordering entries under their eyes is how you make a log unreadable.

## Oldest toasts are dropped past this. A wall of text during a bad night hides the very
## line the player needs.
const MAX_TOASTS := 4

const LIFETIME := {
	0: 3.5,    # info
	1: 5.0,    # warning
	2: 7.0,    # alarm — the ones you must not miss get the longest dwell
}

const FADE_TIME := 0.45

## entry -> seconds remaining
var _live: Dictionary = {}


func _ready() -> void:
	# Toasts must never eat a tap meant for the world. The log sits over the play area,
	# and a missed Ember drag because a notification was in the way would be maddening.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Events.notice.connect(_on_notice)


func _on_notice(text: String, urgency: int) -> void:
	if text.is_empty():
		return

	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", _color_for(urgency))
	label.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE)
	# Alarms get an outline so they stay readable against a lit fire or a pale dawn sky.
	if urgency >= 2:
		label.add_theme_color_override("font_outline_color", UiPalette.BG_DEEP)
		label.add_theme_constant_override("outline_size", 4)
	add_child(label)

	_live[label] = float(LIFETIME.get(urgency, 4.0))
	_trim()


func _trim() -> void:
	while get_child_count() > MAX_TOASTS:
		var oldest := get_child(0)
		_live.erase(oldest)
		oldest.queue_free()


func _process(delta: float) -> void:
	if _live.is_empty():
		return
	# Iterate a copy: expiring an entry mutates the dictionary underneath us. Typed, so the
	# modulate and queue_free calls below are checked rather than resolved at runtime.
	for entry: Label in _live.keys():
		if not is_instance_valid(entry):
			_live.erase(entry)
			continue
		var remaining: float = _live[entry] - delta
		if remaining <= 0.0:
			_live.erase(entry)
			entry.queue_free()
			continue
		_live[entry] = remaining
		# Fade out over the last stretch rather than vanishing. A toast that pops out of
		# existence reads as a glitch.
		if remaining < FADE_TIME:
			entry.modulate.a = remaining / FADE_TIME


static func _color_for(urgency: int) -> Color:
	match urgency:
		2: return UiPalette.DANGER
		1: return UiPalette.WARN
		_: return UiPalette.TEXT_DIM
