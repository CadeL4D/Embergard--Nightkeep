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
## The menus, in tab order.
##
## Ordered by how often a hand reaches for them rather than by when they were written: Jobs and
## Build are the two the player lives in, so they sit where the thumb lands first.
##
## One list, one dropdown, one open tab — replacing three overlapping mechanisms that all reached
## these same seven panels (a toggle button each, a Cycle button that chose which menu the "open"
## button would open, and a hold-drag radial switcher). Each had its own idea of what "open" meant,
## and mutual exclusion was enforced by every panel explicitly un-pressing the other four.
const MENU_IDS: Array[StringName] = [
	&"jobs", &"construction", &"harvest", &"terrain", &"spells", &"console", &"world", &"goals",
]
const MENU_LABELS: Array[StringName] = [
	&"UI_JOBS", &"UI_CONSTRUCTION", &"UI_HARVEST", &"UI_TERRAIN", &"UI_SPELLS",
	&"UI_CONSOLE", &"UI_WORLD", &"UI_GOALS",
]

@onready var _safe_area: MarginContainer = $SafeArea
@onready var _layout: VBoxContainer = $SafeArea/Layout
@onready var _job_scroll: ScrollContainer = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel/Layout/Scroll
@onready var _library_scroll: ScrollContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/LibraryPanel/Layout/Scroll
@onready var _cards_scroll: ScrollContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel/Layout/CardsScroll
@onready var _breakdown_scroll: ScrollContainer = \
	$SafeArea/Layout/Breakdown/Scroll
@onready var _resources: ResourceReadout = \
	$SafeArea/Layout/TopRow/ResourceColumn/ResourceBar/Resources
@onready var _resource_bar: PanelContainer = $SafeArea/Layout/TopRow/ResourceColumn/ResourceBar
@onready var _breakdown: BreakdownPanel = $SafeArea/Layout/Breakdown
@onready var _menu_dock: VBoxContainer = $SafeArea/Layout/MenuDock
@onready var _menus_button: Button = $SafeArea/Layout/MenuDock/MenusButton
@onready var _menu_panel: PanelContainer = $SafeArea/Layout/MenuDock/MenuPanel
@onready var _menu_tabs_clip: ScrollContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/TabsClip
@onready var _menu_tabs: HBoxContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/TabsClip/Tabs
@onready var _library_panel: PanelContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/LibraryPanel
@onready var _library_rows: VBoxContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/LibraryPanel/Layout/Scroll/Rows
@onready var _library_capacity: Label = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/LibraryPanel/Layout/Header/Capacity
@onready var _library_auto: CheckButton = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/LibraryPanel/Layout/Header/Auto
@onready var _library_details: Label = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/LibraryPanel/Layout/Details
@onready var _control_panel: PanelContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel
@onready var _control_status: Label = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Status
@onready var _forbidden_button: Button = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Paint/Forbidden
@onready var _work_zone_button: Button = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Paint/Work
@onready var _guard_zone_button: Button = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Paint/Guard
@onready var _erase_zone_button: Button = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Paint/Erase
@onready var _shelter_button: Button = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Orders/Shelter
@onready var _dusk_button: Button = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Orders/Dusk
@onready var _cleanse_button: Button = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ControlPanel/Layout/Orders/Cleanse
@onready var _concerns_panel: PanelContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ConcernsPanel
@onready var _concerns_scroll: ScrollContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ConcernsPanel/Layout/Scroll
@onready var _concerns_rows: VBoxContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/ConcernsPanel/Layout/Scroll/Rows
@onready var _job_panel: PanelContainer = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel
@onready var _job_hint: Label = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel/Layout/Hint
@onready var _harvest_areas: Button = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel/Layout/Header/HarvestAreas
@onready var _workers_available: Label = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel/Layout/Header/Workers
@onready var _rows: VBoxContainer = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel/Layout/Scroll/Rows
@onready var _gather_bar: PanelContainer = $SafeArea/Layout/BottomRow/GatherBar
@onready var _gather_done: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/DoneButton
@onready var _gather_status: Label = $SafeArea/Layout/BottomRow/GatherBar/Row/Status
@onready var _gather_wood: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/WoodButton
@onready var _gather_stone: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/StoneButton
@onready var _gather_berries: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/BerriesButton
@onready var _gather_radius_minus: Button = \
	$SafeArea/Layout/BottomRow/GatherBar/Row/RadiusMinus
@onready var _gather_radius_label: Label = $SafeArea/Layout/BottomRow/GatherBar/Row/Radius
@onready var _gather_radius_plus: Button = \
	$SafeArea/Layout/BottomRow/GatherBar/Row/RadiusPlus
@onready var _gather_paint: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/PaintButton
@onready var _gather_erase: Button = $SafeArea/Layout/BottomRow/GatherBar/Row/EraseButton
@onready var _build_panel: PanelContainer = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel
@onready var _center_status: Label = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel/Layout/CenterRow/Status
@onready var _center_raise: Button = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel/Layout/CenterRow/RaiseButton
@onready var _tabs: HBoxContainer = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel/Layout/Tabs
@onready var _cards: HBoxContainer = \
	$SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel/Layout/CardsScroll/Cards
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
@onready var _powers: HBoxContainer = $SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/Powers
@onready var _phase_label: Label = $SafeArea/Layout/TopRow/PhaseBar/Row/Phase
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
var _selected_golem_id: int = 0
var _management_pause_owned: bool = false
var _management_pause_suppressed: bool = false
var _upgrade_widgets: Dictionary = {}
var _upgrade_key: String = ""
## Which tab the dropdown shows. Remembered while closed, so reopening returns you to the menu
## you were last working in rather than to a fixed first tab.
var _menu_tab: StringName = &"jobs"
## menu id -> tab button
var _menu_tab_buttons: Dictionary = {}
var _power_hold_button: Button = null
var _power_hold_def: PowerDef = null
var _power_hold_elapsed: float = 0.0
var _power_hold_shown: bool = false
var _power_hold_suppressed: Button = null
var _status_sample_tick: int = -1
var _last_water_sample: float = 0.0
var _last_mood_sample: float = 0.0
var _water_rate: float = 0.0
var _mood_rate: float = 0.0


