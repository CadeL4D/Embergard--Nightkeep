extends CanvasLayer
## The player-facing HUD: the resource readout, and the Job Board.
##
## The Job Board is the game's main control surface — the whole point of the design
## is that you steer a colony with a handful of sliders rather than by dragging
## individuals. Rows are built at runtime from the Jobs catalog, so adding a job
## .tres puts a slider on the board with no UI work.
##
## Every row shows BOTH the quota and the live headcount ("3/4"). That second
## number matters more than it looks: when a player sets a slider and nothing
## appears to happen, the readout is what tells them whether the order was
## impossible (nobody spare) or simply slow (people are still walking).

const JOB_ROW := preload("res://scenes/ui/job_row.tscn")
const BUILD_CARD := preload("res://scenes/ui/build_card.tscn")

@onready var _safe_area: MarginContainer = $SafeArea
@onready var _resources: Label = $SafeArea/Layout/TopRow/ResourceBar/Resources
@onready var _jobs_button: Button = $SafeArea/Layout/BottomRow/Buttons/JobsButton
@onready var _build_button: Button = $SafeArea/Layout/BottomRow/Buttons/BuildButton
@onready var _ascend_button: Button = $SafeArea/Layout/BottomRow/Buttons/AscendButton
@onready var _job_panel: PanelContainer = $SafeArea/Layout/BottomRow/JobPanel
@onready var _rows: VBoxContainer = $SafeArea/Layout/BottomRow/JobPanel/Rows
@onready var _build_panel: PanelContainer = $SafeArea/Layout/BottomRow/BuildPanel
@onready var _cards: HBoxContainer = $SafeArea/Layout/BottomRow/BuildPanel/Cards
@onready var _placement_bar: PanelContainer = $SafeArea/Layout/BottomRow/PlacementBar
@onready var _placement_status: Label = $SafeArea/Layout/BottomRow/PlacementBar/Row/Status
@onready var _confirm_button: Button = $SafeArea/Layout/BottomRow/PlacementBar/Row/ConfirmButton
@onready var _cancel_button: Button = $SafeArea/Layout/BottomRow/PlacementBar/Row/CancelButton
@onready var _powers: HBoxContainer = $SafeArea/Layout/BottomRow/Buttons/Powers
@onready var _phase_label: Label = $SafeArea/Layout/PhaseBar/Phase

## job id -> {slider, count label}
var _row_widgets: Dictionary = {}
## building id -> card button
var _card_widgets: Dictionary = {}
## power id -> button
var _power_widgets: Dictionary = {}
var _god_hand: Node = null
var _refresh_accum: float = 0.0
var _placement: Node = null
var _ascend_armed: bool = false
var _ascend_timer: float = 0.0


func _ready() -> void:
	_apply_safe_area()
	get_tree().root.size_changed.connect(_apply_safe_area)

	_jobs_button.toggled.connect(_on_jobs_toggled)
	_build_button.toggled.connect(_on_build_toggled)
	_ascend_button.pressed.connect(_on_ascend)
	_confirm_button.pressed.connect(_on_confirm)
	_cancel_button.pressed.connect(_on_cancel)
	Events.resources_changed.connect(_on_resources_changed)
	Events.run_started.connect(_on_run_started)

	# The placement controller lives in the run scene because it needs world space;
	# the HUD only drives it. Looked up rather than exported so the HUD can also be
	# dropped into a UI-only test scene without one.
	_placement = get_node_or_null("../PlacementController")
	if _placement != null:
		_placement.placement_changed.connect(_on_placement_changed)

	_god_hand = get_node_or_null("../GodHand")
	if _god_hand != null:
		_god_hand.armed_changed.connect(_on_armed_changed)

	_build_rows()
	_build_cards()
	_build_powers()
	_refresh()


# --- Layout ------------------------------------------------------------------------

func _apply_safe_area() -> void:
	SafeArea.apply(_safe_area, 8)


# --- Job rows ------------------------------------------------------------------------

func _build_rows() -> void:
	for id in _row_widgets:
		var w: Dictionary = _row_widgets[id]
		w["root"].queue_free()
	_row_widgets.clear()

	for job: JobDef in Jobs.all():
		var row: HBoxContainer = JOB_ROW.instantiate()
		row.name = "Row_%s" % job.id
		_rows.add_child(row)

		var swatch: ColorRect = row.get_node("Swatch")
		var name_label: Label = row.get_node("JobName")
		var slider: HSlider = row.get_node("Slider")
		var count: Label = row.get_node("Count")

		swatch.color = job.color
		name_label.text = job.display_name
		name_label.add_theme_color_override("font_color", job.color)
		slider.value = Colony.quota_of(job.id)
		slider.value_changed.connect(_on_slider_changed.bind(job.id))

		_row_widgets[job.id] = {"root": row, "slider": slider, "count": count}


