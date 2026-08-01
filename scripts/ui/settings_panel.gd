class_name SettingsPanel
extends VBoxContainer
## Compact tabbed settings surface shared by mouse, keyboard and touch.

var _listening_action: StringName = &""
var _key_buttons: Dictionary = {}
var _text_value: Label
var _hold_value: Label
var _shake_value: Label
var _pages: Array[Control] = []
var _tab_buttons: Array[Button] = []


func _ready() -> void:
	custom_minimum_size = Vector2(350, 224)
	_build()
	set_process_unhandled_key_input(true)


func save() -> void:
	Audio.save_settings()
	Accessibility.save_settings()


func _build() -> void:
	# A small explicit tab row is more predictable than TabContainer's automatic tab
	# scrolling at phone safe-area sizes and at 130% text. All pages occupy the same host.
	var header := HBoxContainer.new()
	header.name = "TabButtons"
	header.add_theme_constant_override("separation", 2)
	add_child(header)
	var group := ButtonGroup.new()
	group.allow_unpress = false
	var page_host := PanelContainer.new()
	page_host.name = "Pages"
	page_host.custom_minimum_size = Vector2(350, 190)
	page_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(page_host)
	_pages.assign([
		_audio_tab(), _gameplay_tab(), _accessibility_tab(), _controls_tab(),
	])
	for index in _pages.size():
		var page := _pages[index]
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		page_host.add_child(page)
		var button := Button.new()
		button.text = String(page.name)
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(78, Accessibility.MIN_UI_TARGET_PX)
		button.add_theme_font_size_override("font_size", 9)
		button.pressed.connect(set_tab.bind(index))
		header.add_child(button)
		_tab_buttons.append(button)
	set_tab(0)