func _ready() -> void:
	_apply_safe_area()
	_harvest_areas.text = tr(&"GATHER_AREAS")
	_gather_wood.text = tr(&"GATHER_WOOD")
	_gather_stone.text = tr(&"GATHER_STONE")
	_gather_berries.text = tr(&"GATHER_BERRIES")
	_gather_erase.text = tr(&"GATHER_REMOVE")
	get_tree().root.size_changed.connect(_apply_safe_area)
	Accessibility.changed.connect(_on_accessibility_changed)
	_apply_handedness()

	_library_auto.toggled.connect(Divine.set_library_auto_manage)
	_menus_button.toggled.connect(_on_menus_toggled)
	_build_menu_tabs()
	_center_raise.pressed.connect(_on_center_raise)
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
		_god_hand.hand_mode_changed.connect(func(_active: bool) -> void:
			_refresh_menu_tabs())

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
	_harvest_areas.pressed.connect(_on_harvest_areas)
	_gather_wood.pressed.connect(_select_harvest_job.bind(&"woodcutting"))
	_gather_stone.pressed.connect(_select_harvest_job.bind(&"quarrying"))
	_gather_berries.pressed.connect(_select_harvest_job.bind(&"foraging"))
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

	# A drawer only costs column height while it is open, so refit on every open and
	# close as well as on resize. Deferred because the signal arrives before the
	# containers above have invalidated their cached minimum sizes.
	for panel: Control in [_job_panel, _library_panel, _build_panel, _breakdown]:
		panel.visibility_changed.connect(_fit_drawers, CONNECT_DEFERRED)

	_sync_rows()
	_build_tabs()
	_build_cards()
	_build_powers()
	_rebuild_library()
	_refresh()
	_close_menus()
	_fit_drawers.call_deferred()


# --- Layout ------------------------------------------------------------------------

## Authored heights for the scrolling drawers, used as the CEILING they are allowed to
## reach rather than as a fixed size. See _fit_drawer.
const JOB_SCROLL_HEIGHT := 220.0
const LIBRARY_SCROLL_HEIGHT := 178.0
const CARDS_SCROLL_HEIGHT := 72.0
const CONCERNS_SCROLL_HEIGHT := 150.0
const BREAKDOWN_SCROLL_HEIGHT := 176.0
## Below this a drawer is not worth showing, so it scrolls instead of shrinking further.
const DRAWER_MIN_HEIGHT := 64.0


func _apply_safe_area() -> void:
	SafeArea.apply(_safe_area, 8)
	_fit_menu_tabs()
	_fit_drawers()


## Shrink whichever drawer is open until the whole HUD column fits on the screen.
##
## The dropdown hangs from the top-left and the world-context cards sit at the bottom, so an
## over-tall menu body pushes those cards — and anything else below it — off the screen. The
## original form of this bug took the button row that carried the ONLY way out of a drawer with
## it, which is why the panel is measured rather than trusted.
##
## Measured against the viewport rather than against SafeArea's own rect on purpose. An
## anchored Control is grown to its combined minimum size, so once the column overflows
## the container reports the OVERSIZED height and the slack always reads as zero — the
## measurement would agree that everything fits while it visibly did not.
func _fit_drawers() -> void:
	if not is_node_ready():
		return
	_fit_drawer(_breakdown_scroll, BREAKDOWN_SCROLL_HEIGHT)
	_fit_drawer(_job_scroll, JOB_SCROLL_HEIGHT)
	_fit_drawer(_library_scroll, LIBRARY_SCROLL_HEIGHT)
	_fit_drawer(_cards_scroll, CARDS_SCROLL_HEIGHT)
	_fit_drawer(_concerns_scroll, CONCERNS_SCROLL_HEIGHT)


func _fit_drawer(scroll: ScrollContainer, design_height: float) -> void:
	if scroll == null or not scroll.is_visible_in_tree():
		return
	var chrome := float(_safe_area.get_theme_constant(&"margin_top")
		+ _safe_area.get_theme_constant(&"margin_bottom"))
	var available := get_tree().root.get_visible_rect().size.y - chrome
	# Slack is signed: negative shrinks this drawer by exactly the overflow, positive
	# grows it back toward its authored height once there is room again. Because the
	# column's minimum already includes the drawer's current minimum, one pass lands on
	# the answer — no waiting for a layout frame.
	var slack := available - _layout.get_combined_minimum_size().y
	scroll.custom_minimum_size.y = clampf(
		scroll.custom_minimum_size.y + slack, DRAWER_MIN_HEIGHT, design_height)


func _on_accessibility_changed(kind: StringName) -> void:
	if kind == &"handedness":
		_apply_handedness()
	if kind == &"management_pause":
		_sync_management_pause()
	if kind == &"status_display":
		_refresh_phase()


## The dock lives in the top corner on the side the player's thumb is not covering.
##
## It was the bottom strip's reordering that used to answer this setting. Now that every menu
## hangs from one corner, mirroring which corner is both simpler and a bigger win: a right-handed
## player holding a phone one-handed has their palm over the right edge, so the panel that has to
## stay readable belongs on the left.
func _apply_handedness() -> void:
	if _menu_dock == null:
		return
	# The dock is only as wide as its widest child, so its own horizontal size flag is the whole
	# mirror. A BoxContainer's `alignment` would not help here — on a VBox that aligns children
	# vertically, which is not the axis being flipped.
	var left := Accessibility.handedness == Accessibility.Handedness.RIGHT
	_menu_dock.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if left \
		else Control.SIZE_SHRINK_END


# --- The menu dropdown -----------------------------------------------------------------
#
# One button, one panel, one open tab. The panel stays up until the player closes it, because a
# menu that vanishes on its own is a menu you have to keep reopening — and reopening it used to
# mean finding the right button in a strip of nine.

func _build_menu_tabs() -> void:
	for child in _menu_tabs.get_children():
		_menu_tabs.remove_child(child)
		child.queue_free()
	_menu_tab_buttons.clear()
	for index in MENU_IDS.size():
		var id: StringName = MENU_IDS[index]
		var tab := Button.new()
		tab.name = "Tab_%s" % id
		tab.text = tr(MENU_LABELS[index])
		tab.toggle_mode = true
		tab.custom_minimum_size = Vector2(0, 20)
		tab.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		tab.pressed.connect(_select_menu_tab.bind(id))
		_menu_tabs.add_child(tab)
		_menu_tab_buttons[id] = tab
	_fit_menu_tabs()
	_refresh_menu_tabs()


