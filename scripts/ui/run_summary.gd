extends CanvasLayer
## The end-of-run card: what you achieved, what you earned, and what it bought.
##
## The design rule this screen exists to enforce is that LOSING IS A PAYOUT. A
## rogue-lite where a failed run feels like a wasted evening does not get a second
## evening, so the card leads with what was gained rather than what went wrong, and
## always ends with a button that starts the next run immediately.

@onready var _title: Label = $Center/Card/Layout/Title
@onready var _message: Label = $Center/Card/Layout/Message
@onready var _stats: Label = $Center/Card/Layout/Stats
@onready var _seed: Button = $Center/Card/Layout/Seed
@onready var _shards: Label = $Center/Card/Layout/Shards
@onready var _achievements: Label = $Center/Card/Layout/Achievements
@onready var _unlocks: Label = $Center/Card/Layout/Unlocks
@onready var _unlock_button: Button = $Center/Card/Layout/UnlockButton
@onready var _new_run: Button = $Center/Card/Layout/NewRun
@onready var _menu_button: Button = $Center/Card/Layout/MenuButton
@onready var _card: PanelContainer = $Center/Card

## The cheapest thing still locked, offered on this card. An `Unlocks.Entry` rather than a
## BuildingDef, so powers are offered on the same footing — see Unlocks.
var _offer: Unlocks.Entry = null

var _last_notice: String = ""


func _ready() -> void:
	visible = false
	Events.run_ended.connect(_on_run_ended)
	Events.notice.connect(_on_notice)
	_new_run.pressed.connect(_on_new_run)
	_unlock_button.pressed.connect(_on_unlock)
	# Without this the main menu is a one-way door: the only way back to difficulty and
	# seed choice would be to quit the game.
	_menu_button.pressed.connect(_on_main_menu)
	_seed.pressed.connect(_copy_seed)


## The run's closing line arrives as a notice just after run_ended, so it is
## remembered here and shown on the card.
func _on_notice(text: String, urgency: int) -> void:
	if urgency >= 2:
		_last_notice = text


func _on_run_ended(ascended: bool, shards: int) -> void:
	_title.text = tr(&"SUMMARY_ASCENDED" if ascended else &"SUMMARY_FALLEN")
	_title.add_theme_color_override("font_color",
		UiPalette.ACCENT_PALE if ascended else UiPalette.DANGER)
	_message.text = _last_notice

	_stats.text = L10n.t(&"SUMMARY_STATS", [Sim.day, Colony.population()])
	_shards.text = L10n.t(&"SUMMARY_SHARDS", [shards, Meta.shards])
	var record: Dictionary = Meta.run_history[0] if not Meta.run_history.is_empty() else {}
	_seed.text = L10n.t(&"SUMMARY_COPY_SEED", [int(record.get("seed", World.seed_value))])
	var new_achievements: Array = record.get("new_achievements", [])
	var names := PackedStringArray()
	for id in new_achievements:
		names.append(tr(StringName("ACHIEVEMENT_" + String(id).to_upper())))
	_achievements.visible = not names.is_empty()
	_achievements.text = L10n.t(&"SUMMARY_ACHIEVEMENTS", [", ".join(names)])

	_refresh_offer()

	visible = true
	_card.modulate.a = 0.0
	_card.scale = Vector2(0.97, 0.97)
	_card.pivot_offset = _card.size * 0.5
	var reveal := create_tween().set_parallel(true)
	var duration := Accessibility.motion_duration(0.24)
	reveal.tween_property(_card, "modulate:a", 1.0, duration)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	reveal.tween_property(_card, "scale", Vector2.ONE, duration)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_new_run.grab_focus()


func _copy_seed() -> void:
	if Meta.run_history.is_empty():
		return
	DisplayServer.clipboard_set(str(Meta.run_history[0].get("seed", World.seed_value)))
	_seed.text = tr(&"HISTORY_COPIED")


## Offer the cheapest thing still locked, and let the PLAYER decide.
##
## The first version spent shards automatically the moment they were affordable.
## That is straightforwardly wrong: it quietly emptied the player's currency into
## whatever happened to be cheapest, so the reward for a good run was a number that
## went up and immediately back down. Spending is a choice, and it is most of what
## the meta layer is for.
func _refresh_offer() -> void:
	# Unlocks.cheapest() already sorts by price across every kind, so this no longer has to know
	# whether it is offering a building or a miracle.
	_offer = Unlocks.cheapest()

	if _offer == null:
		_unlocks.text = tr(&"SUMMARY_ALL_UNLOCKED")
		_unlock_button.visible = false
		return

	_unlock_button.visible = true
	_unlock_button.text = L10n.t(&"SUMMARY_UNLOCK_OFFER",
		[tr(_offer.display_name), _offer.cost])
	var affordable := Meta.shards >= _offer.cost
	_unlock_button.disabled = not affordable
	_unlocks.text = tr(_offer.description) if affordable else L10n.t(
		&"SUMMARY_UNLOCK_SHORT", [_offer.cost - Meta.shards, tr(_offer.display_name)])


func _on_unlock() -> void:
	if _offer == null or Meta.shards < _offer.cost:
		return
	Meta.shards -= _offer.cost
	Meta.unlock(_offer.id)
	_shards.text = L10n.t(&"SUMMARY_SHARDS_REMAINING", [Meta.shards])
	_refresh_offer()


## Back to the title. Safe from here specifically because the run is already over and its
## save already cleared — leaving mid-run would need a confirmation.
func _on_main_menu() -> void:
	visible = false
	_last_notice = ""
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _on_new_run() -> void:
	visible = false
	_last_notice = ""
	var run := get_parent()
	if run != null and run.has_method("start_run"):
		run.start_run(randi())
