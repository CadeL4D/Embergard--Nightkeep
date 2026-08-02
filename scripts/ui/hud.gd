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
const BOTTOM_MENU_IDS: Array[StringName] = [
	&"powers", &"jobs", &"build", &"hand", &"library", &"control", &"realm",
]
const BOTTOM_MENU_LABELS: Array[StringName] = [
	&"UI_POWER_UPS", &"UI_JOBS", &"UI_BUILD", &"UI_HAND", &"UI_LIBRARY",
	&"UI_CONTROL", &"UI_REALM",
]

@onready var _safe_area: MarginContainer = $SafeArea
@onready var _resources: Label = $SafeArea/Layout/TopRow/ResourceColumn/ResourceBar/Resources
@onready var _resource_bar: PanelContainer = $SafeArea/Layout/TopRow/ResourceColumn/ResourceBar
@onready var _breakdown: BreakdownPanel = $SafeArea/Layout/TopRow/ResourceColumn/Breakdown
@onready var _jobs_button: Button = $SafeArea/Layout/BottomRow/ButtonsClip/Buttons/JobsButton
@onready var _build_button: Button = $SafeArea/Layout/BottomRow/ButtonsClip/Buttons/BuildButton
@onready var _hand_button: Button = $SafeArea/Layout/BottomRow/ButtonsClip/Buttons/HandButton
@onready var _library_button: Button = \
	$SafeArea/Layout/BottomRow/ButtonsClip/Buttons/LibraryButton
@onready var _library_panel: PanelContainer = $SafeArea/Layout/BottomRow/LibraryPanel
@onready var _library_rows: VBoxContainer = \
	$SafeArea/Layout/BottomRow/LibraryPanel/Layout/Scroll/Rows
@onready var _library_capacity: Label = \
	$SafeArea/Layout/BottomRow/LibraryPanel/Layout/Header/Capacity
@onready var _library_auto: CheckButton = \
	$SafeArea/Layout/BottomRow/LibraryPanel/Layout/Header/Auto
@onready var _library_details: Label = $SafeArea/Layout/BottomRow/LibraryPanel/Layout/Details
@onready var _realm_button: Button = $SafeArea/Layout/BottomRow/ButtonsClip/Buttons/RealmButton
@onready var _control_button: Button = \
	$SafeArea/Layout/BottomRow/ButtonsClip/Buttons/ControlButton
@onready var _control_panel: PanelContainer = $SafeArea/Layout/BottomRow/ControlPanel
@onready var _control_status: Label = $SafeArea/Layout/BottomRow/ControlPanel/Layout/Status
@onready var _forbidden_button: Button = \
	$SafeArea/Layout/BottomRow/ControlPanel/Layout/Paint/Forbidden
@onready var _work_zone_button: Button = $SafeArea/Layout/BottomRow/ControlPanel/Layout/Paint/Work
@onready var _guard_zone_button: Button = $SafeArea/Layout/BottomRow/ControlPanel/Layout/Paint/Guard
@onready var _erase_zone_button: Button = $SafeArea/Layout/BottomRow/ControlPanel/Layout/Paint/Erase
@onready var _shelter_button: Button = \
	$SafeArea/Layout/BottomRow/ControlPanel/Layout/Orders/Shelter
@onready var _dusk_button: Button = $SafeArea/Layout/BottomRow/ControlPanel/Layout/Orders/Dusk
@onready var _cleanse_button: Button = \
	$SafeArea/Layout/BottomRow/ControlPanel/Layout/Orders/Cleanse
@onready var _job_panel: PanelContainer = $SafeArea/Layout/BottomRow/JobPanel
@onready var _rows: VBoxContainer = $SafeArea/Layout/BottomRow/JobPanel/Layout/Scroll/Rows
@onready var _gather_bar: PanelContainer = $SafeArea/Layout/BottomRow/GatherBar
@onready var _gather_done: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/DoneButton
@onready var _gather_status: Label = $SafeArea/Layout/BottomRow/GatherBar/Row/Status
@onready var _gather_radius_minus: Button = \
	$SafeArea/Layout/BottomRow/GatherBar/Row/RadiusMinus
@onready var _gather_radius_label: Label = $SafeArea/Layout/BottomRow/GatherBar/Row/Radius
@onready var _gather_radius_plus: Button = \
	$SafeArea/Layout/BottomRow/GatherBar/Row/RadiusPlus
@onready var _gather_paint: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/PaintButton
@onready var _gather_erase: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/EraseButton
@onready var _build_panel: PanelContainer = $SafeArea/Layout/BottomRow/BuildPanel
@onready var _tabs: HBoxContainer = $SafeArea/Layout/BottomRow/BuildPanel/Layout/Tabs
@onready var _cards: HBoxContainer = \
	$SafeArea/Layout/BottomRow/BuildPanel/Layout/CardsScroll/Cards
@onready var _building_card: PanelContainer = $SafeArea/Layout/BottomRow/BuildingCard
@onready var _bld_what: Label = $SafeArea/Layout/BottomRow/BuildingCard/Rows/What
@onready var _bld_detail: Label = $SafeArea/Layout/BottomRow/BuildingCard/Rows/Detail
@onready var _upgrade_choices: HBoxContainer = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/UpgradeChoices
@onready var _view_button: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/Actions/ViewButton
@onready var _demolish_button: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/Actions/DemolishButton
@onready var _storage_filter: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/Actions/StorageFilter
@onready var _storage_priority: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/Actions/StoragePriority
@onready var _combat_policies: HBoxContainer = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/CombatPolicies
@onready var _target_policy: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/CombatPolicies/TargetPolicy
@onready var _repair_priority: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/CombatPolicies/RepairPriority
@onready var _production_policies: HBoxContainer = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/ProductionPolicies
@onready var _production_pause: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/ProductionPolicies/ProductionPause
@onready var _worker_limit: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/ProductionPolicies/WorkerLimit
@onready var _production_priority: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/ProductionPolicies/ProductionPriority
@onready var _maintain_target: Button = \
	$SafeArea/Layout/BottomRow/BuildingCard/Rows/ProductionPolicies/MaintainTarget
