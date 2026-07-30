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
@onready var _resources: Label = $SafeArea/Layout/TopRow/ResourceColumn/ResourceBar/Resources
@onready var _resource_bar: PanelContainer = $SafeArea/Layout/TopRow/ResourceColumn/ResourceBar
@onready var _breakdown: BreakdownPanel = $SafeArea/Layout/TopRow/ResourceColumn/Breakdown
@onready var _jobs_button: Button = $SafeArea/Layout/BottomRow/Buttons/JobsButton
@onready var _build_button: Button = $SafeArea/Layout/BottomRow/Buttons/BuildButton
@onready var _ascend_button: Button = $SafeArea/Layout/BottomRow/Buttons/AscendButton
@onready var _job_panel: PanelContainer = $SafeArea/Layout/BottomRow/JobPanel
@onready var _rows: VBoxContainer = $SafeArea/Layout/BottomRow/JobPanel/Layout/Scroll/Rows
@onready var _build_panel: PanelContainer = $SafeArea/Layout/BottomRow/BuildPanel
@onready var _tabs: HBoxContainer = $SafeArea/Layout/BottomRow/BuildPanel/Layout/Tabs
@onready var _cards: HBoxContainer = $SafeArea/Layout/BottomRow/BuildPanel/Layout/Cards
@onready var _building_card: PanelContainer = $SafeArea/Layout/BottomRow/BuildingCard
@onready var _bld_what: Label = $SafeArea/Layout/BottomRow/BuildingCard/Rows/What
@onready var _bld_detail: Label = $SafeArea/Layout/BottomRow/BuildingCard/Rows/Detail
@onready var _upgrade_button: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/Actions/UpgradeButton
@onready var _demolish_button: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/Actions/DemolishButton
@onready var _placement_bar: PanelContainer = $SafeArea/Layout/BottomRow/PlacementBar
@onready var _placement_status: Label = $SafeArea/Layout/BottomRow/PlacementBar/Row/Status
@onready var _confirm_button: Button = $SafeArea/Layout/BottomRow/PlacementBar/Row/ConfirmButton
@onready var _cancel_button: Button = $SafeArea/Layout/BottomRow/PlacementBar/Row/CancelButton
@onready var _powers: HBoxContainer = $SafeArea/Layout/BottomRow/Buttons/Powers
@onready var _phase_label: Label = $SafeArea/Layout/PhaseBar/Row/Phase
@onready var _pause_button: Button = $SafeArea/Layout/PhaseBar/Row/PauseButton
@onready var _speed_button: Button = $SafeArea/Layout/PhaseBar/Row/SpeedButton
@onready var _migrant_prompt: PanelContainer = $SafeArea/Layout/MigrantPrompt
@onready var _migrant_ask: Label = $SafeArea/Layout/MigrantPrompt/Row/Ask
@onready var _accept_button: Button = $SafeArea/Layout/MigrantPrompt/Row/AcceptButton
@onready var _refuse_button: Button = $SafeArea/Layout/MigrantPrompt/Row/RefuseButton
@onready var _selection_card: PanelContainer = $SafeArea/Layout/BottomRow/SelectionCard
@onready var _sel_who: Label = $SafeArea/Layout/BottomRow/SelectionCard/Rows/Who
@onready var _sel_doing: Label = $SafeArea/Layout/BottomRow/SelectionCard/Rows/Doing
@onready var _sel_needs: Label = $SafeArea/Layout/BottomRow/SelectionCard/Rows/Needs

