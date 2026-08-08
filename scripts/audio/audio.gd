extends Node
## Autoload: the audio bus layout, volume settings, and the one entry point every
## sound in the game goes through.
##
## Ships BEFORE any actual sound exists, on purpose. `play_sfx()` no-ops on an unknown id,
## so call sites can be added as features are built — the alternative is retrofitting
## emit-points across twenty files later, which is how games end up half-scored.
##
## Buses are created in code rather than shipped as a default_bus_layout.tres because the
## layout is four plain buses with no effects; a binary resource for that is a file nobody
## can review in a diff.

const BUS_MASTER := &"Master"
const BUS_MUSIC := &"Music"
const BUS_SFX := &"SFX"
const BUS_UI := &"UI"

## Volumes are stored 0-1 and converted to dB on the way to the mixer. Players think in
## percentages; AudioServer thinks in decibels, and exposing dB in a settings screen is
## how you get a slider where the bottom 80% does nothing.
const MIN_DB := -40.0

var _volumes: Dictionary = {
	BUS_MASTER: 0.9,
	BUS_MUSIC: 0.6,
	BUS_SFX: 0.85,
	BUS_UI: 0.8,
}

## Registered one-shot streams, id -> AudioStream. Populated once baked SFX exist.
var _sfx: Dictionary = {}
## Round-robin pool so overlapping one-shots do not cut each other off. A single player
## would make a wave of ten monsters dying sound like one monster dying.
var _pool: Array[AudioStreamPlayer] = []
var _pool_cursor: int = 0
var _music_player: AudioStreamPlayer
var _music_players: Dictionary = {}
var _night_blend: float = 0.0
var _target_night_blend: float = 0.0
var _blight_blend: float = 0.0
var _target_blight_blend: float = 0.0
var _mood_sample_accum: float = 0.0
var _resource_amounts: Dictionary = {}
var _last_resource_sound_ms: int = 0

const POOL_SIZE := 12
func _ready() -> void:
	_ensure_buses()
	load_settings()
	_register_catalog()
	_build_music()
	_wire_events()
	set_process(true)


func _exit_tree() -> void:
	# Release playback references explicitly. Mobile operating systems can tear an
	# app down while audio is active, and leaving stream references alive beyond
	# their players produces noisy shutdown diagnostics in the same code path.
	for player: AudioStreamPlayer in _music_players.values():
		player.stop()
		player.stream = null
	_music_players.clear()
	_music_player = null
	for player: AudioStreamPlayer in _pool:
		player.stop()
		player.stream = null
	_pool.clear()
	_sfx.clear()


# --- Buses -----------------------------------------------------------------------------

func _ensure_buses() -> void:
	for bus in [BUS_MUSIC, BUS_SFX, BUS_UI]:
		if AudioServer.get_bus_index(bus) != -1:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus)
		AudioServer.set_bus_send(idx, BUS_MASTER)

	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		add_child(p)
		p.finished.connect(_on_one_shot_finished.bind(p))
		_pool.append(p)


# --- Volume ----------------------------------------------------------------------------

## Linear 0-1, as a settings slider wants it.
func get_volume(bus: StringName) -> float:
	return float(_volumes.get(bus, 1.0))


func set_volume(bus: StringName, linear: float) -> void:
	var v := clampf(linear, 0.0, 1.0)
	_volumes[bus] = v
	var idx := AudioServer.get_bus_index(bus)
	if idx == -1:
		return
	# Silence is a real mute, not -40 dB. Without this the quietest slider position still
	# leaks audible sound, which reads as a broken setting.
	AudioServer.set_bus_mute(idx, is_zero_approx(v))
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))


func _apply_all_volumes() -> void:
	for bus: StringName in _volumes:
		set_volume(bus, _volumes[bus])


# --- Persistence -----------------------------------------------------------------------
# Stored alongside the profile rather than with the run: audio is a preference, and losing
# it because a run ended would be infuriating.

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(Meta.SAVE_PATH) == OK:
		for bus: StringName in _volumes.keys():
			_volumes[bus] = float(cfg.get_value("audio", String(bus), _volumes[bus]))
	_apply_all_volumes()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	# Load-then-write: this file is shared with the profile, and clobbering it would cost
	# the player every shard they have earned.
	cfg.load(Meta.SAVE_PATH)
	for bus: StringName in _volumes:
		cfg.set_value("audio", String(bus), _volumes[bus])
	cfg.save(Meta.SAVE_PATH)


