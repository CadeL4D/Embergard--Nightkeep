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
@onready var _shards: Label = $Center/Card/Layout/Shards
@onready var _unlocks: Label = $Center/Card/Layout/Unlocks
@onready var _unlock_button: Button = $Center/Card/Layout/UnlockButton
@onready var _new_run: Button = $Center/Card/Layout/NewRun

## The cheapest thing still locked, offered on this card.
var _offer: BuildingDef = null

var _last_notice: String = ""


func _ready() -> void:
	visible = false
	Events.run_ended.connect(_on_run_ended)
	Events.notice.connect(_on_notice)
	_new_run.pressed.connect(_on_new_run)
	_unlock_button.pressed.connect(_on_unlock)


## The run's closing line arrives as a notice just after run_ended, so it is
## remembered here and shown on the card.
func _on_notice(text: String, urgency: int) -> void:
	if urgency >= 2:
		_last_notice = text


func _on_run_ended(ascended: bool, shards: int) -> void:
	_title.text = "You carry the Ember onward" if ascended else "The keep has fallen"
	_title.add_theme_color_override("font_color",
		Color(1.0, 0.85, 0.5) if ascended else Color(1.0, 0.55, 0.42))
	_message.text = _last_notice

	_stats.text = "Survived to day %d\n%d survivors remained" % [
		Sim.day, Colony.population()]
	_shards.text = "+%d Relic Shards   (%d total)" % [shards, Meta.shards]

	_refresh_offer()

	visible = true
	_new_run.grab_focus()


## Offer the cheapest thing still locked, and let the PLAYER decide.
##
## The first version spent shards automatically the moment they were affordable.
## That is straightforwardly wrong: it quietly emptied the player's currency into
## whatever happened to be cheapest, so the reward for a good run was a number that
## went up and immediately back down. Spending is a choice, and it is most of what
## the meta layer is for.
func _refresh_offer() -> void:
	var locked := Buildings.locked()
	_offer = null
	for def: BuildingDef in locked:
		if _offer == null or def.unlock_cost < _offer.unlock_cost:
			_offer = def

	if _offer == null:
		_unlocks.text = "Everything is unlocked."
		_unlock_button.visible = false
		return

	_unlock_button.visible = true
	_unlock_button.text = "Unlock %s  —  %d shards" % [_offer.display_name, _offer.unlock_cost]
	var affordable := Meta.shards >= _offer.unlock_cost
	_unlock_button.disabled = not affordable
	_unlocks.text = _offer.description if affordable else \
		"%d more shards for the %s." % [_offer.unlock_cost - Meta.shards, _offer.display_name]


func _on_unlock() -> void:
	if _offer == null or Meta.shards < _offer.unlock_cost:
		return
	Meta.shards -= _offer.unlock_cost
	Meta.unlock(_offer.id)
	_shards.text = "%d Relic Shards remaining" % Meta.shards
	_refresh_offer()


func _on_new_run() -> void:
	visible = false
	_last_notice = ""
	var run := get_parent()
	if run != null and run.has_method("start_run"):
		run.start_run(randi())