## job id -> {slider, count label}
var _row_widgets: Dictionary = {}
## building id -> card button
var _card_widgets: Dictionary = {}
## category -> tab button
var _tab_widgets: Dictionary = {}
## Signature of the job set the board was built for. See _sync_rows.
var _rows_key: String = ""
## Which build-menu tab is open. Empty until _build_tabs picks the first one.
var _tab: StringName = &""
## power id -> button
var _power_widgets: Dictionary = {}
var _god_hand: Node = null
var _refresh_accum: float = 0.0
var _placement: Node = null
## Frame the breakdown was last toggled on, to debounce duplicate press events.
var _tap_frame: int = -1
var _ascend_armed: bool = false
var _ascend_timer: float = 0.0
## Demolition is irreversible and refunds 40%, so it arms on the first press like Ascend does.
var _demolish_armed: bool = false
var _demolish_timer: float = 0.0


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

	# The resource bar is the tap target for the breakdown, so the affordance sits exactly on
	# the numbers the player is questioning rather than on a separate "info" control.
	#
	# A PanelContainer with gui_input, NOT a Button: Button is not a container and does not lay
	# its children out at all, so the readout Label spilled outside the panel and straight off
	# the right edge of the screen. Only ScreenTouch is handled — emulate_touch_from_mouse is
	# on, so a desktop click arrives as a touch too, and listening for both double-toggles.
	_resource_bar.gui_input.connect(_on_resource_bar_input)

	_accept_button.pressed.connect(Colony.accept_migrants)
	_refuse_button.pressed.connect(Colony.refuse_migrants)
	Events.migrants_arrived.connect(_on_migrants_arrived)
	Events.migrants_resolved.connect(_on_migrants_resolved)

	_pause_button.toggled.connect(_on_pause_toggled)
	_speed_button.pressed.connect(_on_speed_pressed)
	Events.speed_changed.connect(_on_speed_changed)

	_upgrade_button.pressed.connect(_on_upgrade)
	_demolish_button.pressed.connect(_on_demolish)
	# The build menu is gated on the Village Center tier and on headcount, so raising the Hearth or
	# taking in survivors can unlock cards mid-run. Rebuilding on those two events is what makes
	# that moment visible — an unlock nobody notices is not a reward.
	Events.building_completed.connect(_on_roster_changed)
	Events.building_destroyed.connect(_on_roster_changed)
	Events.villager_spawned.connect(_on_roster_changed)
	# Taking up or giving back an ability changes the bar. Rebuilt on the signal rather than polled,
	# because a power appearing is one of the better moments in the game and should be immediate.
	Events.powers_changed.connect(_build_powers)

	_sync_rows()
	_build_tabs()
	_build_cards()
	_build_powers()
	_refresh()


# --- Layout ------------------------------------------------------------------------

func _apply_safe_area() -> void:
	SafeArea.apply(_safe_area, 8)


# --- Job rows ------------------------------------------------------------------------

## Rebuild the Job Board, but only when the set of AVAILABLE jobs has actually changed.
##
## Guarded by a signature for the same reason the ability buttons are: this now runs whenever a
## building finishes or falls, and a slider destroyed and recreated under the player's thumb is a
## slider that drops their drag. Comparing a joined id list is far cheaper than the rebuild.
func _sync_rows() -> void:
	var ids := PackedStringArray()
	for job: JobDef in Jobs.available():
		ids.append(String(job.id))
	var key := ",".join(ids)
	if key == _rows_key:
		return
	_rows_key = key
	_build_rows()


func _build_rows() -> void:
	for id in _row_widgets:
		var w: Dictionary = _row_widgets[id]
		var root: Node = w["root"]
		# Detached before freeing: queue_free defers to end of frame, so a rebuilt board would
		# briefly hold both the old rows and the new ones and jump to double height.
		_rows.remove_child(root)
		root.queue_free()
	_row_widgets.clear()

	# available(), not all(): a job whose workplace does not exist yet is hidden rather than shown
	# as a dead slider. See Jobs.available for why that is more than cosmetic.
	for job: JobDef in Jobs.available():
		var row: HBoxContainer = JOB_ROW.instantiate()
		row.name = "Row_%s" % job.id
		_rows.add_child(row)

		var swatch: ColorRect = row.get_node("Swatch")
		var name_label: Label = row.get_node("JobName")
		var slider: HSlider = row.get_node("Slider")
		var count: Label = row.get_node("Count")

		swatch.color = job.color
		name_label.text = tr(job.display_name)
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

## One tab per category present in the content. Necessary well before the list reaches 25
## buildings — a flat strip of cards ran off the side of a phone at eleven.
func _build_tabs() -> void:
	# Detached before freeing. queue_free defers to the end of the frame, so a rebuilt strip would
	# briefly contain both the old buttons and the new ones — invisible for a one-off build at
	# startup, glaringly visible now that switching tabs rebuilds the card row every tap.
	for key in _tab_widgets:
		var old: Node = _tab_widgets[key]
		_tabs.remove_child(old)
		old.queue_free()
	_tab_widgets.clear()

	var categories := Buildings.categories()
	if categories.is_empty():
		return
	if not _tab in categories:
		_tab = categories[0]

	for category: StringName in categories:
		var tab := Button.new()
		tab.name = "Tab_%s" % category
		tab.text = tr(StringName("TAB_" + String(category).to_upper()))
		tab.toggle_mode = true
		tab.custom_minimum_size = Vector2(0, 20)
		tab.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		tab.pressed.connect(_on_tab_pressed.bind(category))
		_tabs.add_child(tab)
		_tab_widgets[category] = tab

	_refresh_tabs()