func _on_slider_changed(value: float, job_id: StringName) -> void:
	Colony.set_quota(job_id, int(value))
	_refresh()


func _on_jobs_toggled(pressed: bool) -> void:
	_job_panel.visible = pressed
	if pressed:
		_build_button.button_pressed = false


# --- Build menu ------------------------------------------------------------------------

func _build_cards() -> void:
	for id in _card_widgets:
		_card_widgets[id].queue_free()
	_card_widgets.clear()

	for def: BuildingDef in Buildings.placeable():
		var card: Button = BUILD_CARD.instantiate()
		card.name = "Card_%s" % def.id
		card.tooltip_text = def.description
		_cards.add_child(card)

		var icon: TextureRect = card.get_node("Layout/Icon")
		var name_label: Label = card.get_node("Layout/BuildingName")
		var cost_label: Label = card.get_node("Layout/Cost")
		icon.texture = def.sprite
		name_label.text = def.display_name
		name_label.add_theme_color_override("font_color", def.color)
		cost_label.text = def.cost_text()

		card.pressed.connect(_on_card_pressed.bind(def))
		_card_widgets[def.id] = card


func _on_build_toggled(pressed: bool) -> void:
	_build_panel.visible = pressed
	if pressed:
		_jobs_button.button_pressed = false
	elif _placement != null and _placement.active:
		_placement.cancel()
	_refresh_cards()


func _on_card_pressed(def: BuildingDef) -> void:
	if _placement == null:
		return
	_placement.begin(def)


func _on_confirm() -> void:
	if _placement != null:
		_placement.confirm()


func _on_cancel() -> void:
	if _placement != null:
		_placement.cancel()


## Ascending is irreversible and ends the run, so it takes two presses. A single
## mistap next to the Build button should never cost someone their colony.
func _on_ascend() -> void:
	if not _ascend_armed:
		_ascend_armed = true
		_ascend_button.text = "Sure?"
		_ascend_timer = 3.0
		return
	_ascend_armed = false
	_ascend_button.text = "Ascend"
	var run := get_parent()
	if run != null and run.has_method("ascend"):
		run.ascend()


## Placement mode replaces the build menu rather than sitting alongside it. Two
## competing panels in the thumb zone is how you get mis-taps on a phone.
func _on_placement_changed(active: bool, status: String, valid: bool) -> void:
	_placement_bar.visible = active
	_build_panel.visible = _build_button.button_pressed and not active
	if not active:
		return
	_placement_status.text = status
	_placement_status.add_theme_color_override("font_color",
		Color(0.72, 0.88, 0.72) if valid else Color(0.95, 0.6, 0.55))
	_confirm_button.disabled = not valid


# --- Powers ----------------------------------------------------------------------------

func _build_powers() -> void:
	for id in _power_widgets:
		_power_widgets[id].queue_free()
	_power_widgets.clear()

	for def: PowerDef in Powers.all():
		var button := Button.new()
		button.name = "Power_%s" % def.id
		button.custom_minimum_size = Vector2(96, 26)
		button.toggle_mode = true
		button.tooltip_text = def.description
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_color_override("font_color", def.color)
		button.pressed.connect(_on_power_pressed.bind(def))
		_powers.add_child(button)
		_power_widgets[def.id] = button


func _on_power_pressed(def: PowerDef) -> void:
	if _god_hand == null:
		return
	# Arming a power closes the build and job panels: all three want the bottom of
	# the screen, and the tap that arms a power must not also land on a menu.
	_jobs_button.button_pressed = false
	_build_button.button_pressed = false
	_god_hand.arm(def)


func _on_armed_changed(power: PowerDef) -> void:
	for id in _power_widgets:
		var button: Button = _power_widgets[id]
		button.set_pressed_no_signal(power != null and power.id == id)


## Powers show cost, and the cooldown counts down in the label. A greyed button
## with no explanation is indistinguishable from a broken one.
func _refresh_powers() -> void:
	for id in _power_widgets:
		var def := Powers.get_power(id)
		if def == null:
			continue
		var button: Button = _power_widgets[id]
		var cd := Divine.cooldown_of(id)
		if cd > 0.0:
			button.text = "%s %.0fs" % [def.display_name, ceilf(cd)]
			button.disabled = true
		else:
			button.text = "%s  %d" % [def.display_name, int(def.faith_cost)]
			button.disabled = Divine.faith < def.faith_cost