## Widen the dropdown to hold the whole tab strip, up to what the screen can take.
##
## A ScrollContainer reports a minimum width of zero, so without this the panel is sized purely by
## whichever menu body is open — and on the narrow Job Board that clipped the last tab in half and
## put a scrollbar under the strip. A tab you cannot see is a menu the player cannot find, which is
## the exact failure the dropdown exists to fix. The scroll survives underneath as the fallback for
## a screen genuinely too narrow to show seven tabs at once.
func _fit_menu_tabs() -> void:
	if _menu_tabs_clip == null:
		return
	var chrome := float(_safe_area.get_theme_constant(&"margin_left")
		+ _safe_area.get_theme_constant(&"margin_right")) + 24.0
	var room := get_tree().root.get_visible_rect().size.x - chrome
	_menu_tabs_clip.custom_minimum_size.x = minf(
		_menu_tabs.get_combined_minimum_size().x, maxf(room, 0.0))


func _on_menus_toggled(pressed: bool) -> void:
	if pressed:
		_select_menu_tab(_menu_tab)
	else:
		_close_menus()


func _select_menu_tab(id: StringName) -> void:
	var workspace := get_node_or_null("../MobileWorkspace")
	if workspace != null and workspace.has_method("open"):
		_menu_tab = id
		_menu_panel.visible = false
		_menus_button.set_pressed_no_signal(false)
		_apply_menu_tab()
		workspace.open(id)
		_sync_management_pause()
		return
	if id == &"realm":
		# The Realm map is a screen of its own, not a drawer. Opening it closes the dropdown
		# rather than leaving a panel stranded underneath a full-screen map — and _menu_tab is
		# left alone so reopening returns to the menu the player was actually working in.
		_close_menus()
		_on_realm()
		return
	_menu_tab = id
	_menu_panel.visible = true
	_menus_button.set_pressed_no_signal(true)
	_apply_menu_tab()


func _close_menus() -> void:
	_menu_panel.visible = false
	_menus_button.set_pressed_no_signal(false)
	_apply_menu_tab()


func _menu_is_open(id: StringName) -> bool:
	return _menu_panel.visible and _menu_tab == id


## Push the one piece of state out to every panel.
##
## Each `_on_*_toggled` still owns what its own menu does on open and close — cancelling a brush,
## dropping a placement ghost, closing the breakdown. What they no longer do is reach across and
## un-press each other: exclusivity is a property of there being one open tab.
func _apply_menu_tab() -> void:
	if not is_node_ready():
		return
	_on_jobs_toggled(_menu_is_open(&"jobs"))
	_on_build_toggled(_menu_is_open(&"build"))
	_on_control_toggled(_menu_is_open(&"control"))
	_on_library_toggled(_menu_is_open(&"library"))
	_on_hand_toggled(_menu_is_open(&"hand"))
	_powers.visible = _menu_is_open(&"powers")
	_concerns_panel.visible = _menu_is_open(&"concerns")
	_refresh_concerns()
	_refresh_menu_tabs()
	_fit_drawers()


func _refresh_menu_tabs() -> void:
	for id in _menu_tab_buttons:
		var tab: Button = _menu_tab_buttons[id]
		var active: bool = _menu_panel.visible and id == _menu_tab
		tab.set_pressed_no_signal(active)
		tab.add_theme_color_override("font_color",
			UiPalette.ACCENT if active else UiPalette.TEXT_DIM)
	# The Hand is a world tool rather than a panel, so its tab is where its state has to show.
	if _god_hand != null and _menu_tab_buttons.has(&"hand"):
		(_menu_tab_buttons[&"hand"] as Button).text = _god_hand.hand_status()


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
		# Harvest designations now have one clear entry point at the top of the
		# board. Per-row Area buttons made basic and advanced jobs look like they
		# owned unrelated territories even when they harvested the same resource.
		area_button.visible = false
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
	_refresh_selection()
	_refresh_building_card()
	_sync_management_pause()


func _on_gather_area(job_id: StringName) -> void:
	DefenseControl.set_gather_mode(job_id)


func _on_harvest_areas() -> void:
	DefenseControl.select_gather_mode(&"woodcutting")


func _select_harvest_job(job_id: StringName) -> void:
	if DefenseControl.gather_job == job_id:
		DefenseControl.set_gather_erasing(false)
	else:
		DefenseControl.select_gather_mode(job_id)


func _on_gather_mode_changed(job_id: StringName, erasing: bool, radius: int) -> void:
	if not is_node_ready():
		return
	var active := job_id != &""
	_gather_bar.visible = active
	if not active:
		return
	# A harvest brush owns the map surface, so the dropdown that was covering part of it
	# gets out of the way for the duration.
	_close_menus()
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
	_gather_wood.set_pressed_no_signal(job_id == &"woodcutting" and not erasing)
	_gather_stone.set_pressed_no_signal(job_id == &"quarrying" and not erasing)
	_gather_berries.set_pressed_no_signal(job_id == &"foraging" and not erasing)


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

	# revealed(), not placeable(): a card gated only on POPULATION is shown and disabled, because
	# that gate is a number the player watches climb. A card behind a Village Center tier is not
	# here at all — the Center row above the tabs is where the next tier is advertised, once,
	# with the whole list behind it. See Buildings.revealed.
	for def: BuildingDef in Buildings.revealed():
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


# --- The Watch -------------------------------------------------------------------------
#
# What is wrong in the colony, right now, ranked. Derived entirely from live state — no new
# simulation, nothing stored — because everything here was already knowable and simply had
# nowhere to be said. Toasts scroll away; a villager standing still says nothing at all. Two
# separate freeze bugs reached the point of killing colonists partly because the only way to
# discover either was to notice a body.

## Highest severity first, so the thing that will kill somebody is never below the thing that
## is merely untidy. Capped: a list nobody can read is the same as no list.
const MAX_CONCERNS := 12