func _on_tab_pressed(category: StringName) -> void:
	if _tab == category:
		# Re-pressing the open tab must not untoggle it into a menu showing nothing. A tab strip
		# with no selection is a dead end the player has to guess their way out of.
		_refresh_tabs()
		return
	_tab = category
	_build_cards()
	_refresh_tabs()


func _refresh_tabs() -> void:
	for key in _tab_widgets:
		var tab: Button = _tab_widgets[key]
		tab.set_pressed_no_signal(key == _tab)
		tab.add_theme_color_override("font_color",
			UiPalette.ACCENT if key == _tab else UiPalette.TEXT_DIM)


func _build_cards() -> void:
	for id in _card_widgets:
		var old: Node = _card_widgets[id]
		_cards.remove_child(old)
		old.queue_free()
	_card_widgets.clear()

	# in_menu(), not placeable(): a card the colony has not earned yet is SHOWN and disabled.
	# Hiding it would mean the player cannot discover that a Smelter exists, let alone what it
	# needs — and the whole progression is meant to be something to work toward.
	for def: BuildingDef in Buildings.in_menu():
		if def.category != _tab:
			continue
		var card: Button = BUILD_CARD.instantiate()
		card.name = "Card_%s" % def.id
		card.tooltip_text = tr(def.description)
		_cards.add_child(card)

		var icon: TextureRect = card.get_node("Layout/Icon")
		var name_label: Label = card.get_node("Layout/BuildingName")
		var cost_label: Label = card.get_node("Layout/Cost")
		icon.texture = def.sprite
		name_label.text = tr(def.display_name)
		name_label.add_theme_color_override("font_color", def.color)
		cost_label.text = def.cost_text()

		card.pressed.connect(_on_card_pressed.bind(def))
		_card_widgets[def.id] = card
	_refresh_cards()


## Anything that can change what is buildable: a completed Village Center raises the tier, a
## destroyed one lowers it, an arriving survivor can clear a headcount gate.
func _on_roster_changed(_arg: Variant = null) -> void:
	_build_tabs()
	_build_cards()
	# A finished sawmill adds the Sawyer row; a destroyed one takes it away again.
	_sync_rows()


# --- The selected building --------------------------------------------------------------
#
# Where upgrading and demolishing live, because there is nowhere else they could: both are verbs
# aimed at one specific structure, and the build menu is for things that do not exist yet.

func _on_upgrade() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b == null or not is_instance_valid(b):
		return
	if Colony.upgrade_building(b):
		# The building is a construction site now, not something with actions on it. Dropping the
		# selection also closes the card, which is the honest thing to do — leaving an Upgrade
		# button live over a half-built Great Hall invites a second press that cannot work.
		_god_hand.clear_building_selection()
		_refresh_building_card()


## Two presses, like Ascend. Demolition is slow, refunds 40%, and cannot be undone — one mistap
## next to the Upgrade button must not cost someone their Watchtower at dusk.
func _on_demolish() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b == null or not is_instance_valid(b):
		return
	if not _demolish_armed:
		_demolish_armed = true
		_demolish_timer = 3.0
		_refresh_building_card()
		return
	_demolish_armed = false
	if Colony.demolish_building(b):
		_god_hand.clear_building_selection()
	_refresh_building_card()