# --- Playback --------------------------------------------------------------------------

## Register a stream against an id. Called by the audio bake step once it exists.
func register_sfx(id: StringName, stream: AudioStream) -> void:
	if stream != null:
		_sfx[id] = stream


## Fire a one-shot. Unknown ids are silently ignored — that is what lets call sites be
## written before the sound design lands.
func play_sfx(id: StringName, pitch_variance: float = 0.08,
		bus: StringName = BUS_SFX) -> void:
	# Headless acceptance runs have no audio device to consume one-shot playback. Starting a WAV
	# there can leave its AudioStreamPlayback alive on the mixer thread when the test process exits,
	# producing a false ObjectDB/resource leak even though the player node was freed correctly.
	if DisplayServer.get_name() == "headless":
		return
	var stream: AudioStream = _sfx.get(id)
	if stream == null or _pool.is_empty():
		return
	var p := _pool[_pool_cursor]
	_pool_cursor = (_pool_cursor + 1) % _pool.size()
	p.stream = stream
	p.bus = bus
	# A touch of pitch scatter. Twenty identical one-shots in a night wave is the single
	# fastest way to make a soundscape grating.
	p.pitch_scale = 1.0 + randf_range(-pitch_variance, pitch_variance)
	p.play()


func _on_one_shot_finished(player: AudioStreamPlayer) -> void:
	# A pooled player only needs its stream while it is playing. Releasing it immediately keeps
	# teardown deterministic on mobile suspension as well as ordinary desktop shutdown.
	if player != null and not player.playing:
		player.stream = null


## Hook for the procedural music layer. No-ops until that exists, so the phase machine can
## already be wired to it.
func set_music_mood(phase: int) -> void:
	_target_night_blend = 1.0 if phase == Sim.Phase.NIGHT else (
		0.58 if phase == Sim.Phase.DUSK else 0.22 if phase == Sim.Phase.DAWN else 0.0)


func _register_catalog() -> void:
	for id: StringName in AudioData.SFX_IDS:
		var path := "res://assets/audio/sfx/%s.wav" % id
		var stream := load(path) as AudioStream
		if stream != null:
			register_sfx(id, stream)


func _build_music() -> void:
	# Headless verification has no audio device and therefore cannot drain active WAV playback
	# before engine shutdown. Music is presentation-only, so avoid loading or starting the three
	# layers in that environment; desktop and mobile builds still use the authored mix below.
	if DisplayServer.get_name() == "headless":
		return
	# Keep all three WAVs synchronized and cross-fade their player volumes.  This
	# avoids AudioStreamGenerator on iOS and removes all sample synthesis from the
	# main thread while retaining the layered day/night/Blight score.
	for id: StringName in AudioData.MUSIC_IDS:
		var stream := load("res://assets/audio/music/%s.wav" % id) as AudioStream
		if stream == null:
			push_warning("Audio: missing baked music layer %s" % id)
			continue
		var player := AudioStreamPlayer.new()
		player.name = "Music%s" % String(id).capitalize()
		player.bus = BUS_MUSIC
		player.stream = stream
		player.volume_db = -80.0
		add_child(player)
		_music_players[id] = player
		player.play()
	_music_player = _music_players.get(&"day") as AudioStreamPlayer
	_apply_music_mix()
	print("Audio: %d baked music layers started" % _music_players.size())