func _gather_concerns() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var threat_info := Threat.pressure_breakdown()
	if bool(threat_info.get("suppressed", false)):
		out.append({"rank": 3, "text": tr(&"THREAT_REGION_PURIFIED")})
	else:
		out.append({"rank": 2, "text": L10n.t(&"THREAT_WATCH_BREAKDOWN", [
			int(round(float(threat_info.get("current_pressure", 0.0)) * 100.0)),
			int(round(float(threat_info.get("desired_coverage", 0.0)) * 100.0)),
			int(round(float(threat_info.get("actual_coverage", 0.0)) * 100.0)),
			int(threat_info.get("enemy_structure_count", 0)),
		])})
	var idle_by_reason: Dictionary = {}
	var starving := 0
	var parched := 0
	for villager: Villager in Colony.villagers:
		if not is_instance_valid(villager) or not villager.alive:
			continue
		if villager.food <= 0.0:
			starving += 1
		if villager.water <= 0.0:
			parched += 1
		# Only counted while genuinely stopped: a villager walking to the answer is not a problem.
		if villager.idle_reason != &"" and not villager.is_moving():
			idle_by_reason[villager.idle_reason] = \
				int(idle_by_reason.get(villager.idle_reason, 0)) + 1

	if parched > 0:
		out.append({"rank": 0, "text": L10n.t(&"CONCERN_PARCHED", [parched])})
	if starving > 0:
		out.append({"rank": 0, "text": L10n.t(&"CONCERN_STARVING", [starving])})
	for reason: StringName in idle_by_reason:
		var rank := 1 if reason in [&"no_food", &"no_water"] else 2
		out.append({"rank": rank, "text": L10n.t(&"CONCERN_IDLE", [
			int(idle_by_reason[reason]),
			tr(StringName("IDLE_" + String(reason).to_upper()))])})

	# A settlement drinking from the river has until the freeze to sink a well, and the whole
	# point of a warning a season early is that it is still actionable.
	if not Colony.has_sheltered_water():
		out.append({"rank": 1 if Climate.shores_frozen() else 3,
			"text": tr(&"CONCERN_NO_WELL")})

	# beds_free() already nets off who is sleeping in them, so a negative reading is exactly
	# "more people than the housing can hold" without a second count of the population.
	if Colony.beds_free() <= 0 and Colony.population() > 0:
		out.append({"rank": 3, "text": L10n.t(&"CONCERN_NO_BEDS", [Colony.population()])})

	var damaged := 0
	var dry_towers := 0
	var dry_magic := 0
	for candidate in Colony.buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b) or b.is_site():
			continue
		if b.needs_repair():
			damaged += 1
		if not b.def.ammo_kind.is_empty() and b.def.ammo_per_shot > 0 \
				and int(b.input_buffer.get(b.def.ammo_kind, 0)) < b.def.ammo_per_shot:
			dry_towers += 1
		if b.def.energy_per_shot > 0 \
				and Colony.energy_available_near(b.centre_cell()) < b.def.energy_per_shot:
			dry_magic += 1
	# Goods on the ground are only a problem if nobody is coming for them, so this is really a
	# report on whether the colony employs anyone who hauls.
	var loose := Colony.loose_resource_total()
	if loose > 0:
		out.append({"rank": 2 if Colony.headcount_of(&"worker") <= 0 else 3,
			"text": L10n.t(&"CONCERN_SPILLS", [loose])})
	if dry_towers > 0:
		out.append({"rank": 1, "text": L10n.t(&"CONCERN_TOWER_DRY", [dry_towers])})
	if dry_magic > 0:
		out.append({"rank": 1, "text": L10n.t(&"CONCERN_MAGIC_DRY", [dry_magic])})
	if damaged > 0:
		out.append({"rank": 3, "text": L10n.t(&"CONCERN_DAMAGED", [damaged])})

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["rank"]) < int(b["rank"]))
	return out


func _refresh_concerns() -> void:
	if not is_node_ready() or not _concerns_panel.visible:
		return
	for child in _concerns_rows.get_children():
		_concerns_rows.remove_child(child)
		child.queue_free()

	var concerns := _gather_concerns()
	if concerns.is_empty():
		var calm := Label.new()
		calm.text = tr(&"CONCERNS_NONE")
		calm.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		calm.add_theme_color_override("font_color", UiPalette.OK)
		_concerns_rows.add_child(calm)
		return

	for index in mini(concerns.size(), MAX_CONCERNS):
		var row: Dictionary = concerns[index]
		var label := Label.new()
		label.text = String(row["text"])
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(300, 0)
		label.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		label.add_theme_color_override("font_color", [
			UiPalette.DANGER, UiPalette.WARN, UiPalette.TEXT, UiPalette.TEXT_DIM,
		][clampi(int(row["rank"]), 0, 3)])
		_concerns_rows.add_child(label)


## The colony's Village Center, whatever tier it currently stands at.
##
## Found by property rather than by id so a scenario that nominates a different structure as its
## centre keeps working — the same reason BuildingDef carries `center_tier` at all.
func _center_building() -> Building:
	var best: Building = null
	for candidate in Colony.buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b) or b.is_site() or b.def.center_tier <= 0:
			continue
		if best == null or b.def.center_tier > best.def.center_tier:
			best = b
	return best


## The one place the build menu talks about progression.
##
## Since the tier gate now HIDES future cards, something has to say what raising the Center buys,
## or a first-day menu of fifteen cards reads as the whole game. This row is that something: the
## next tier by name, what it wants, and how many buildings arrive with it.
##
## Raising happens right here rather than only on the Center's own selection card. Requiring the
## player to close the build menu and find the Hearth on the map, in order to unlock the rest of
## the build menu, is the kind of loop that makes progression feel hidden rather than earned. The
## work itself still goes through Colony.upgrade_building, so there is one upgrade path.
func _refresh_center_row() -> void:
	if not is_node_ready():
		return
	var center := _center_building()
	# Built in two statements, not a ternary. An inline `else []` is an UNTYPED Array literal,
	# which cannot be assigned to an Array[Dictionary] — and the failure is a runtime script
	# error rather than a parse error, so it only surfaces when the HUD is actually built.
	var checks: Array[Dictionary] = []
	if center != null:
		checks = Colony.upgrade_checks(center)
	if checks.is_empty():
		_center_status.text = tr(&"CENTER_ROW_MAX")
		_center_raise.visible = false
		return

	var check: Dictionary = checks[0]
	var next: BuildingDef = check["def"]
	_center_status.text = L10n.t(&"CENTER_ROW_NEXT", [
		tr(next.display_name), Buildings.revealed_by_next_center(), next.cost_text()])
	_center_raise.visible = true
	_center_raise.text = L10n.t(&"UI_UPGRADE_TO", [tr(next.display_name)])
	_center_raise.disabled = not bool(check["ok"])
	_center_raise.tooltip_text = String(check["reason"])