func _refresh_building_card() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b == null or not is_instance_valid(b):
		_building_card.visible = false
		_demolish_armed = false
		return

	_building_card.visible = true
	var def: BuildingDef = b.def
	_bld_what.text = tr(def.display_name)
	_bld_what.add_theme_color_override("font_color", def.color)

	# What state it is in matters more than what it is: a site waiting on timber and a finished
	# workshop offer completely different decisions.
	if b.is_demolishing():
		_bld_detail.text = L10n.t(&"BLD_TEARING_DOWN",
			[int(b.demolish_done / b.demolish_work() * 100.0)])
	elif b.is_site():
		_bld_detail.text = tr(&"BLD_AWAITING_MATERIALS") if b.needs_materials() \
			else tr(&"BLD_UNDER_CONSTRUCTION")
	else:
		_bld_detail.text = L10n.t(&"BLD_INTACT", [int(b.health_fraction() * 100.0)])

	var check := Colony.upgrade_check(b)
	var next: BuildingDef = check["def"]
	_upgrade_button.visible = next != null
	if next != null:
		_upgrade_button.disabled = not check["ok"]
		_upgrade_button.text = L10n.t(&"UI_UPGRADE_TO", [tr(next.display_name)])
		# The REASON goes in the tooltip and, when it is the blocker, into the detail line — a
		# disabled button that will not say why is the thing this codebase already refuses to ship
		# in the power bar.
		_upgrade_button.tooltip_text = check["reason"]
		if not check["ok"] and not b.is_site():
			_bld_detail.text = check["reason"]

	# Nothing to tear down on a site that is already coming apart, and never on the Village Center —
	# see Colony.can_demolish.
	_demolish_button.visible = not b.is_demolishing() and Colony.can_demolish(b)
	_demolish_button.text = tr(&"UI_DEMOLISH_CONFIRM" if _demolish_armed else &"UI_DEMOLISH")


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
		_ascend_button.text = tr(&"UI_ASCEND_CONFIRM")
		_ascend_timer = 3.0
		return
	_ascend_armed = false
	_ascend_button.text = tr(&"UI_ASCEND")
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
	# Tapping the ghost is the primary confirm, so the bar has to teach it — the
	# gesture is invisible otherwise, and a player who never finds it is left tapping
	# a small button at the bottom of the screen for every wall segment.
	_placement_status.text = L10n.t(&"UI_PLACEMENT_TAP_TO_BUILD", [status]) if valid else status
	_placement_status.add_theme_color_override("font_color",
		UiPalette.OK if valid else UiPalette.DANGER)
	_confirm_button.disabled = not valid


# --- Powers ----------------------------------------------------------------------------

## The power bar carries only the abilities the colony has actually TAKEN UP.
##
## Not every power that exists: with the Temple in play a power must be bought with shards and then
## taken up in-run at a permanent Faith cost, so a bar listing all eight would be six permanently
## disabled buttons occupying the most valuable strip of a phone screen. Taking one up happens in
## the Faith breakdown, which is where the Burden arithmetic the decision depends on already lives.
func _build_powers() -> void:
	for id in _power_widgets:
		var old: Node = _power_widgets[id]
		_powers.remove_child(old)
		old.queue_free()
	_power_widgets.clear()

	for def: PowerDef in Powers.all():
		if not Divine.is_taken_up(def.id):
			continue
		var button := Button.new()
		button.name = "Power_%s" % def.id
		button.custom_minimum_size = Vector2(74, 22)
		button.toggle_mode = true
		button.tooltip_text = tr(def.description)
		button.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
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
		if not Divine.power_active(def):
			# Taken up, but its Temple has fallen. Said plainly rather than left greyed: the player
			# needs to know their Sanctum going down is why Dawnbreak stopped working.
			button.text = L10n.t(&"POWER_NO_TEMPLE", [tr(def.display_name)])
			button.disabled = true
		elif cd > 0.0:
			button.text = L10n.t(&"POWER_ON_COOLDOWN", [tr(def.display_name), int(ceilf(cd))])
			button.disabled = true
		else:
			button.text = L10n.t(&"POWER_COST", [tr(def.display_name), int(def.faith_cost)])
			button.disabled = Divine.faith < def.faith_cost