@onready var _placement_bar: PanelContainer = $SafeArea/Layout/BottomRow/PlacementBar
@onready var _placement_status: Label = $SafeArea/Layout/BottomRow/PlacementBar/Row/Status
@onready var _confirm_button: Button = $SafeArea/Layout/BottomRow/PlacementBar/Row/ConfirmButton
@onready var _cancel_button: Button = $SafeArea/Layout/BottomRow/PlacementBar/Row/CancelButton
@onready var _powers: HBoxContainer = $SafeArea/Layout/BottomRow/ButtonsClip/Buttons/Powers
@onready var _bottom_buttons: HBoxContainer = $SafeArea/Layout/BottomRow/ButtonsClip/Buttons
@onready var _menu_cycle_button: Button = \
	$SafeArea/Layout/BottomRow/ButtonsClip/Buttons/MenuCycleButton
@onready var _active_menu_label: Label = \
	$SafeArea/Layout/BottomRow/ButtonsClip/Buttons/ActiveMenu
@onready var _menu_switcher: MenuSwitcher = $MenuSwitcher
@onready var _phase_label: Label = $SafeArea/Layout/TopRow/PhaseBar/Row/Phase
@onready var _pause_button: Button = $SafeArea/Layout/TopRow/PhaseBar/Row/PauseButton
@onready var _speed_button: Button = $SafeArea/Layout/TopRow/PhaseBar/Row/SpeedButton
@onready var _menu_button: Button = $SafeArea/Layout/TopRow/PhaseBar/Row/MenuButton
@onready var _migrant_prompt: PanelContainer = $SafeArea/Layout/MigrantPrompt
@onready var _migrant_ask: Label = $SafeArea/Layout/MigrantPrompt/Row/Ask
@onready var _accept_button: Button = $SafeArea/Layout/MigrantPrompt/Row/AcceptButton
@onready var _refuse_button: Button = $SafeArea/Layout/MigrantPrompt/Row/RefuseButton
@onready var _selection_card: PanelContainer = $SafeArea/Layout/BottomRow/SelectionCard
@onready var _sel_who: Label = $SafeArea/Layout/BottomRow/SelectionCard/Rows/Who
@onready var _sel_doing: Label = $SafeArea/Layout/BottomRow/SelectionCard/Rows/Doing
@onready var _sel_needs: Label = $SafeArea/Layout/BottomRow/SelectionCard/Rows/Needs
@onready var _equipment_policy: Button = \
	$SafeArea/Layout/BottomRow/SelectionCard/Rows/EquipmentPolicy

## job id -> {slider, count label}
var _row_widgets: Dictionary = {}
## building id -> card button
var _card_widgets: Dictionary = {}
## category -> tab button
var _tab_widgets: Dictionary = {}
## Signature of the job set the board was built for. See _sync_rows.
var _rows_key: String = ""
## Signature of the build-menu state. See _on_roster_changed.
var _menu_key: String = ""
## Which build-menu tab is open. Empty until _build_tabs picks the first one.
var _tab: StringName = &""
## power id -> button
var _power_widgets: Dictionary = {}
var _god_hand: Node = null
var _refresh_accum: float = 0.0
var _placement: Node = null
## Frame the breakdown was last toggled on, to debounce duplicate press events.
var _tap_frame: int = -1
## Demolition is irreversible and refunds 40%, so it arms on the first press like Ascend does.
var _demolish_armed: bool = false
var _demolish_timer: float = 0.0
var _management_pause_owned: bool = false
var _upgrade_widgets: Dictionary = {}
var _upgrade_key: String = ""
var _bottom_menu_index: int = 0
var _menu_touch_index: int = -1
var _menu_touch_elapsed: float = 0.0
var _menu_touch_position: Vector2 = Vector2.ZERO
var _menu_switcher_open: bool = false