func _gameplay_tab() -> VBoxContainer:
	var rows := VBoxContainer.new()
	rows.name = tr(&"OPTIONS_GAMEPLAY")
	rows.add_theme_constant_override("separation", 8)

	var graphics_row := HBoxContainer.new()
	var graphics_label := Label.new()
	graphics_label.text = tr(&"OPTIONS_GRAPHICS")
	graphics_label.custom_minimum_size.x = 110
	var graphics := OptionButton.new()
	graphics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key: StringName in Accessibility.GRAPHICS_NAMES:
		graphics.add_item(tr(key))
	graphics.select(Accessibility.graphics_mode)
	graphics.item_selected.connect(Accessibility.set_graphics_mode)
	graphics_row.add_child(graphics_label)
	graphics_row.add_child(graphics)
	rows.add_child(graphics_row)

	var hand_row := HBoxContainer.new()
	var hand_label := Label.new()
	hand_label.text = tr(&"OPTIONS_HANDEDNESS")
	hand_label.custom_minimum_size.x = 110
	var hand := OptionButton.new()
	hand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key: StringName in Accessibility.HANDEDNESS_NAMES:
		hand.add_item(tr(key))
	hand.select(Accessibility.handedness)
	hand.item_selected.connect(Accessibility.set_handedness)
	hand_row.add_child(hand_label)
	hand_row.add_child(hand)
	rows.add_child(hand_row)

	var hold_row := HBoxContainer.new()
	var hold_label := Label.new()
	hold_label.text = tr(&"OPTIONS_HOLD_DURATION")
	hold_label.custom_minimum_size.x = 110
	var hold := HSlider.new()
	hold.min_value = 0
	hold.max_value = Accessibility.HOLD_DURATIONS.size() - 1
	hold.step = 1
	hold.value = Accessibility.HOLD_DURATIONS.find(Accessibility.hold_duration)
	hold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hold_value = Label.new()
	_hold_value.custom_minimum_size.x = 46
	_hold_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_refresh_hold_value()
	hold.value_changed.connect(func(value: float) -> void:
		Accessibility.set_hold_duration(Accessibility.HOLD_DURATIONS[int(value)])
		_refresh_hold_value()
	)
	hold_row.add_child(hold_label)
	hold_row.add_child(hold)
	hold_row.add_child(_hold_value)
	rows.add_child(hold_row)

	var note := Label.new()
	note.text = tr(&"OPTIONS_GRAPHICS_NOTE")
	note.add_theme_color_override("font_color", UiPalette.TEXT_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(note)
	return rows


func set_tab(index: int) -> void:
	if _pages.is_empty():
		return
	var selected := clampi(index, 0, _pages.size() - 1)
	for page_index in _pages.size():
		_pages[page_index].visible = page_index == selected
		_tab_buttons[page_index].set_pressed_no_signal(page_index == selected)


func _audio_tab() -> VBoxContainer:
	var rows := VBoxContainer.new()
	rows.name = tr(&"OPTIONS_AUDIO")
	rows.add_theme_constant_override("separation", 8)
	for bus: StringName in [Audio.BUS_MASTER, Audio.BUS_MUSIC, Audio.BUS_SFX, Audio.BUS_UI]:
		var label_key: StringName = {
			Audio.BUS_MASTER: &"UI_MASTER",
			Audio.BUS_MUSIC: &"UI_MUSIC",
			Audio.BUS_SFX: &"UI_SOUND",
			Audio.BUS_UI: &"UI_INTERFACE",
		}[bus]
		rows.add_child(_slider_row(label_key, Audio.get_volume(bus), 0.0, 1.0, 0.05,
			func(value: float) -> void: Audio.set_volume(bus, value)))
	var note := Label.new()
	note.text = tr(&"AUDIO_COMPLETE_NOTE")
	note.add_theme_color_override("font_color", UiPalette.TEXT_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(note)
	return rows


func _accessibility_tab() -> VBoxContainer:
	var outer := VBoxContainer.new()
	outer.name = tr(&"OPTIONS_ACCESS_TAB")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 174
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)
	var palette_row := HBoxContainer.new()
	var palette_label := Label.new()
	palette_label.text = tr(&"ACCESS_PALETTE")
	palette_label.custom_minimum_size.x = 110
	var palette := OptionButton.new()
	palette.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key: StringName in Accessibility.PALETTE_NAMES:
		palette.add_item(tr(key))
	palette.select(Accessibility.palette_mode)
	palette.item_selected.connect(Accessibility.set_palette_mode)
	palette_row.add_child(palette_label)
	palette_row.add_child(palette)
	rows.add_child(palette_row)

	var text_row := HBoxContainer.new()
	var text_label := Label.new()
	text_label.text = tr(&"ACCESS_TEXT_SIZE")
	text_label.custom_minimum_size.x = 110
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = Accessibility.TEXT_SCALES.size() - 1
	slider.step = 1
	slider.value = Accessibility.TEXT_SCALES.find(Accessibility.text_scale)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_value = Label.new()
	_text_value.custom_minimum_size.x = 42
	_text_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_refresh_text_value()
	slider.value_changed.connect(func(value: float) -> void:
		Accessibility.set_text_scale(Accessibility.TEXT_SCALES[int(value)])
		_refresh_text_value()
	)
	text_row.add_child(text_label)
	text_row.add_child(slider)
	text_row.add_child(_text_value)
	rows.add_child(text_row)

	var shake_row := HBoxContainer.new()
	var shake_label := Label.new()
	shake_label.text = tr(&"ACCESS_SCREEN_SHAKE")
	shake_label.custom_minimum_size.x = 110
	var shake := HSlider.new()
	shake.min_value = 0
	shake.max_value = Accessibility.SCREEN_SHAKE_LEVELS.size() - 1
	shake.step = 1
	shake.value = Accessibility.SCREEN_SHAKE_LEVELS.find(Accessibility.screen_shake_strength)
	shake.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shake_value = Label.new()
	_shake_value.custom_minimum_size.x = 42
	_shake_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_refresh_shake_value()
	shake.value_changed.connect(func(value: float) -> void:
		Accessibility.set_screen_shake_strength(Accessibility.SCREEN_SHAKE_LEVELS[int(value)])
		_refresh_shake_value()
	)
	shake_row.add_child(shake_label)
	shake_row.add_child(shake)
	shake_row.add_child(_shake_value)
	rows.add_child(shake_row)

	rows.add_child(_check(&"ACCESS_REDUCED_MOTION", Accessibility.reduced_motion,
		Accessibility.set_reduced_motion))
	rows.add_child(_check(&"ACCESS_HAPTICS", Accessibility.haptics,
		Accessibility.set_haptics))
	rows.add_child(_check(&"ACCESS_TUTORIALS", Accessibility.tutorials_enabled,
		Accessibility.set_tutorials_enabled))
	rows.add_child(_check(&"ACCESS_HIGH_VISIBILITY_TARGETS",
		Accessibility.high_visibility_targets, Accessibility.set_high_visibility_targets))
	rows.add_child(_check(&"ACCESS_PAUSE_WHILE_MANAGING",
		Accessibility.pause_while_managing, Accessibility.set_pause_while_managing))
	var diagnostics := _check(&"ACCESS_DIAGNOSTICS_OPT_IN",
		Accessibility.diagnostics_export_opt_in, Accessibility.set_diagnostics_export_opt_in)
	rows.add_child(diagnostics)
	var export := Button.new()
	export.text = tr(&"ACCESS_EXPORT_DIAGNOSTICS")
	export.disabled = not Accessibility.diagnostics_export_opt_in
	diagnostics.toggled.connect(func(enabled: bool) -> void: export.disabled = not enabled)
	export.pressed.connect(func() -> void:
		if Diagnostics.export_bundle():
			export.text = tr(&"ACCESS_DIAGNOSTICS_EXPORTED")
	)
	rows.add_child(export)
	var reset := Button.new()
	reset.text = tr(&"ACCESS_RESET_TUTORIALS")
	reset.pressed.connect(func() -> void:
		Accessibility.reset_tutorials()
		reset.text = tr(&"ACCESS_TUTORIALS_RESET")
	)
	rows.add_child(reset)
	return outer


func _controls_tab() -> VBoxContainer:
	var outer := VBoxContainer.new()
	outer.name = tr(&"OPTIONS_CONTROLS")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 174
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for action: StringName in Accessibility.ACTION_DEFAULTS:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = tr(Accessibility.ACTION_LABELS[action])
		label.custom_minimum_size.x = 190
		var button := Button.new()
		button.custom_minimum_size.x = 110
		button.text = OS.get_keycode_string(Accessibility.action_key(action))
		button.pressed.connect(_listen_for_key.bind(action))
		row.add_child(label)
		row.add_child(button)
		rows.add_child(row)
		_key_buttons[action] = button
	scroll.add_child(rows)
	outer.add_child(scroll)
	var reset := Button.new()
	reset.text = tr(&"CONTROL_RESET")
	reset.pressed.connect(func() -> void:
		Accessibility.reset_controls()
		_refresh_keys()
	)
	outer.add_child(reset)
	return outer


func _slider_row(label_key: StringName, value: float, minimum: float, maximum: float,
		step: float, callback: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = tr(label_key)
	label.custom_minimum_size.x = 90
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(callback)
	row.add_child(label)
	row.add_child(slider)
	return row


func _check(label_key: StringName, pressed: bool, callback: Callable) -> CheckBox:
	var box := CheckBox.new()
	box.text = tr(label_key)
	box.button_pressed = pressed
	box.toggled.connect(callback)
	return box


func _listen_for_key(action: StringName) -> void:
	_listening_action = action
	var button: Button = _key_buttons[action]
	button.text = tr(&"CONTROL_PRESS_KEY")
	button.grab_focus()


func _unhandled_key_input(event: InputEvent) -> void:
	if _listening_action == &"" or not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var code := int(key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode)
	if code == KEY_ESCAPE:
		_listening_action = &""
		_refresh_keys()
		return
	Accessibility.remap_action(_listening_action, code)
	_listening_action = &""
	_refresh_keys()
	get_viewport().set_input_as_handled()


func _refresh_keys() -> void:
	for action: StringName in _key_buttons:
		var button: Button = _key_buttons[action]
		button.text = OS.get_keycode_string(Accessibility.action_key(action))


func _refresh_text_value() -> void:
	if _text_value != null:
		_text_value.text = "%d%%" % roundi(Accessibility.text_scale * 100.0)


func _refresh_hold_value() -> void:
	if _hold_value != null:
		_hold_value.text = "%.2fs" % Accessibility.hold_duration


func _refresh_shake_value() -> void:
	if _shake_value != null:
		_shake_value.text = "%d%%" % roundi(Accessibility.screen_shake_strength * 100.0)