## Grey out anything the colony cannot currently pay for. Showing the card but
## disabled — rather than hiding it — is deliberate: players need to know a building
## exists and what it costs before they can work toward it.
##
## Two different kinds of "no", and they must not look the same. Cannot AFFORD is a temporary
## shortfall, so the card dims and its cost stands. Not UNLOCKED is a structural gate, so the cost
## line is replaced by what would open it — "needs Village Center 2" is actionable in a way that a
## greyed-out timber price is not.
func _refresh_cards() -> void:
	for id in _card_widgets:
		var def := Buildings.get_building(id)
		if def == null:
			continue
		var card: Button = _card_widgets[id]
		var cost_label: Label = card.get_node("Layout/Cost")
		var unlocked := Buildings.unlocked_in_run(def)
		var affordable := unlocked and Colony.can_afford(def.cost)
		card.disabled = not affordable
		card.modulate = Color.WHITE if affordable else Color(1, 1, 1, 0.5)
		if unlocked:
			cost_label.text = def.cost_text()
			cost_label.add_theme_color_override("font_color", UiPalette.TEXT_DIM)
		else:
			cost_label.text = _gate_text(def)
			cost_label.add_theme_color_override("font_color", UiPalette.WARN)


## What is standing between the colony and this building. Population is named first when it is the
## binding constraint, because it is the slower of the two to fix and therefore the one the player
## needs to start on.
func _gate_text(def: BuildingDef) -> String:
	if def.min_population > Colony.population():
		return L10n.t(&"GATE_NEEDS_POP", [def.min_population])
	return L10n.t(&"GATE_NEEDS_CENTER", [def.tier])


func _on_run_started(_seed: int) -> void:
	# A fresh colony has none of last run's workplaces, so which jobs are even shown changes.
	# Forced rather than guarded: the signature may be identical across two runs and the widgets
	# still have to be rebound to the new colony's quotas.
	_rows_key = ""
	_sync_rows()
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
			_ascend_button.text = tr(&"UI_ASCEND")

	if _demolish_armed:
		_demolish_timer -= delta
		if _demolish_timer <= 0.0:
			_demolish_armed = false

	_refresh_accum += delta
	if _refresh_accum < 0.25:
		return
	_refresh_accum = 0.0
	# Mood and Faith drift continuously rather than firing a signal, so the top bar
	# has to poll. Resource counts still refresh on their signal for immediacy.
	_refresh_resources()
	_refresh_powers()
	_refresh_phase()
	_refresh_selection()
	_refresh_building_card()
	if _job_panel.visible:
		_refresh_counts()
	if _build_panel.visible:
		_refresh_cards()


## The phase clock is the game's spine, and at dusk it becomes the most important
## thing on screen — the countdown is what turns "it is getting dark" into a
## scramble.
func _refresh_phase() -> void:
	var names: Array[StringName] = [&"PHASE_DAY", &"PHASE_DUSK", &"PHASE_NIGHT", &"PHASE_DAWN"]
	var extra := ""
	if Sim.phase == Sim.Phase.NIGHT and Threat.alive_count() > 0:
		extra = L10n.t(&"HUD_HOSTILES", [Threat.alive_count()])
	_phase_label.text = L10n.t(&"HUD_CLOCK", [
		Sim.day, tr(names[Sim.phase]), int(Sim.seconds_remaining()), extra])
	_phase_label.add_theme_color_override("font_color", UiPalette.phase_color(Sim.phase))


# --- Speed ----------------------------------------------------------------------------

## Both event types are accepted, then debounced by frame.
##
## `emulate_touch_from_mouse` is on, so a desktop click can arrive as a mouse button, as an
## emulated touch, or as both depending on how the viewport routes it. Listening for one risks a
## control that silently does nothing on one platform; listening for both risks toggling twice in
## a frame and appearing to do nothing at all. The frame guard makes either delivery correct.
func _on_resource_bar_input(event: InputEvent) -> void:
	# Narrowed with explicit casts rather than duck-typed. Reading `event.pressed` off an
	# InputEvent-typed value yields a Variant, and the parser refuses to infer a type from it.
	var pressed := false
	if event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		pressed = button.pressed and button.button_index == MOUSE_BUTTON_LEFT
	if not pressed:
		return
	var frame := Engine.get_process_frames()
	if frame == _tap_frame:
		return
	_tap_frame = frame
	_breakdown.toggle()
	# On the CONTROL that received the event, not on self — the Hud is a CanvasLayer and
	# accept_event() is a Control method. Consuming it stops the tap falling through to the
	# God Hand and sending the Ember to wherever the resource bar happens to be.
	_resource_bar.accept_event()


# --- Survivors at the gate --------------------------------------------------------------