## Grey out anything the colony cannot currently pay for. Showing the card but
## disabled — rather than hiding it — is deliberate: players need to know a building
## exists and what it costs before they can work toward it.
func _refresh_cards() -> void:
	for id in _card_widgets:
		var def := Buildings.get_building(id)
		if def == null:
			continue
		var card: Button = _card_widgets[id]
		var affordable := Colony.can_afford(def.cost)
		card.disabled = not affordable
		card.modulate = Color.WHITE if affordable else Color(1, 1, 1, 0.5)


func _on_run_started(_seed: int) -> void:
	# Quotas are reset per run, so the sliders have to be pulled back into line or
	# the board shows last run's numbers over this run's colony.
	for id in _row_widgets:
		var w: Dictionary = _row_widgets[id]
		var slider: HSlider = w["slider"]
		slider.set_block_signals(true)
		slider.value = Colony.quota_of(id)
		slider.set_block_signals(false)
	_refresh()


# --- Refresh -------------------------------------------------------------------------

func _process(delta: float) -> void:
	# Headcounts change as the reconciler runs, so the board needs polling — but at
	# 4 Hz, not per frame. A per-frame rebuild of these strings shows up in the
	# profiler as the UI's own cost while you are trying to profile the sim.
	if _ascend_armed:
		_ascend_timer -= delta
		if _ascend_timer <= 0.0:
			_ascend_armed = false
			_ascend_button.text = "Ascend"

	_refresh_accum += delta
	if _refresh_accum < 0.25:
		return
	_refresh_accum = 0.0
	# Mood and Faith drift continuously rather than firing a signal, so the top bar
	# has to poll. Resource counts still refresh on their signal for immediacy.
	_refresh_resources()
	_refresh_powers()
	_refresh_phase()
	if _job_panel.visible:
		_refresh_counts()
	if _build_panel.visible:
		_refresh_cards()


## The phase clock is the game's spine, and at dusk it becomes the most important
## thing on screen — the countdown is what turns "it is getting dark" into a
## scramble.
func _refresh_phase() -> void:
	var names := ["DAY", "DUSK", "NIGHT", "DAWN"]
	var colors := [
		Color(0.82, 0.86, 0.9),
		Color(1.0, 0.65, 0.35),
		Color(0.72, 0.62, 0.95),
		Color(0.9, 0.8, 0.6),
	]
	var extra := ""
	if Sim.phase == Sim.Phase.NIGHT and Threat.alive_count() > 0:
		extra = "   %d hostile" % Threat.alive_count()
	_phase_label.text = "Day %d   %s   %ds%s" % [
		Sim.day, names[Sim.phase], int(Sim.seconds_remaining()), extra]
	_phase_label.add_theme_color_override("font_color", colors[Sim.phase])


func _refresh() -> void:
	_refresh_resources()
	_refresh_counts()
	_refresh_cards()
	_refresh_powers()
	_refresh_phase()


func _on_resources_changed(_kind: StringName, _amount: int) -> void:
	_refresh_resources()


func _refresh_resources() -> void:
	# Faith shows its RATE alongside its value. The rate is driven by colony mood,
	# and a number that silently depends on morale is indistinguishable from a
	# broken one — the player has to be able to see that unhappy villagers are why
	# their miracles are not charging.
	# Two lines rather than one long row. On a phone in portrait a single strip of
	# six figures runs off the edge, and here it had already grown long enough to
	# collide with the debug overlay on the opposite side of the screen.
	_resources.text = "wood %d    stone %d    food %d\npop %d    mood %d    faith %d (x%.1f)" % [
		Colony.amount_of(&"wood"),
		Colony.amount_of(&"stone"),
		Colony.amount_of(&"food"),
		Colony.population(),
		int(Colony.average_mood()),
		int(Divine.faith),
		Divine.faith_multiplier(),
	]


func _refresh_counts() -> void:
	# Slider range tracks the population (plus headroom), so the useful part of the
	# track is the whole track. A fixed max of 20 with six survivors squeezed every
	# meaningful value into the first tenth of the slider, which on a phone is
	# roughly one thumb-width for the entire decision.
	var slider_max := maxf(float(Colony.population()) + 2.0, 4.0)

	for id in _row_widgets:
		var w: Dictionary = _row_widgets[id]
		var count: Label = w["count"]
		var slider: HSlider = w["slider"]
		if not is_equal_approx(slider.max_value, slider_max):
			slider.max_value = slider_max
		var have := Colony.headcount_of(id)
		var want := Colony.quota_of(id)
		count.text = "%d/%d" % [have, want]
		# Amber when the colony cannot meet the order — the player needs to see
		# "you asked for more people than you have" without opening a tutorial.
		count.add_theme_color_override("font_color",
			Color(0.9, 0.72, 0.35) if have < want else Color(0.7, 0.76, 0.82))
