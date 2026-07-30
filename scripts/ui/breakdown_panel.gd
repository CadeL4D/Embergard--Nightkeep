class_name BreakdownPanel
extends PanelContainer
## Tap the resource bar, see the arithmetic.
##
## The NUMBER rows are rebuilt from scratch on each refresh rather than diffed. The term list
## changes shape as conditions come and go — nobody is thirsty, then three people are — and
## reconciling a variable list of rows costs more code than throwing eight labels away twice a
## second.
##
## The ability BUTTONS are not, because a control destroyed and recreated twice a second is a
## control the player cannot reliably press. Hence two containers with two different lifetimes.
##
## Refreshes on a timer, not per frame, and only while visible.

const REFRESH_INTERVAL := 0.5

@onready var _rows: VBoxContainer = $Rows

## Numbers, thrown away and rebuilt twice a second.
var _reports: VBoxContainer = null
## Buttons, rebuilt only when the set of abilities actually changes.
var _abilities: VBoxContainer = null
## Signature of the ability set the buttons were built for.
var _abilities_key: String = ""

var _accum: float = 0.0


func _ready() -> void:
	visible = false
	_reports = VBoxContainer.new()
	_reports.add_theme_constant_override("separation", 1)
	_rows.add_child(_reports)
	_abilities = VBoxContainer.new()
	_abilities.add_theme_constant_override("separation", 1)
	_rows.add_child(_abilities)
	refresh()


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum < REFRESH_INTERVAL:
		return
	_accum = 0.0
	refresh()


func refresh() -> void:
	for child in _reports.get_children():
		_reports.remove_child(child)
		child.queue_free()
	for report in RateLedger.all():
		_add_report(report)
	_sync_abilities()


# --- Reports ------------------------------------------------------------------------------------

func _add_report(report: RateLedger.Report) -> void:
	# Heading: the name and the figure every term below it has to account for.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	_reports.add_child(head)

	var title := _label(report.title, UiPalette.ACCENT, UiTheme.FONT_SIZE)
	title.custom_minimum_size = Vector2(66, 0)
	head.add_child(title)

	var total := _label(report.total_text,
		UiPalette.TEXT if report.healthy else UiPalette.DANGER, UiTheme.FONT_SIZE)
	total.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(total)

	for term in report.terms:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_reports.add_child(row)

		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(10, 0)
		row.add_child(spacer)

		var name_label := _label(term.text(), UiPalette.TEXT_DIM, UiTheme.FONT_SIZE_SMALL)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		# Sign carries the meaning, so it is coloured: a player scanning a breakdown for
		# "what is hurting me" should find it without reading the labels.
		var tint := UiPalette.TEXT_DIM
		if not term.is_factor:
			tint = UiPalette.OK if term.value >= 0.0 else UiPalette.WARN
		elif term.value < 1.0:
			tint = UiPalette.WARN
		var amount := _label(term.amount_text(), tint, UiTheme.FONT_SIZE_SMALL)
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		amount.custom_minimum_size = Vector2(52, 0)
		row.add_child(amount)

	if not report.note.is_empty():
		var note := _label(report.note, UiPalette.TEXT_FAINT, UiTheme.FONT_SIZE_SMALL)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(240, 0)
		_reports.add_child(note)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 5)
	_reports.add_child(gap)


# --- Abilities ----------------------------------------------------------------------------------
#
# Taking up and giving back abilities lives HERE, under the Faith breakdown, rather than in a panel
# of its own.
#
# Because this is already the screen a player is looking at when they ask the only question the
# Burden system poses: my Faith is draining, what do I shed? Putting the controls anywhere else
# would mean reading the arithmetic in one place and acting on it in another, from memory, while
# the buffer runs down.

## Rebuild the buttons only if which abilities are on offer, or which are held, has changed.
## A cheap string signature is enough to tell a real change from a redraw.
func _sync_abilities() -> void:
	var eligible: Array[PowerDef] = []
	for def: PowerDef in Powers.all():
		if Divine.is_taken_up(def.id) or Divine.can_take_up(def):
			eligible.append(def)

	var key := ""
	for def: PowerDef in eligible:
		key += "%s:%d|" % [def.id, 1 if Divine.is_taken_up(def.id) else 0]
	if key == _abilities_key:
		# Same set. Only the affordability of the give-back button can have moved.
		_refresh_ability_buttons()
		return
	_abilities_key = key

	for child in _abilities.get_children():
		_abilities.remove_child(child)
		child.queue_free()
	if eligible.is_empty():
		return

	var head := _label(L10n.t(&"LEDGER_ABILITIES"), UiPalette.ACCENT, UiTheme.FONT_SIZE)
	_abilities.add_child(head)

	for def: PowerDef in eligible:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_abilities.add_child(row)

		var taken := Divine.is_taken_up(def.id)
		var name_label := _label(tr(def.display_name),
			def.color if taken else UiPalette.TEXT_DIM, UiTheme.FONT_SIZE_SMALL)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.custom_minimum_size = Vector2(88, 0)
		row.add_child(name_label)

		# The Burden is stated on the row whether the ability is held or not, so the cost of taking
		# one up is visible BEFORE the decision rather than only after it.
		var burden := _label("%+.2f" % -def.burden,
			UiPalette.WARN if taken else UiPalette.TEXT_FAINT, UiTheme.FONT_SIZE_SMALL)
		burden.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		burden.custom_minimum_size = Vector2(44, 0)
		row.add_child(burden)

		var action := Button.new()
		action.name = "Action_%s" % def.id
		action.custom_minimum_size = Vector2(64, 18)
		action.add_theme_font_size_override("font_size", UiTheme.FONT_SIZE_SMALL)
		if taken:
			action.text = tr(&"UI_GIVE_BACK")
			# Giving an ability back costs Faith, so it cannot be used as a free toggle to dodge a
			# deficit the moment one appears mid-night.
			action.tooltip_text = L10n.t(&"UI_GIVE_BACK_COST", [int(Divine.RELINQUISH_COST)])
			action.pressed.connect(_on_give_back.bind(def.id))
		else:
			action.text = tr(&"UI_TAKE_UP")
			action.add_theme_color_override("font_color", UiPalette.OK)
			action.pressed.connect(_on_take_up.bind(def))
		row.add_child(action)
	_refresh_ability_buttons()


## Affordability only. Cheap enough to run on the timer, and it creates nothing.
func _refresh_ability_buttons() -> void:
	for def: PowerDef in Powers.all():
		var found := _abilities.find_child("Action_%s" % def.id, true, false)
		if found == null or not found is Button:
			continue
		var action := found as Button
		# Take-up is never gated on Faith — its cost is the standing Burden, not a payment. Only
		# giving one back charges the pool, so only that button can be unaffordable.
		action.disabled = Divine.is_taken_up(def.id) \
			and not Divine.can_pay(Divine.RELINQUISH_COST)


func _on_take_up(def: PowerDef) -> void:
	if Divine.take_up(def):
		refresh()


func _on_give_back(id: StringName) -> void:
	if Divine.relinquish(id):
		refresh()


static func _label(text: String, color: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