## Names the cost of saying yes, so the choice is informed. Accepting people you cannot house is
## allowed — it is the whole decision — but the player should know they are doing it.
func _on_migrants_arrived(count: int) -> void:
	_migrant_prompt.visible = true
	var beds := Colony.beds_free()
	var warning := ""
	if beds < count:
		warning = L10n.t(
			&"MIGRANTS_BEDS_WARNING_ONE" if beds == 1 else &"MIGRANTS_BEDS_WARNING", [beds])
	elif Colony.food_days() < Colony.MIGRATION_MIN_FOOD_DAYS:
		warning = tr(&"MIGRANTS_FOOD_WARNING")
	_migrant_ask.text = L10n.t(
		&"MIGRANTS_ASK_ONE" if count == 1 else &"MIGRANTS_ASK", [count, warning])
	_migrant_ask.add_theme_color_override("font_color",
		UiPalette.WARN if warning != "" else UiPalette.TEXT)


func _on_migrants_resolved() -> void:
	_migrant_prompt.visible = false


func _on_pause_toggled(pressed: bool) -> void:
	Sim.set_paused(pressed)


func _on_speed_pressed() -> void:
	Sim.cycle_speed()


## Driven by the signal rather than by the button handlers, so the readout stays correct
## however the speed was changed — including from the debug keys.
func _on_speed_changed(_scale: float, paused: bool) -> void:
	_pause_button.set_pressed_no_signal(paused)
	_pause_button.text = tr(&"UI_RESUME" if paused else &"UI_PAUSE")
	_speed_button.text = L10n.t(&"UI_SPEED", [int(Sim.time_scale)])


# --- Selection ------------------------------------------------------------------------

## Mirror of the God Hand's selection. Polled rather than signalled because the numbers
## on it (hunger, rest, mood) drift continuously — a signal would have to fire every
## tick, which is just polling with extra steps.
##
## Reuses Villager.describe(), which had been written, commented, and never called by
## anything: selecting a villager used to toggle a ring and tell the player nothing.
func _refresh_selection() -> void:
	# Typed as Villager, not Node: every field read below (alive, job, food, water, rest, mood,
	# describe) lives on Villager and none of them on Node, so a Node-typed local would make the
	# whole block unchecked.
	var who: Villager = _god_hand.selected if _god_hand != null else null
	if who == null or not is_instance_valid(who) or not who.alive:
		_selection_card.visible = false
		return

	_selection_card.visible = true
	_sel_who.text = tr(&"SELECT_SURVIVOR") if who.job == &"" else tr(Jobs.get_job(who.job).display_name)
	_sel_doing.text = who.describe()
	_sel_needs.text = L10n.t(&"SELECT_NEEDS",
		[int(who.food), int(who.water), int(who.rest), int(who.mood)])
	# Colour the needs line by its worst value, so a starving villager is visible without
	# the player having to read four numbers.
	var worst: float = minf(minf(who.food, who.water), who.rest)
	var tint := UiPalette.TEXT_DIM
	if worst <= Villager.HUNGER_URGENT:
		tint = UiPalette.DANGER if worst <= 15.0 else UiPalette.WARN
	_sel_needs.add_theme_color_override("font_color", tint)


func _refresh() -> void:
	_refresh_resources()
	_refresh_counts()
	_refresh_cards()
	_refresh_powers()
	_refresh_phase()
	_refresh_selection()
	_refresh_building_card()


func _on_resources_changed(_kind: StringName, _amount: int) -> void:
	_refresh_resources()