func _ready() -> void:
	_apply_safe_area()
	get_tree().root.size_changed.connect(_apply_safe_area)
	Accessibility.changed.connect(_on_accessibility_changed)
	_apply_handedness()

	_jobs_button.toggled.connect(_on_jobs_toggled)
	_build_button.toggled.connect(_on_build_toggled)
	_hand_button.toggled.connect(_on_hand_toggled)
	_library_button.toggled.connect(_on_library_toggled)
	_library_auto.toggled.connect(Divine.set_library_auto_manage)
	_control_button.toggled.connect(_on_control_toggled)
	_realm_button.pressed.connect(_on_realm)
	_menu_cycle_button.gui_input.connect(_on_menu_cycle_input)
	_confirm_button.pressed.connect(_on_confirm)
	_cancel_button.pressed.connect(_on_cancel)
	Events.resources_changed.connect(_on_resources_changed)
	Events.run_started.connect(_on_run_started)
	Climate.changed.connect(_refresh_phase)

	# The placement controller lives in the run scene because it needs world space;
	# the HUD only drives it. Looked up rather than exported so the HUD can also be
	# dropped into a UI-only test scene without one.
	_placement = get_node_or_null("../PlacementController")
	if _placement != null:
		_placement.placement_changed.connect(_on_placement_changed)

	_god_hand = get_node_or_null("../GodHand")
	if _god_hand != null:
		_god_hand.armed_changed.connect(_on_armed_changed)
		_god_hand.hand_mode_changed.connect(func(active: bool) -> void:
			_hand_button.set_pressed_no_signal(active))

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
	_equipment_policy.pressed.connect(_on_equipment_policy)
	Events.migrants_arrived.connect(_on_migrants_arrived)
	Events.migrants_resolved.connect(_on_migrants_resolved)

	_pause_button.toggled.connect(_on_pause_toggled)
	_speed_button.pressed.connect(_on_speed_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	Events.speed_changed.connect(_on_speed_changed)

	_view_button.pressed.connect(_on_view_building)
	_demolish_button.pressed.connect(_on_demolish)
	_storage_filter.pressed.connect(_on_storage_filter)
	_storage_priority.pressed.connect(_on_storage_priority)
	_target_policy.pressed.connect(_on_target_policy)
	_repair_priority.pressed.connect(_on_repair_priority)
	_production_pause.pressed.connect(_on_production_pause)
	_worker_limit.pressed.connect(_on_worker_limit)
	_production_priority.pressed.connect(_on_production_priority)
	_maintain_target.pressed.connect(_on_maintain_target)
	_forbidden_button.pressed.connect(
		DefenseControl.set_paint_mode.bind(DefenseControl.PaintMode.FORBIDDEN))
	_work_zone_button.pressed.connect(
		DefenseControl.set_paint_mode.bind(DefenseControl.PaintMode.WORK))
	_guard_zone_button.pressed.connect(
		DefenseControl.set_paint_mode.bind(DefenseControl.PaintMode.GUARD))
	_erase_zone_button.pressed.connect(
		DefenseControl.set_paint_mode.bind(DefenseControl.PaintMode.ERASE))
	_shelter_button.pressed.connect(DefenseControl.toggle_shelter)
	_dusk_button.pressed.connect(DefenseControl.toggle_dusk_lock)
	_cleanse_button.pressed.connect(DefenseControl.start_cleanse)
	_gather_done.pressed.connect(DefenseControl.cancel_gather_paint)
	_gather_radius_minus.pressed.connect(DefenseControl.adjust_gather_radius.bind(-1))
	_gather_radius_plus.pressed.connect(DefenseControl.adjust_gather_radius.bind(1))
	_gather_paint.pressed.connect(DefenseControl.set_gather_erasing.bind(false))
	_gather_erase.pressed.connect(DefenseControl.set_gather_erasing.bind(true))
	DefenseControl.changed.connect(_refresh_control_panel)
	DefenseControl.paint_mode_changed.connect(func(_mode: int) -> void:
		_refresh_control_panel())
	DefenseControl.gather_mode_changed.connect(_on_gather_mode_changed)
	# The build menu is gated on the Village Center tier and on headcount, so raising the Hearth or
	# taking in survivors can unlock cards mid-run. Rebuilding on those two events is what makes
	# that moment visible — an unlock nobody notices is not a reward.
	Events.building_completed.connect(_on_roster_changed)
	Events.building_destroyed.connect(_on_roster_changed)
	Events.villager_spawned.connect(_on_roster_changed)
	# Taking up or giving back an ability changes the bar. Rebuilt on the signal rather than polled,
	# because a power appearing is one of the better moments in the game and should be immediate.
	Events.powers_changed.connect(_build_powers)
	Events.library_changed.connect(_rebuild_library)

	_sync_rows()
	_build_tabs()
	_build_cards()
	_build_powers()
	_rebuild_library()
	_refresh()
	_activate_bottom_menu(0)


# --- Layout ------------------------------------------------------------------------

func _apply_safe_area() -> void:
	SafeArea.apply(_safe_area, 8)


func _on_accessibility_changed(kind: StringName) -> void:
	if kind == &"handedness":
		_apply_handedness()
	if kind == &"management_pause":
		_sync_management_pause()


func _apply_handedness() -> void:
	if _bottom_buttons == null:
		return
	# The launcher is intentionally fixed in the bottom-left corner. Handedness still
	# applies to world gestures, but moving the one persistent navigation anchor
	# would make the tap/hold interaction impossible to learn by muscle memory.
	var order: Array[Control] = [
		_menu_cycle_button, _active_menu_label, _powers, _jobs_button, _build_button,
		_hand_button, _library_button, _control_button, _realm_button,
	]
	for index in order.size():
		_bottom_buttons.move_child(order[index], index)


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
		var area_button: Button = row.get_node("AreaButton")
		var minus_button: Button = row.get_node("MinusButton")
		var slider: HSlider = row.get_node("Slider")
		var plus_button: Button = row.get_node("PlusButton")
		var count: Label = row.get_node("Count")

		swatch.color = job.color
		name_label.text = tr(job.display_name)
		name_label.add_theme_color_override("font_color", job.color)
		area_button.visible = not job.target_features.is_empty()
		area_button.tooltip_text = L10n.t(&"GATHER_AREA_TOOLTIP", [tr(job.display_name)])
		if area_button.visible:
			area_button.pressed.connect(_on_gather_area.bind(job.id))
		slider.value = Colony.quota_of(job.id)
		slider.value_changed.connect(_on_slider_changed.bind(job.id))
		minus_button.pressed.connect(_nudge_job.bind(job.id, -1))
		plus_button.pressed.connect(_nudge_job.bind(job.id, 1))

		_row_widgets[job.id] = {
			"root": row,
			"slider": slider,
			"count": count,
			"area": area_button,
			"minus": minus_button,
			"plus": plus_button,
		}


func _on_slider_changed(value: float, job_id: StringName) -> void:
	Colony.set_quota(job_id, int(value))
	_refresh()


func _nudge_job(job_id: StringName, delta: int) -> void:
	var widgets: Dictionary = _row_widgets.get(job_id, {})
	if widgets.is_empty():
		return
	var slider: HSlider = widgets["slider"]
	var next_value := clampi(Colony.quota_of(job_id) + delta, 0, int(slider.max_value))
	slider.value = next_value


func _on_jobs_toggled(pressed: bool) -> void:
	_job_panel.visible = pressed
	if pressed:
		if _god_hand != null:
			_god_hand.set_hand_mode(false)
		DefenseControl.cancel_gather_paint()
		_breakdown.visible = false
		_build_button.button_pressed = false
		_control_button.button_pressed = false
		_library_button.button_pressed = false
	_refresh_selection()
	_refresh_building_card()
	_sync_management_pause()


func _on_gather_area(job_id: StringName) -> void:
	DefenseControl.set_gather_mode(job_id)


func _on_gather_mode_changed(job_id: StringName, erasing: bool, radius: int) -> void:
	if not is_node_ready():
		return
	var active := job_id != &""
	_gather_bar.visible = active
	if not active:
		return
	_job_panel.visible = false
	_jobs_button.set_pressed_no_signal(false)
	_build_button.set_pressed_no_signal(false)
	_control_button.set_pressed_no_signal(false)
	_library_button.set_pressed_no_signal(false)
	_build_panel.visible = false
	_control_panel.visible = false
	_library_panel.visible = false
	_breakdown.visible = false
	if _placement != null and _placement.active:
		_placement.cancel()
	var job := Jobs.get_job(job_id)
	_gather_status.text = L10n.t(&"GATHER_BRUSH_STATUS", [
		tr(job.display_name) if job != null else String(job_id),
		DefenseControl.gathering_count(job_id),
	])
	_gather_radius_label.text = L10n.t(&"GATHER_RADIUS", [radius])
	_gather_radius_minus.disabled = radius <= DefenseControl.GATHER_RADIUS_MIN
	_gather_radius_plus.disabled = radius >= DefenseControl.GATHER_RADIUS_MAX
	_gather_paint.set_pressed_no_signal(not erasing)
	_gather_erase.set_pressed_no_signal(erasing)


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
	# Guarded by a signature, like the job rows and the ability buttons.
	#
	# This fires on every building AND every villager, and it used to rebuild the whole tab strip and
	# card row unconditionally — so the stress test's 60 spawns triggered 60 full menu rebuilds,
	# instantiating several hundred card scenes and immediately freeing them. Population only matters
	# here through `min_population` gates, which change at a handful of thresholds, not per villager.
	var key := "%d:%d:%d" % [Colony.center_tier(), Colony.population(), Buildings.in_menu().size()]
	if key != _menu_key:
		_menu_key = key
		_build_tabs()
		_build_cards()
	# A finished sawmill adds the Sawyer row; a destroyed one takes it away again. Guarded separately
	# because the job set and the build menu change on different events.
	_sync_rows()


# --- The selected building --------------------------------------------------------------
#
# Where upgrading and demolishing live, because there is nowhere else they could: both are verbs
# aimed at one specific structure, and the build menu is for things that do not exist yet.

func _on_upgrade_to(next_id: StringName) -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b == null or not is_instance_valid(b):
		return
	if Colony.upgrade_building(b, next_id):
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
	if b.def.menu_hidden:
		b.destroy()
		_god_hand.clear_building_selection()
		_refresh_building_card()
		return
	if Colony.demolish_building(b):
		_god_hand.clear_building_selection()
	_refresh_building_card()


func _on_view_building() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b == null or not is_instance_valid(b):
		return
	var camera := get_node_or_null("../CameraRig")
	if camera != null and camera.has_method("focus_on_rect"):
		camera.focus_on_rect(b.world_rect())


func _refresh_building_card() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b == null or not is_instance_valid(b) or _action_panel_open():
		_building_card.visible = false
		_demolish_armed = false
		return

	_building_card.visible = true
	var def: BuildingDef = b.def
	_bld_what.text = tr(def.display_name)
	_bld_what.add_theme_color_override("font_color", def.color)
	var is_storage := not b.is_site() and def.is_stockpile
	_storage_filter.visible = is_storage
	_storage_priority.visible = is_storage
	if is_storage:
		var store_cell := b.centre_cell()
		_storage_filter.text = DefenseControl.stockpile_filter_name(store_cell)
		_storage_priority.text = L10n.t(&"STORAGE_PRIORITY",
			[DefenseControl.stockpile_priority(store_cell)])
	var can_control := not b.is_site() and not b.is_demolishing()
	_combat_policies.visible = can_control and (def.attack_damage > 0.0 or b.needs_repair())
	_target_policy.visible = def.attack_damage > 0.0
	_repair_priority.visible = can_control
	_target_policy.text = L10n.t(&"TARGET_POLICY", [tr(StringName(
		"TARGET_" + String(b.target_policy).to_upper()))])
	_repair_priority.text = L10n.t(&"REPAIR_PRIORITY", [b.repair_priority])
	_production_policies.visible = can_control and def.worker_slots > 0
	if _production_policies.visible:
		_production_pause.text = tr(&"PRODUCTION_RESUME" if b.production_paused \
			else &"PRODUCTION_PAUSE")
		var worker_cap := b.effective_worker_slots()
		_worker_limit.text = L10n.t(&"WORKER_LIMIT", [worker_cap, def.worker_slots])
		_production_priority.text = L10n.t(&"PRODUCTION_PRIORITY", [b.production_priority])
		_maintain_target.text = tr(&"PRODUCTION_MAINTAIN_OFF") if b.production_target < 0 \
			else L10n.t(&"PRODUCTION_MAINTAIN", [b.production_target])

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
		if def.inventory_capacity > 0:
			_bld_detail.text += L10n.t(&"BLD_STORAGE", [b.inventory_used(), def.inventory_capacity])
		if def.input_capacity > 0:
			_bld_detail.text += L10n.t(&"BLD_INPUTS",
				[b._buffer_used(b.input_buffer), def.input_capacity])
		if def.output_capacity > 0:
			_bld_detail.text += L10n.t(&"BLD_OUTPUTS",
				[b._buffer_used(b.output_buffer), def.output_capacity])
		if not def.ammo_kind.is_empty():
			_bld_detail.text += L10n.t(&"BLD_AMMO", [Colony.amount_of(def.ammo_kind),
				L10n.resource(def.ammo_kind)])
		if def.faith_upkeep > 0.0:
			_bld_detail.text += L10n.t(&"BLD_FAITH_UPKEEP", [def.faith_upkeep])
		if def.sleep_slots > 0:
			_bld_detail.text += L10n.t(&"BLD_HOUSING", [def.sleep_slots,
				int(round(def.sleep_recovery_multiplier * 100.0))])

	_refresh_upgrade_choices(b)

	# Nothing to tear down on a site that is already coming apart, and never on the Village Center —
	# see Colony.can_demolish.
	_demolish_button.visible = not b.is_demolishing() and Colony.can_demolish(b)
	if def.menu_hidden:
		_demolish_button.text = tr(&"UI_DISMISS_CONFIRM" if _demolish_armed else &"UI_DISMISS")
	else:
		_demolish_button.text = tr(&"UI_DEMOLISH_CONFIRM" if _demolish_armed else &"UI_DEMOLISH")


func _refresh_upgrade_choices(b: Building) -> void:
	var checks := Colony.upgrade_checks(b)
	var ids := PackedStringArray()
	for check: Dictionary in checks:
		var option: BuildingDef = check["def"]
		if option != null:
			ids.append(String(option.id))
	var key := ",".join(ids)
	if key != _upgrade_key:
		_upgrade_key = key
		for child in _upgrade_choices.get_children():
			_upgrade_choices.remove_child(child)
			child.queue_free()
		_upgrade_widgets.clear()
		for check: Dictionary in checks:
			var option: BuildingDef = check["def"]
			if option == null:
				continue
			var button := Button.new()
			button.custom_minimum_size = Vector2(112, 24)
			button.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
			button.pressed.connect(_on_upgrade_to.bind(option.id))
			_upgrade_choices.add_child(button)
			_upgrade_widgets[option.id] = button

	_upgrade_choices.visible = not checks.is_empty()
	for check: Dictionary in checks:
		var option: BuildingDef = check["def"]
		if option == null or not _upgrade_widgets.has(option.id):
			continue
		var button: Button = _upgrade_widgets[option.id]
		button.disabled = not bool(check["ok"])
		button.text = L10n.t(&"UI_UPGRADE_TO", [tr(option.display_name)])
		button.tooltip_text = "%s\n%s" % [tr(option.description), String(check["reason"])]


func _on_storage_filter() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b != null and is_instance_valid(b) and not b.is_site() and b.def.is_stockpile:
		DefenseControl.cycle_stockpile_filter(b.centre_cell())
		_refresh_building_card()


func _on_storage_priority() -> void:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	if b != null and is_instance_valid(b) and not b.is_site() and b.def.is_stockpile:
		DefenseControl.cycle_stockpile_priority(b.centre_cell())
		_refresh_building_card()


func _selected_building() -> Building:
	var b: Building = _god_hand.selected_building if _god_hand != null else null
	return b if b != null and is_instance_valid(b) and not b.is_site() else null


func _on_target_policy() -> void:
	var b := _selected_building()
	if b != null:
		b.cycle_target_policy()
		_refresh_building_card()


func _on_repair_priority() -> void:
	var b := _selected_building()
	if b != null:
		b.cycle_repair_priority()
		_refresh_building_card()


func _on_production_pause() -> void:
	var b := _selected_building()
	if b != null:
		b.production_paused = not b.production_paused
		_refresh_building_card()


func _on_worker_limit() -> void:
	var b := _selected_building()
	if b != null and b.def.worker_slots > 0:
		var current := b.effective_worker_slots()
		b.production_worker_limit = (current + 1) % (b.def.worker_slots + 1)
		_refresh_building_card()


func _on_production_priority() -> void:
	var b := _selected_building()
	if b != null:
		b.production_priority = b.production_priority % 3 + 1
		_refresh_building_card()


func _on_maintain_target() -> void:
	var b := _selected_building()
	if b == null:
		return
	var targets: Array[int] = [-1, 10, 25, 50, 100, 200]
	var at := targets.find(b.production_target)
	b.production_target = targets[(maxi(at, 0) + 1) % targets.size()]
	_refresh_building_card()


func _on_build_toggled(pressed: bool) -> void:
	_build_panel.visible = pressed
	if pressed:
		if _god_hand != null:
			_god_hand.set_hand_mode(false)
		DefenseControl.cancel_gather_paint()
		_breakdown.visible = false
		_jobs_button.button_pressed = false
		_control_button.button_pressed = false
		_library_button.button_pressed = false
	elif _placement != null and _placement.active:
		_placement.cancel()
	_refresh_cards()
	_refresh_selection()
	_refresh_building_card()
	_sync_management_pause()


func _on_hand_toggled(pressed: bool) -> void:
	if _god_hand == null:
		return
	_god_hand.set_hand_mode(pressed)
	if pressed:
		_jobs_button.button_pressed = false
		_build_button.button_pressed = false
		_control_button.button_pressed = false
		_library_button.button_pressed = false
		_job_panel.visible = false
		_build_panel.visible = false
		_control_panel.visible = false
		_library_panel.visible = false
		_breakdown.visible = false
	_sync_management_pause()


func _on_control_toggled(pressed: bool) -> void:
	_control_panel.visible = pressed
	if pressed:
		if _god_hand != null:
			_god_hand.set_hand_mode(false)
		DefenseControl.cancel_gather_paint()
		_breakdown.visible = false
		_jobs_button.button_pressed = false
		_build_button.button_pressed = false
		_library_button.button_pressed = false
		if _placement != null and _placement.active:
			_placement.cancel()
	else:
		DefenseControl.cancel_paint()
	_refresh_control_panel()
	_refresh_selection()
	_refresh_building_card()
	_sync_management_pause()


# --- Tome library -----------------------------------------------------------------------

func _on_library_toggled(pressed: bool) -> void:
	_library_panel.visible = pressed
	if pressed:
		if _god_hand != null:
			_god_hand.set_hand_mode(false)
		DefenseControl.cancel_gather_paint()
		DefenseControl.cancel_paint()
		_breakdown.visible = false
		_jobs_button.button_pressed = false
		_build_button.button_pressed = false
		_control_button.button_pressed = false
		_job_panel.visible = false
		_build_panel.visible = false
		_control_panel.visible = false
		if _placement != null and _placement.active:
			_placement.cancel()
		_rebuild_library()
	_refresh_selection()
	_refresh_building_card()
	_sync_management_pause()


func _rebuild_library() -> void:
	if not is_node_ready():
		return
	for child in _library_rows.get_children():
		_library_rows.remove_child(child)
		child.queue_free()
	_library_capacity.text = L10n.t(&"LIBRARY_CAPACITY", [Divine.installed_count(),
		Divine.tome_capacity()])
	_library_auto.set_pressed_no_signal(Divine.auto_manage_library)
	if Divine.tomes.is_empty():
		var empty := Label.new()
		empty.text = tr(&"LIBRARY_EMPTY")
		empty.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		_library_rows.add_child(empty)
		return
	for index in Divine.tomes.size():
		var tome = Divine.tomes[index]
		var row := HBoxContainer.new()
		row.name = "Tome_%d" % index
		row.add_theme_constant_override("separation", 4)
		var label := Label.new()
		label.custom_minimum_size = Vector2(180, 22)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		label.text = L10n.t(&"LIBRARY_ROW", [tome.label(), int(tome.durability),
			"%.2f" % tome.rate()])
		var inspect := _library_action_button(&"LIBRARY_INSPECT", 48)
		inspect.pressed.connect(_inspect_tome.bind(index))
		var install := _library_action_button(
			&"LIBRARY_REMOVE" if tome.installed else &"LIBRARY_INSTALL", 58)
		install.disabled = not tome.installed and Divine.installed_count() >= Divine.tome_capacity()
		install.pressed.connect(_toggle_tome_install.bind(index))
		var lock := _library_action_button(
			&"LIBRARY_UNLOCK" if tome.locked else &"LIBRARY_LOCK", 52)
		lock.pressed.connect(_toggle_tome_lock.bind(index))
		var combine := _library_action_button(&"LIBRARY_COMBINE", 58)
		combine.disabled = tome.installed or tome.locked or tome.tier >= 3 \
			or _combine_candidates(tome.tier) < 3
		combine.pressed.connect(_combine_tome.bind(index))
		for control in [label, inspect, install, lock, combine]:
			row.add_child(control)
		_library_rows.add_child(row)


func _library_action_button(key: StringName, width: float) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(width, 22)
	button.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
	button.text = tr(key)
	return button


func _combine_candidates(tier: int) -> int:
	var total := 0
	for tome in Divine.tomes:
		if not tome.installed and not tome.locked and tome.tier == tier and tome.durability > 0.0:
			total += 1
	return total


func _inspect_tome(index: int) -> void:
	_library_details.text = Divine.tome_details(index)


func _toggle_tome_install(index: int) -> void:
	if not Divine.install_tome(index):
		Events.notice.emit(tr(&"LIBRARY_NO_SLOT"), 1)


func _toggle_tome_lock(index: int) -> void:
	Divine.toggle_tome_lock(index)


func _combine_tome(index: int) -> void:
	if not Divine.combine_tome(index):
		Events.notice.emit(tr(&"LIBRARY_COMBINE_NEEDS"), 1)


func _refresh_control_panel() -> void:
	if not is_node_ready():
		return
	_forbidden_button.set_pressed_no_signal(
		DefenseControl.paint_mode == DefenseControl.PaintMode.FORBIDDEN)
	_work_zone_button.set_pressed_no_signal(
		DefenseControl.paint_mode == DefenseControl.PaintMode.WORK)
	_guard_zone_button.set_pressed_no_signal(
		DefenseControl.paint_mode == DefenseControl.PaintMode.GUARD)
	_erase_zone_button.set_pressed_no_signal(
		DefenseControl.paint_mode == DefenseControl.PaintMode.ERASE)
	_shelter_button.set_pressed_no_signal(DefenseControl.shelter_active)
	_dusk_button.set_pressed_no_signal(DefenseControl.dusk_lock)
	_shelter_button.text = tr(&"CONTROL_SHELTER_ON" if DefenseControl.shelter_active \
		else &"CONTROL_SHELTER")
	_dusk_button.text = tr(&"CONTROL_DUSK_ON" if DefenseControl.dusk_lock else &"CONTROL_DUSK")
	var cleanse := DefenseControl.can_start_cleanse()
	_cleanse_button.disabled = not bool(cleanse["ok"])
	_cleanse_button.tooltip_text = String(cleanse["reason"])
	_cleanse_button.text = L10n.t(&"CONTROL_CLEANSE_PROGRESS",
		[DefenseControl.cleanse_dawns_left]) if DefenseControl.cleanse_dawns_left > 0 \
		else tr(&"CONTROL_CLEANSE")
	_control_status.text = tr(&"CONTROL_PAINT_HINT") \
		if DefenseControl.paint_mode != DefenseControl.PaintMode.NONE else tr(&"CONTROL_HINT")


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


func _on_realm() -> void:
	DefenseControl.cancel_gather_paint()
	var realm_map := get_node_or_null("../RealmMap")
	if realm_map != null and realm_map.has_method("open"):
		realm_map.open()


## Placement mode replaces the build menu rather than sitting alongside it. Two
## competing panels in the thumb zone is how you get mis-taps on a phone.
func _on_placement_changed(active: bool, status: String, valid: bool) -> void:
	_placement_bar.visible = active
	_build_panel.visible = _build_button.button_pressed and not active
	if not active:
		_refresh_selection()
		_refresh_building_card()
		return
	DefenseControl.cancel_gather_paint()
	_breakdown.visible = false
	_jobs_button.button_pressed = false
	_control_button.button_pressed = false
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
	_control_button.button_pressed = false
	DefenseControl.cancel_gather_paint()
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

	if _menu_touch_index != -1 and not _menu_switcher_open:
		_menu_touch_elapsed += delta
		if _menu_touch_elapsed >= Accessibility.hold_duration:
			_menu_switcher_open = true
			var labels := PackedStringArray()
			for key: StringName in BOTTOM_MENU_LABELS:
				labels.append(tr(key))
			_menu_switcher.open(labels, _menu_cycle_button.get_global_rect().get_center())
			_menu_switcher.update_pointer(_menu_touch_position)

	if _demolish_armed:
		_demolish_timer -= delta
		if _demolish_timer <= 0.0:
			_demolish_armed = false

	_refresh_accum += delta
	if _refresh_accum < 0.25:
		return
	_refresh_accum = 0.0
	_sync_management_pause()
	# Mood and Faith drift continuously rather than firing a signal, so the top bar
	# has to poll. Resource counts still refresh on their signal for immediacy.
	_refresh_resources()
	_refresh_powers()
	_refresh_phase()
	_refresh_selection()
	_refresh_building_card()
	if _god_hand != null:
		_hand_button.text = _god_hand.hand_status()
	if _job_panel.visible:
		_refresh_counts()
	if _gather_bar.visible:
		_on_gather_mode_changed(
			DefenseControl.gather_job,
			DefenseControl.gather_erasing,
			DefenseControl.gather_radius)
	if _build_panel.visible:
		_refresh_cards()
	if _control_panel.visible:
		_refresh_control_panel()
	if _library_panel.visible:
		_library_capacity.text = L10n.t(&"LIBRARY_CAPACITY", [Divine.installed_count(),
			Divine.tome_capacity()])


func _on_menu_cycle_input(event: InputEvent) -> void:
	if not event is InputEventScreenTouch:
		return
	var touch := event as InputEventScreenTouch
	if not touch.pressed or _menu_touch_index != -1:
		return
	_menu_touch_index = touch.index
	_menu_touch_elapsed = 0.0
	_menu_touch_position = touch.position
	_menu_switcher_open = false
	_menu_cycle_button.accept_event()


func _input(event: InputEvent) -> void:
	if _menu_touch_index == -1:
		return
	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index != _menu_touch_index:
			return
		_menu_touch_position = drag.position
		if _menu_switcher_open:
			_menu_switcher.update_pointer(drag.position)
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.index != _menu_touch_index or touch.pressed:
			return
		_menu_touch_position = touch.position
		if _menu_switcher_open:
			_menu_switcher.update_pointer(touch.position)
			var picked := _menu_switcher.finish()
			if picked >= 0:
				_activate_bottom_menu(picked)
		else:
			_activate_bottom_menu((_bottom_menu_index + 1) % BOTTOM_MENU_IDS.size())
		_menu_touch_index = -1
		_menu_touch_elapsed = 0.0
		_menu_switcher_open = false


func _activate_bottom_menu(index: int) -> void:
	if BOTTOM_MENU_IDS.is_empty():
		return
	_bottom_menu_index = posmod(index, BOTTOM_MENU_IDS.size())
	# Close every mutually exclusive surface through its normal handler, so paint,
	# placement, management-pause ownership and Hand mode all clean up correctly.
	_jobs_button.set_pressed_no_signal(false)
	_build_button.set_pressed_no_signal(false)
	_hand_button.set_pressed_no_signal(false)
	_library_button.set_pressed_no_signal(false)
	_control_button.set_pressed_no_signal(false)
	_on_jobs_toggled(false)
	_on_build_toggled(false)
	_on_hand_toggled(false)
	_on_library_toggled(false)
	_on_control_toggled(false)
	_powers.visible = false

	match BOTTOM_MENU_IDS[_bottom_menu_index]:
		&"powers":
			_powers.visible = true
		&"jobs":
			_jobs_button.set_pressed_no_signal(true)
			_on_jobs_toggled(true)
		&"build":
			_build_button.set_pressed_no_signal(true)
			_on_build_toggled(true)
		&"hand":
			_hand_button.set_pressed_no_signal(true)
			_on_hand_toggled(true)
		&"library":
			_library_button.set_pressed_no_signal(true)
			_on_library_toggled(true)
		&"control":
			_control_button.set_pressed_no_signal(true)
			_on_control_toggled(true)
		&"realm":
			_on_realm()
	_active_menu_label.text = tr(BOTTOM_MENU_LABELS[_bottom_menu_index])
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
	_phase_label.text += "\n" + Climate.hud_text()
	var forecast := Threat.next_night_forecast()
	var risk_keys: Array[StringName] = [&"FORECAST_READY", &"FORECAST_CLOSE", &"FORECAST_DANGER"]
	var monster_names: PackedStringArray = forecast["names"]
	var shown := PackedStringArray()
	for i in mini(monster_names.size(), 3):
		shown.append(monster_names[i])
	_phase_label.text += "\n" + L10n.t(&"FORECAST_LINE", [
		int(forecast["night"]), int(forecast["bodies"]),
		", ".join(shown), tr(risk_keys[int(forecast["risk"])])])
	_phase_label.tooltip_text = L10n.t(&"CLIMATE_TOOLTIP", [
		Climate.name_of_season(), Climate.name_of_weather(),
		int(round(Climate.farm_multiplier() * 100.0)),
		int(round(Climate.gather_multiplier(Terrain.Feature.TREE) * 100.0)),
	]) + "\n" + L10n.t(&"FORECAST_TOOLTIP", [
		int(forecast["budget"]), int(forecast["readiness"]), ", ".join(monster_names)])
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
	var opening := not _breakdown.visible
	if opening:
		DefenseControl.cancel_gather_paint()
		_jobs_button.button_pressed = false
		_build_button.button_pressed = false
		_control_button.button_pressed = false
		_library_button.button_pressed = false
		if _placement != null and _placement.active:
			_placement.cancel()
	_breakdown.toggle()
	_refresh_selection()
	_refresh_building_card()
	if _god_hand != null:
		_hand_button.text = _god_hand.hand_status()
	# On the CONTROL that received the event, not on self — the Hud is a CanvasLayer and
	# accept_event() is a Control method. Consuming it stops the tap falling through to the
	# God Hand and sending the Ember to wherever the resource bar happens to be.
	_resource_bar.accept_event()


# --- Survivors at the gate --------------------------------------------------------------

## Names the cost of saying yes, so the choice is informed. Accepting people you cannot house is
## allowed — it is the whole decision — but the player should know they are doing it.
func _on_migrants_arrived(count: int) -> void:
	# The survivor decision is timed and takes priority over optional drawers.
	# Closing them keeps the prompt inside the safe area even when the resource
	# ledger or job board had been open on a short phone display.
	_breakdown.visible = false
	DefenseControl.cancel_gather_paint()
	_jobs_button.button_pressed = false
	_build_button.button_pressed = false
	_control_button.button_pressed = false
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


func _on_menu_pressed() -> void:
	var menu := get_node_or_null("../PauseMenu")
	if menu != null and menu.has_method("open"):
		menu.open()


## Driven by the signal rather than by the button handlers, so the readout stays correct
## however the speed was changed — including from the debug keys.
func _on_speed_changed(_scale: float, paused: bool) -> void:
	_pause_button.set_pressed_no_signal(paused)
	_pause_button.text = tr(&"UI_RESUME" if paused else &"UI_PAUSE")
	_speed_button.text = L10n.t(&"UI_SPEED", [int(Sim.time_scale)])


# --- Desktop hotkeys ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var onboarding := get_node_or_null("../Onboarding/Dim") as Control
	if onboarding != null and onboarding.visible:
		return
	if event.is_action_pressed(&"game_pause"):
		_on_menu_pressed()
	elif event.is_action_pressed(&"game_speed"):
		Sim.cycle_speed()
	elif event.is_action_pressed(&"game_jobs"):
		_activate_bottom_menu(BOTTOM_MENU_IDS.find(&"jobs"))
	elif event.is_action_pressed(&"game_build"):
		_activate_bottom_menu(BOTTOM_MENU_IDS.find(&"build"))
	elif event.is_action_pressed(&"game_realm"):
		_activate_bottom_menu(BOTTOM_MENU_IDS.find(&"realm"))
	elif event.is_action_pressed(&"game_cancel"):
		if _placement != null and _placement.active:
			_placement.cancel()
		elif DefenseControl.gather_job != &"":
			DefenseControl.cancel_gather_paint()
		else:
			_breakdown.visible = false
			_activate_bottom_menu(BOTTOM_MENU_IDS.find(&"powers"))
	else:
		return
	get_viewport().set_input_as_handled()


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
	if who == null or not is_instance_valid(who) or not who.alive or _action_panel_open():
		_selection_card.visible = false
		return

	_selection_card.visible = true
	var role := tr(&"SELECT_CHILD") if not who.is_adult() else (
		tr(&"SELECT_SURVIVOR") if who.job == &"" else tr(Jobs.get_job(who.job).display_name))
	_sel_who.text = L10n.t(&"SELECT_IDENTITY",
		[who.profile.display_name, who.profile.age_days, role])
	_sel_doing.text = who.describe()
	var gear: PackedStringArray = []
	for row in who.profile.equipment.values():
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var item_def := Items.get_item(StringName(row.get("def", &"")))
		if item_def != null:
			gear.append(tr(item_def.display_name))
	if not gear.is_empty():
		_sel_doing.text += L10n.t(&"SELECT_EQUIPMENT", [", ".join(gear)])
	_sel_needs.text = L10n.t(&"SELECT_NEEDS",
		[int(who.health), int(who.max_health), int(who.food), int(who.water),
			int(who.rest), int(who.mood)])
	_equipment_policy.visible = who.is_adult()
	_equipment_policy.text = tr({
		&"best_available": &"EQUIP_BEST",
		&"preserve_durability": &"EQUIP_PRESERVE",
		&"none": &"EQUIP_NONE",
	}.get(who.profile.equipment_policy, &"EQUIP_BEST"))
	# Colour the needs line by its worst value, so a starving villager is visible without
	# the player having to read four numbers.
	var health_percent := who.health / maxf(who.max_health, 1.0) * 100.0
	var worst: float = minf(minf(minf(who.food, who.water), who.rest), health_percent)
	var tint := UiPalette.TEXT_DIM
	if worst <= Villager.HUNGER_URGENT:
		tint = UiPalette.DANGER if worst <= 15.0 else UiPalette.WARN
	_sel_needs.add_theme_color_override("font_color", tint)


func _on_equipment_policy() -> void:
	var who: Villager = _god_hand.selected if _god_hand != null else null
	if who == null or not is_instance_valid(who) or not who.is_adult():
		return
	var policies: Array[StringName] = [&"best_available", &"preserve_durability", &"none"]
	var at := policies.find(who.profile.equipment_policy)
	who.set_equipment_policy(policies[(maxi(at, 0) + 1) % policies.size()])
	_refresh_selection()


## Only one large drawer is allowed in the thumb zone. This is both a readability
## rule and a hard layout guarantee for the 360 px-tall mobile viewport.
func _action_panel_open() -> bool:
	return _breakdown.visible or _job_panel.visible or _build_panel.visible \
		or _control_panel.visible or _library_panel.visible or _placement_bar.visible \
		or _gather_bar.visible \
		or _migrant_prompt.visible


func _sync_management_pause() -> void:
	var should_pause := Accessibility.pause_while_managing and _action_panel_open()
	if should_pause and not Sim.paused:
		_management_pause_owned = true
		Sim.set_paused(true)
	elif not should_pause and _management_pause_owned:
		_management_pause_owned = false
		Sim.set_paused(false)


func _refresh() -> void:
	_refresh_resources()
	_refresh_counts()
	_refresh_cards()
	_refresh_powers()
	_refresh_phase()
	_refresh_selection()
	_refresh_building_card()
	_refresh_control_panel()


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
		var minus_button: Button = w["minus"]
		var plus_button: Button = w["plus"]
		if not is_equal_approx(slider.max_value, slider_max):
			slider.max_value = slider_max
		var have := Colony.headcount_of(id)
		var want := Colony.quota_of(id)
		minus_button.disabled = want <= 0
		plus_button.disabled = want >= int(slider_max)
		count.text = L10n.t(&"HUD_HEADCOUNT", [have, want])
		# Amber when the colony cannot meet the order — the player needs to see
		# "you asked for more people than you have" without opening a tutorial.
		count.add_theme_color_override("font_color",
			UiPalette.WARN if have < want else UiPalette.TEXT_DIM)