func _on_center_raise() -> void:
	var center := _center_building()
	if center == null:
		return
	var checks := Colony.upgrade_checks(center)
	if checks.is_empty():
		return
	var next: BuildingDef = checks[0]["def"]
	if next == null or not Colony.upgrade_building(center, next.id):
		return
	# Show the player where their materials are about to go. The Center can be well off screen by
	# the time this is affordable, and an upgrade with no visible consequence reads as a dead tap.
	var camera := get_node_or_null("../CameraRig")
	if camera != null and camera.has_method("focus_on_rect"):
		camera.focus_on_rect(center.world_rect())
	_refresh_center_row()


## Anything that can change what is buildable: a completed Village Center raises the tier, a
## destroyed one lowers it, an arriving survivor can clear a headcount gate.
func _on_roster_changed(_arg: Variant = null) -> void:
	# Guarded by a signature, like the job rows and the ability buttons.
	#
	# This fires on every building AND every villager, and it used to rebuild the whole tab strip and
	# card row unconditionally — so the stress test's 60 spawns triggered 60 full menu rebuilds,
	# instantiating several hundred card scenes and immediately freeing them. Population only matters
	# here through `min_population` gates, which change at a handful of thresholds, not per villager.
	var key := "%d:%d:%d" % [Colony.center_tier(), Colony.population(), Buildings.revealed().size()]
	if key != _menu_key:
		_menu_key = key
		_build_tabs()
		_build_cards()
	_refresh_center_row()
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
			_bld_detail.text += L10n.t(&"BLD_AMMO", [int(b.input_buffer.get(def.ammo_kind, 0)),
				L10n.resource(def.ammo_kind)])
		if def.faith_upkeep > 0.0:
			_bld_detail.text += L10n.t(&"BLD_FAITH_UPKEEP", [def.faith_upkeep])
		if def.energy_capacity > 0:
			_bld_detail.text += L10n.t(&"BLD_ENERGY", [b.stored_energy, def.energy_capacity])
		elif def.energy_per_shot > 0:
			_bld_detail.text += L10n.t(&"BLD_NEARBY_ENERGY",
				[Colony.energy_available_near(b.centre_cell()), def.energy_per_shot])
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
			var choice := HBoxContainer.new()
			choice.add_theme_constant_override("separation", 5)
			var button := Button.new()
			button.custom_minimum_size = Vector2(98, 24)
			button.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
			button.pressed.connect(_on_upgrade_to.bind(option.id))
			choice.add_child(button)
			var needs := RichTextLabel.new()
			needs.bbcode_enabled = true
			needs.fit_content = true
			needs.scroll_active = false
			needs.custom_minimum_size = Vector2(116, 22)
			needs.add_theme_font_size_override("normal_font_size", UiTheme.FONT_SIZE_SMALL)
			choice.add_child(needs)
			_upgrade_choices.add_child(choice)
			_upgrade_widgets[option.id] = {"button": button, "needs": needs}

	_upgrade_choices.visible = not checks.is_empty()
	for check: Dictionary in checks:
		var option: BuildingDef = check["def"]
		if option == null or not _upgrade_widgets.has(option.id):
			continue
		var widgets: Dictionary = _upgrade_widgets[option.id]
		var button: Button = widgets["button"]
		var needs: RichTextLabel = widgets["needs"]
		button.disabled = not bool(check["ok"])
		button.text = L10n.t(&"UI_UPGRADE_TO", [tr(option.display_name)])
		button.tooltip_text = "%s\n%s" % [tr(option.description), String(check["reason"])]
		needs.text = _upgrade_requirements(option)
		needs.tooltip_text = String(check["reason"])


func _upgrade_requirements(option: BuildingDef) -> String:
	var parts := PackedStringArray()
	var ok_color := UiPalette.OK.to_html(false)
	var no_color := UiPalette.DANGER.to_html(false)
	for kind: StringName in option.cost:
		var have := Colony.available(kind)
		var required := int(option.cost[kind])
		parts.append("[color=#%s]%s %d/%d[/color]" % [
			ok_color if have >= required else no_color,
			L10n.resource(kind), have, required])
	if option.center_tier == 0 and option.tier > 1:
		var center_ok := Colony.center_tier() >= option.tier
		parts.append("[color=#%s]%s %d/%d[/color]" % [
			ok_color if center_ok else no_color, tr(&"UI_CENTER_SHORT"),
			Colony.center_tier(), option.tier])
	if option.min_population > 0:
		var population := Colony.population()
		parts.append("[color=#%s]%s %d/%d[/color]" % [
			ok_color if population >= option.min_population else no_color,
			tr(&"UI_POPULATION_SHORT"), population, option.min_population])
	if option.unlock_cost > 0:
		var unlocked := Meta.is_unlocked(option.id)
		parts.append("[color=#%s]%s[/color]" % [
			ok_color if unlocked else no_color,
			tr(&"UI_UNLOCKED") if unlocked \
			else L10n.t(&"UI_SHARDS_REQUIRED", [option.unlock_cost])])
	return "  ".join(parts)


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
		Colony.mark_supply_requests_dirty()
		_refresh_building_card()


func _on_worker_limit() -> void:
	var b := _selected_building()
	if b != null and b.def.worker_slots > 0:
		var current := b.effective_worker_slots()
		b.production_worker_limit = (current + 1) % (b.def.worker_slots + 1)
		Colony.mark_supply_requests_dirty()
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
	Colony.mark_supply_requests_dirty()
	_refresh_building_card()


func _on_build_toggled(pressed: bool) -> void:
	_build_panel.visible = pressed
	if pressed:
		if _god_hand != null:
			_god_hand.set_hand_mode(false)
		DefenseControl.cancel_gather_paint()
		_breakdown.visible = false
	elif _placement != null and _placement.active:
		_placement.cancel()
	_refresh_cards()
	_refresh_center_row()
	_refresh_selection()
	_refresh_building_card()
	_sync_management_pause()


func _on_hand_toggled(pressed: bool) -> void:
	if _god_hand == null:
		return
	_god_hand.set_hand_mode(pressed)
	if pressed:
		_breakdown.visible = false
	_sync_management_pause()