func _wire_events() -> void:
	Events.phase_changed.connect(func(phase: int, _duration: float) -> void:
		set_music_mood(phase)
		if phase == Sim.Phase.DAWN:
			play_sfx(&"dawn", 0.01)
	)
	Events.building_placed.connect(func(_building: Node) -> void:
		play_sfx(&"build_place", 0.05)
	)
	Events.building_completed.connect(func(_building: Node) -> void:
		play_sfx(&"build_complete", 0.04)
	)
	Events.resources_changed.connect(_on_resource_changed)
	Events.power_cast.connect(func(_id: StringName, _pos: Vector2) -> void:
		play_sfx(&"power_cast", 0.04)
	)
	Events.hand_action.connect(func(action: StringName, _pos: Vector2) -> void:
		play_sfx(&"hand_lift" if action == &"lift" else &"hand_drop", 0.025)
	)
	Events.tower_fired.connect(func(_tower: Node, _damage: float, _pos: Vector2) -> void:
		play_sfx(&"tower_fire", 0.11)
	)
	Events.monster_attacked.connect(func(_monster: Node, target: Node) -> void:
		play_sfx(&"monster_attack", 0.13)
		# Combat is the only event important enough to interrupt the player's hand.
		# Keeping haptics here (rather than in generic SFX playback) prevents buttons,
		# production ticks and ambient sounds from buzzing the device.
		if target is Villager:
			Accessibility.pulse(28, 0.72)
	)
	Events.production_completed.connect(func(_building: Node, _kind: StringName,
			_amount: int) -> void: play_sfx(&"production", 0.06))
	Events.building_repaired.connect(func(_building: Node, _amount: float) -> void:
		play_sfx(&"repair", 0.08)
	)
	Events.villager_injured.connect(func(_villager: Node, _amount: float) -> void:
		play_sfx(&"injury", 0.1)
	)
	Events.villager_treated.connect(func(_villager: Node) -> void:
		play_sfx(&"heal", 0.035)
	)
	Events.trade_route_updated.connect(func(_route_id: int, status: StringName) -> void:
		if status == &"in_transit":
			play_sfx(&"route_depart", 0.025)
		elif status == &"arrived":
			play_sfx(&"route_arrive", 0.025)
		elif status == &"lost":
			play_sfx(&"route_lost", 0.025)
	)
	Events.climate_changed.connect(func(_season: StringName, weather: StringName,
			severity: float) -> void:
		if weather == &"storm" and severity >= 0.35:
			play_sfx(&"weather_storm", 0.02)
	)
	Events.monster_spawned.connect(func(monster: Node) -> void:
		if monster is Monster and monster.def != null and monster.def.is_boss:
			play_sfx(&"boss", 0.015)
	)
	Events.wave_incoming.connect(func(_size: int, _composition: Dictionary) -> void:
		play_sfx(&"wave", 0.025)
	)
	Events.monster_died.connect(func(_monster: Node) -> void:
		play_sfx(&"monster_die", 0.12)
	)
	Events.villager_died.connect(func(_villager: Node, _cause: StringName) -> void:
		play_sfx(&"villager_die", 0.035)
	)
	Events.tome_written.connect(func(_tier: int) -> void:
		play_sfx(&"tome_written", 0.025)
	)
	Events.notice.connect(func(_text: String, urgency: int) -> void:
		if urgency >= 2:
			play_sfx(&"warning", 0.02)
	)
	get_tree().node_added.connect(_on_node_added)
	for child in get_tree().root.find_children("*", "BaseButton", true, false):
		_connect_button(child as BaseButton)


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_connect_button(node as BaseButton)


func _connect_button(button: BaseButton) -> void:
	if button.has_meta("audio_connected"):
		return
	button.set_meta("audio_connected", true)
	button.pressed.connect(func() -> void:
		var back_like := button.name.contains("Back") or button.name.contains("Cancel") \
			or button.name.contains("Close")
		play_sfx(&"ui_back" if back_like else &"ui_press", 0.025, BUS_UI)
	)


func _on_resource_changed(kind: StringName, amount: int) -> void:
	var previous := int(_resource_amounts.get(kind, amount))
	_resource_amounts[kind] = amount
	var now := Time.get_ticks_msec()
	if amount > previous and now - _last_resource_sound_ms > 140:
		_last_resource_sound_ms = now
		play_sfx(&"resource_drop", 0.08)


func _process(delta: float) -> void:
	_night_blend = move_toward(_night_blend, _target_night_blend, delta * 0.22)
	_blight_blend = move_toward(_blight_blend, _target_blight_blend, delta * 0.12)
	_mood_sample_accum += delta
	if _mood_sample_accum >= 0.75:
		_mood_sample_accum = 0.0
		_target_blight_blend = clampf(
			World.blight_field.coverage() * 1.7 if World.blight_field != null else 0.0,
			0.0, 1.0)
	_apply_music_mix()


func _apply_music_mix() -> void:
	_set_layer_gain(&"day", 1.0 - _night_blend)
	_set_layer_gain(&"night", _night_blend)
	_set_layer_gain(&"blight", _blight_blend * 0.82)


func _set_layer_gain(id: StringName, gain: float) -> void:
	var player := _music_players.get(id) as AudioStreamPlayer
	if player != null:
		player.volume_db = linear_to_db(maxf(gain, 0.0001)) if gain > 0.0 else -80.0