## The readout, one line per resource GROUP plus a line for the colony's condition.
##
## Built from Colony.KIND_GROUPS rather than from a format string per line. The old version named
## wood, stone and food by hand in HUD_RESOURCES_TOP; the production chain took the list from three
## kinds to six and will take it further, and hand-writing a key per row is how a readout ends up
## silently missing the resource that was just added.
##
## Groups whose every stock is zero are HIDDEN. Day one shows one line — raw materials — and the
## strip grows as the economy does, which keeps a phone screen readable and quietly teaches the
## chain: a Processed row appearing the first time a sawmill produces a board is a better
## explanation of the sawmill than any tooltip.
##
## Everything that moves on its own carries its SIGN. A bare "food 128" tells the player nothing
## about whether they are about to starve; "food 128 -9/day" tells them everything, and tapping the
## bar opens the arithmetic behind it (see RateLedger).
func _refresh_resources() -> void:
	var lines := PackedStringArray()

	for group: Array in Colony.KIND_GROUPS:
		var label: StringName = group[0]
		var kinds: Array = group[1]
		var parts := PackedStringArray()
		var any := false
		for kind: StringName in kinds:
			var amount := Colony.amount_of(kind)
			if amount > 0:
				any = true
			var entry := L10n.t(&"HUD_RESOURCE_ENTRY", [L10n.resource(kind), amount])
			# Food is the only stock with a measurable flow, so it is the only one that earns a
			# rate. See Colony's note on why supply is measured and demand computed.
			if kind == &"food":
				entry += _per_day(Colony.food_net_per_second() * Sim.cycle_seconds())
			parts.append(entry)
		# The raw row always shows, even at zero: an empty larder is the most important number on
		# the screen, and hiding it would be the one case where absence is not information.
		if any or label == &"GROUP_RAW":
			lines.append(L10n.t(&"HUD_RESOURCE_GROUP",
				[tr(label), " ".join(parts)]))

	# Faith carries its ceiling: a reservoir that scales with population means "faith 91" says
	# nothing without knowing whether that is nearly full or barely started. And its rate, because
	# a number that silently depends on morale is indistinguishable from a broken one.
	lines.append(L10n.t(&"HUD_RESOURCES_BOTTOM", [
		Colony.population(), _growth_text(),
		int(_average_water()), _sign_of(_water_trend()),
		int(Colony.average_mood()), _mood_sign(),
		"%d/%d" % [int(Divine.faith), int(Divine.faith_max())],
		_sign_of(RateLedger.faith().total)]))

	_resources.text = "\n".join(lines)


## Mood's sign, with a deadband.
##
## Mood drifts toward a target that steps as villagers cross need thresholds, so near equilibrium
## the gap flips sign constantly and a naive indicator strobes. Three points of slack means the
## arrow only appears when morale is actually going somewhere.
func _mood_sign() -> String:
	var gap := RateLedger.mood().total - Colony.average_mood()
	return "" if absf(gap) < 3.0 else ("+" if gap > 0.0 else "-")


## "+14/day" or "-9/day". Blank when the flow is negligible, so a settled colony is not
## decorated with noise.
static func _per_day(amount: float) -> String:
	if absf(amount) < 1.0:
		return ""
	return L10n.t(&"HUD_PER_DAY", ["%+.0f" % amount])


## A bare sign for quantities where the magnitude is not meaningful to the player — mood and
## Faith are bounded and drift, so "rising" is the whole message.
static func _sign_of(delta: float) -> String:
	if absf(delta) < 0.01:
		return ""
	return "+" if delta > 0.0 else "-"


func _average_water() -> float:
	var total := 0.0
	var n := 0
	for v in Colony.villagers:
		if is_instance_valid(v) and v.alive:
			total += v.water
			n += 1
	return total / float(maxi(n, 1))


## Whether the colony is keeping up with its own thirst. Falling means the water is too far
## away, which is a well-shaped problem rather than a stockpile-shaped one.
func _water_trend() -> float:
	if not Colony.has_water_access():
		return -1.0
	return 1.0 if _average_water() >= Villager.THIRST_URGENT else -1.0


## Why the colony is or is not growing, in a few characters next to the population.
##
## Migration is the most important system in the game and it is invisible without this — a
## player who builds a hut has to be able to see the answer change, and one who is stalled
## has to be told which of the two gates they have failed rather than being left to guess.
## Whether the colony is growing, and if not, which requirement is failing.
##
## Deliberately NOT a countdown. Showing "+1 in 445s" turned growth into a timer the player
## watched instead of a colony they tended, and because the rate is derived from mood, beds and
## food — all of which move continuously — the number jittered badly enough to be useless. What
## the player actually needs is one bit of information: is this working, and if not, why not.
func _growth_text() -> String:
	var blocker := Colony.birth_blocker()
	return "" if blocker == "" else L10n.t(&"HUD_GROWTH_BLOCKED", [tr(blocker)])


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
		count.text = L10n.t(&"HUD_HEADCOUNT", [have, want])
		# Amber when the colony cannot meet the order — the player needs to see
		# "you asked for more people than you have" without opening a tutorial.
		count.add_theme_color_override("font_color",
			UiPalette.WARN if have < want else UiPalette.TEXT_DIM)