func _on_control_toggled(pressed: bool) -> void:
	_control_panel.visible = pressed
	if pressed:
		if _god_hand != null:
			_god_hand.set_hand_mode(false)
		DefenseControl.cancel_gather_paint()
		_breakdown.visible = false
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
	_build_panel.visible = _menu_is_open(&"build") and not active
	if not active:
		_refresh_selection()
		_refresh_building_card()
		return
	DefenseControl.cancel_gather_paint()
	_breakdown.visible = false
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
		button.button_down.connect(_on_power_hold_started.bind(def, button))
		button.button_up.connect(_on_power_hold_released.bind(button))
		button.pressed.connect(_on_power_pressed.bind(def, button))
		_powers.add_child(button)
		_power_widgets[def.id] = button


func _on_power_hold_started(def: PowerDef, button: Button) -> void:
	_power_hold_button = button
	_power_hold_def = def
	_power_hold_elapsed = 0.0
	_power_hold_shown = false
	_power_hold_suppressed = null


func _on_power_hold_released(button: Button) -> void:
	if _power_hold_button != button:
		return
	_power_hold_button = null
	_power_hold_def = null
	_power_hold_elapsed = 0.0


func _on_power_pressed(def: PowerDef, button: Button = null) -> void:
	if button != null and _power_hold_suppressed == button:
		_power_hold_suppressed = null
		_power_hold_shown = false
		return
	if _god_hand == null:
		return
	if not Divine.power_active(def):
		Events.notice.emit(L10n.t(&"POWER_NO_TEMPLE", [tr(def.display_name)]), 1)
		return
	var cooldown := Divine.cooldown_of(def.id)
	if cooldown > 0.0:
		Events.notice.emit(L10n.t(&"POWER_ON_COOLDOWN", [
			tr(def.display_name), int(ceilf(cooldown))]), 1)
		return
	if Divine.faith < def.faith_cost:
		Events.notice.emit(L10n.t(&"POWER_NEED_FAITH", [int(def.faith_cost)]), 1)
		return
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
			button.disabled = false
			button.modulate = Color(1, 1, 1, 0.55)
		elif cd > 0.0:
			button.text = L10n.t(&"POWER_ON_COOLDOWN", [tr(def.display_name), int(ceilf(cd))])
			button.disabled = false
			button.modulate = Color(1, 1, 1, 0.55)
		else:
			button.text = L10n.t(&"POWER_COST", [tr(def.display_name), int(def.faith_cost)])
			button.disabled = false
			button.modulate = Color.WHITE if Divine.faith >= def.faith_cost \
				else Color(1, 1, 1, 0.55)


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

	if _power_hold_button != null and not _power_hold_shown:
		_power_hold_elapsed += delta
		if _power_hold_elapsed >= Accessibility.hold_duration:
			_power_hold_shown = true
			_power_hold_suppressed = _power_hold_button
			Events.notice.emit("%s — %s" % [
				tr(_power_hold_def.display_name), tr(_power_hold_def.description)], 0)

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
	_refresh_selection()
	_refresh_building_card()
	if _god_hand != null:
		_refresh_menu_tabs()
	if _job_panel.visible:
		_refresh_counts()
	if _gather_bar.visible:
		_on_gather_mode_changed(
			DefenseControl.gather_job,
			DefenseControl.gather_erasing,
			DefenseControl.gather_radius)
	if _concerns_panel.visible:
		_refresh_concerns()
	if _build_panel.visible:
		_refresh_cards()
		_refresh_center_row()
	if _control_panel.visible:
		_refresh_control_panel()
	if _library_panel.visible:
		_library_capacity.text = L10n.t(&"LIBRARY_CAPACITY", [Divine.installed_count(),
			Divine.tome_capacity()])


## Calendar only. Lighting, particles, and the world itself communicate phase and weather.
func _refresh_phase() -> void:
	var threat_info := Threat.pressure_breakdown()
	var trend := int(threat_info.get("trend", 0))
	var arrow := "↑" if trend > 0 else ("↓" if trend < 0 else "→")
	var cause := &"THREAT_QUIET"
	if bool(threat_info.get("suppressed", false)):
		cause = &"THREAT_PURIFIED"
	elif float(threat_info.get("containment_ratio", 0.0)) > 0.05:
		cause = &"THREAT_BOXED_IN"
	elif int(threat_info.get("enemy_structure_count", 0)) > 0:
		cause = &"THREAT_ENEMY_WORKS"
	elif Sim.day > 1:
		cause = &"THREAT_WORLD_DAY"
	var phases := ["Day", "Dusk", "Night", "Dawn"]
	var phase_name: String = phases[Sim.phase]
	_phase_label.text = "%s %.0f°C · %s %d%% · %s · %s · %s %s" % [
		Climate.name_of_season(), Climate.ambient_temperature_c(), phase_name,
		int(Sim.phase_progress() * 100.0), L10n.t(&"HUD_DAY_MINIMAL", [Sim.day]),
		"Paused" if Sim.paused else "%dx" % int(Sim.time_scale), arrow, tr(cause)]
	_phase_label.tooltip_text = "Threat %d%% · resistance %d%% · footprint %d%% · enemy level %d · expected bodies %d" % [
		int(round(float(threat_info.get("current_pressure", 0.0)) * 100.0)),
		int(round(float(threat_info.get("containment_ratio", 0.0)) * 100.0)),
		int(round(float(threat_info.get("actual_coverage", 0.0)) * 100.0)),
		int(threat_info.get("enemy_level", 1)), int(threat_info.get("expected_bodies", 0))]
	_phase_label.add_theme_font_size_override("font_size", 9)
	_phase_label.add_theme_color_override("font_color", UiPalette.TEXT)


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
		_close_menus()
		if _placement != null and _placement.active:
			_placement.cancel()
	_breakdown.toggle()
	_refresh_selection()
	_refresh_building_card()
	if _god_hand != null:
		_refresh_menu_tabs()
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
	_close_menus()
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
	if _management_pause_owned and not pressed:
		# Manual Resume wins until all management drawers have closed.
		_management_pause_owned = false
		_management_pause_suppressed = true
	Sim.set_paused(pressed)


func _on_speed_pressed() -> void:
	if _management_pause_owned:
		_management_pause_owned = false
		_management_pause_suppressed = true
	Sim.cycle_speed()


func _on_menu_pressed() -> void:
	var menu := get_node_or_null("../PauseMenu")
	if menu != null and menu.has_method("open"):
		menu.open()


## Driven by the signal rather than by the button handlers, so the readout stays correct
## however the speed was changed — including from the debug keys.
func _on_speed_changed(_scale: float, paused: bool) -> void:
	# Resume can come from the pause menu, a speed hotkey, or another overlay. If an
	# automatic management pause owned the clock, any explicit resume relinquishes it.
	if _management_pause_owned and not paused:
		_management_pause_owned = false
		_management_pause_suppressed = true
	_speed_button.text = L10n.t(&"UI_SPEED", [0 if paused else int(Sim.time_scale)])


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
		_select_menu_tab(&"jobs")
	elif event.is_action_pressed(&"game_build"):
		_select_menu_tab(&"construction")
	elif event.is_action_pressed(&"game_realm"):
		_select_menu_tab(&"world")
	elif event.is_action_pressed(&"game_cancel"):
		if _placement != null and _placement.active:
			_placement.cancel()
		elif DefenseControl.gather_job != &"":
			DefenseControl.cancel_gather_paint()
		elif WorkOrders.active_kind >= 0:
			WorkOrders.cancel_tool()
		else:
			_breakdown.visible = false
			_close_menus()
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
	var who: Agent = _god_hand.selected as Agent if _god_hand != null else null
	if who == null or not is_instance_valid(who) or not who.alive or _action_panel_open():
		if _selected_golem_id != 0:
			_selected_golem_id = 0
			_demolish_armed = false
		_selection_card.visible = false
		return
	if who is Golem:
		var golem_id := who.get_instance_id()
		if _selected_golem_id != golem_id:
			_selected_golem_id = golem_id
			_demolish_armed = false
		_refresh_golem_selection(who)
		return
	if _selected_golem_id != 0:
		_selected_golem_id = 0
		_demolish_armed = false
	if not who is Villager:
		_selection_card.visible = false
		return
	var villager := who as Villager

	_selection_card.visible = true
	var role := tr(&"SELECT_CHILD") if not villager.is_adult() else (
		tr(&"SELECT_SURVIVOR") if villager.job == &"" \
		else tr(Jobs.get_job(villager.job).display_name))
	_sel_who.text = L10n.t(&"SELECT_IDENTITY",
		[villager.profile.display_name, villager.profile.age_days, role])
	_sel_doing.text = villager.describe()
	# Why they are standing there, straight from the decision that came back empty. This is the
	# question the player was previously left to answer by watching, and it is the one they ask
	# every time somebody appears to be doing nothing. See Villager.idle_reason.
	var idle := villager.idle_text()
	if not idle.is_empty() and not villager.is_moving():
		_sel_doing.text += "\n" + L10n.t(&"SELECT_IDLE_REASON", [idle])
	var danger := villager.danger_text()
	if not danger.is_empty():
		_sel_doing.text += "\n" + L10n.t(&"SELECT_DANGER", [danger])
	# Time served, which is the one number on a villager that answers to what they have done.
	var mastery := villager.profile.mastery_of(villager.job)
	if mastery > 0.01:
		var job_def := Jobs.get_job(villager.job)
		_sel_doing.text += "\n" + L10n.t(&"SELECT_MASTERY", [
			tr(job_def.display_name) if job_def != null else String(villager.job),
			int(mastery * 100.0)])
	var gear: PackedStringArray = []
	for row in villager.profile.equipment.values():
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var item_def := Items.get_item(StringName(row.get("def", &"")))
		if item_def != null:
			gear.append(tr(item_def.display_name))
	if not gear.is_empty():
		_sel_doing.text += L10n.t(&"SELECT_EQUIPMENT", [", ".join(gear)])
	_sel_needs.text = L10n.t(&"SELECT_NEEDS",
		[int(villager.health), int(villager.max_health), int(villager.food), int(villager.water),
			int(villager.rest), int(villager.mood)])
	_sel_needs.text += "\nFaith %d • comfort %d • stress %d • panic %d • confusion %d" % [
		int(villager.profile.faith), int(villager.profile.thermal_comfort),
		int(villager.profile.stress), int(villager.profile.panic),
		int(villager.profile.confusion)]
	_equipment_policy.visible = villager.is_adult()
	_equipment_policy.text = tr({
		&"best_available": &"EQUIP_BEST",
		&"preserve_durability": &"EQUIP_PRESERVE",
		&"none": &"EQUIP_NONE",
	}.get(villager.profile.equipment_policy, &"EQUIP_BEST"))
	# Colour the needs line by its worst value, so a starving villager is visible without
	# the player having to read four numbers.
	var health_percent := villager.health / maxf(villager.max_health, 1.0) * 100.0
	var worst: float = minf(minf(minf(villager.food, villager.water), villager.rest), health_percent)
	var tint := UiPalette.TEXT_DIM
	if worst <= Villager.HUNGER_URGENT:
		tint = UiPalette.DANGER if worst <= 15.0 else UiPalette.WARN
	_sel_needs.add_theme_color_override("font_color", tint)


func _refresh_golem_selection(golem: Golem) -> void:
	_selection_card.visible = true
	_sel_who.text = L10n.t(&"GOLEM_IDENTITY", [golem.display_name()])
	_sel_doing.text = golem.describe()
	_sel_needs.text = L10n.t(&"GOLEM_INTEGRITY", [int(golem.health), int(golem.max_health)])
	var health_percent := golem.health / maxf(golem.max_health, 1.0) * 100.0
	_sel_needs.add_theme_color_override("font_color",
		UiPalette.DANGER if health_percent <= 15.0 else (
		UiPalette.WARN if health_percent <= 35.0 else UiPalette.TEXT_DIM))
	_equipment_policy.visible = true
	_equipment_policy.text = tr(&"UI_DISMISS_CONFIRM" if _demolish_armed else &"UI_DISMISS")


func _on_equipment_policy() -> void:
	var who: Agent = _god_hand.selected as Agent if _god_hand != null else null
	if who == null or not is_instance_valid(who):
		return
	if who is Golem:
		if not _demolish_armed:
			_demolish_armed = true
			_demolish_timer = 3.0
			_refresh_selection()
			return
		_demolish_armed = false
		(who as Golem).dismiss()
		_god_hand.clear_selection()
		_refresh_selection()
		return
	if not who is Villager:
		return
	var villager := who as Villager
	if not villager.is_adult():
		return
	var policies: Array[StringName] = [&"best_available", &"preserve_durability", &"none"]
	var at := policies.find(villager.profile.equipment_policy)
	villager.set_equipment_policy(policies[(maxi(at, 0) + 1) % policies.size()])
	_refresh_selection()


## Only one large drawer is allowed in the thumb zone. This is both a readability
## rule and a hard layout guarantee for the 360 px-tall mobile viewport.
func _action_panel_open() -> bool:
	var workspace := get_node_or_null("../MobileWorkspace")
	var workspace_open: bool = workspace != null and workspace.has_method("is_open") \
		and workspace.is_open()
	return workspace_open or _breakdown.visible or _job_panel.visible or _build_panel.visible \
		or _control_panel.visible or _library_panel.visible or _placement_bar.visible \
		or _gather_bar.visible \
		or _migrant_prompt.visible


func _sync_management_pause() -> void:
	var panel_open := _action_panel_open()
	if not panel_open:
		if _management_pause_owned:
			_management_pause_owned = false
			Sim.set_paused(false)
		_management_pause_suppressed = false
		return
	if not Accessibility.pause_while_managing:
		if _management_pause_owned:
			_management_pause_owned = false
			Sim.set_paused(false)
		_management_pause_suppressed = false
		return
	if _management_pause_suppressed:
		return
	if not Sim.paused:
		_management_pause_owned = true
		Sim.set_paused(true)


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


## One flat, full-width material strip. Advanced materials appear once acquired; wood,
## stone, and food remain visible at zero because their absence is critical information.
func _refresh_resources() -> void:
	_sample_status_rates()
	var entries: Array = []
	for kind: StringName in Colony.KINDS:
		var amount := Colony.amount_of(kind)
		if amount <= 0 and kind not in [&"wood", &"stone", &"food"]:
			continue
		var rate := ""
		if kind == &"food":
			rate = _per_day(Colony.food_net_per_second() * Sim.cycle_seconds())
		var accessible := L10n.t(&"HUD_RESOURCE_ENTRY", [L10n.resource(kind), amount]) + rate
		entries.append({
			"kind": kind,
			"text": "%s %d%s" % [L10n.resource(kind), amount, rate],
			"accessible": accessible,
		})
	var waterskins := Colony.item_count(&"waterskin")
	var bottling := Jobs.get_job(&"bottling")
	if waterskins > 0 or (bottling != null and Jobs.has_workplace(bottling)):
		entries.append({
			"kind": &"bottled_water",
			"text": L10n.t(&"HUD_BOTTLED_WATER", [waterskins]),
			"accessible": L10n.t(&"HUD_BOTTLED_WATER_ACCESSIBLE", [waterskins]),
		})

	var population_text := "%d/%d%s" % [Colony.population(),
		Colony.population() + Colony.beds_free(), _growth_text()]
	var water_text := "%d%s" % [int(_average_water()), _rate_per_second(_water_rate)]
	var mood_text := "%d%s" % [int(Colony.average_mood()), _rate_per_second(_mood_rate)]
	var influence_text := "%d/%d (-%d)" % [int(DivineLedger.available),
		int(DivineLedger.total_capacity()), int(DivineLedger.reserved)]
	var faith_total := 0.0
	var faith_count := 0
	var energy_total := 0
	for villager in Colony.villagers:
		if is_instance_valid(villager) and villager.alive:
			faith_total += villager.profile.faith
			faith_count += 1
	for building in Colony.buildings:
		if is_instance_valid(building) and not building.is_site():
			energy_total += building.stored_energy
	var personal_faith := int(faith_total / float(maxi(faith_count, 1)))
	entries.append_array([
		{"kind": &"population", "text": population_text,
			"accessible": "population " + population_text},
		{"kind": &"water", "text": water_text, "accessible": "water " + water_text},
		{"kind": &"mood", "text": mood_text, "accessible": "mood " + mood_text},
		{"kind": &"faith", "text": "Influence " + influence_text,
			"accessible": "Influence " + influence_text},
		{"kind": &"personal_faith", "text": "Faith %d" % personal_faith,
			"accessible": "average personal Faith %d" % personal_faith},
		{"kind": &"energy", "text": "Energy %d" % energy_total,
			"accessible": "stored Energy %d" % energy_total},
	])
	_resources.set_rows([{"label": "", "entries": entries}])


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


static func _rate_per_second(delta: float) -> String:
	if absf(delta) < 0.05:
		return ""
	return " %+.1f/s" % delta


func _sample_status_rates() -> void:
	var now_tick := Sim.tick
	var water_now := _average_water()
	var mood_now := Colony.average_mood()
	if _status_sample_tick < 0 or now_tick < _status_sample_tick:
		_status_sample_tick = now_tick
		_last_water_sample = water_now
		_last_mood_sample = mood_now
		_water_rate = 0.0
		_mood_rate = 0.0
		return
	var ticks_elapsed := now_tick - _status_sample_tick
	if ticks_elapsed < 30:
		return
	var seconds := float(ticks_elapsed) * Sim.TICK_DT
	# Drinking and scripted phase changes happen in large, instant steps.  Feeding those
	# steps straight into the readout made it jump by several points per second even
	# though the underlying need decay is deliberately slow.  Winsorise each sample to
	# the real continuous drift range, then ease it so the top bar reads as a trend.
	var measured_water := clampf(
		(water_now - _last_water_sample) / maxf(seconds, 0.01), -1.0, 1.0)
	var measured_mood := clampf(
		(mood_now - _last_mood_sample) / maxf(seconds, 0.01),
		-Villager.MOOD_DRIFT * Villager.MOOD_FALL_SCALE,
		Villager.MOOD_DRIFT)
	_water_rate = lerpf(_water_rate, measured_water, 0.15)
	_mood_rate = lerpf(_mood_rate, measured_mood, 0.15)
	_last_water_sample = water_now
	_last_mood_sample = mood_now
	_status_sample_tick = now_tick


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
	var workers := Colony.worker_count()
	var slider_max := maxf(float(workers) + 2.0, 4.0)
	_workers_available.text = L10n.t(&"UI_WORKERS_AVAILABLE", [workers, Colony.population()])
	_job_hint.text = tr(&"UI_JOB_BOARD_HINT")

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
			UiPalette.DANGER if have < want else UiPalette.TEXT_DIM)
