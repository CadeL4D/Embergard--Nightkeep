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
var _music_playback: AudioStreamGeneratorPlayback
var _music_time: float = 0.0
var _drone_phase: float = 0.0
var _fifth_phase: float = 0.0
var _melody_phase: float = 0.0
var _night_blend: float = 0.0
var _target_night_blend: float = 0.0
var _blight_blend: float = 0.0
var _target_blight_blend: float = 0.0
var _blight_phase: float = 0.0
var _mood_sample_accum: float = 0.0
var _resource_amounts: Dictionary = {}
var _last_resource_sound_ms: int = 0

const POOL_SIZE := 12
const MUSIC_RATE := 22050.0
const MUSIC_BUFFER := 0.55
const MUSIC_ROOT := 146.832


func _ready() -> void:
	_ensure_buses()
	load_settings()
	_register_catalog()
	_build_music()
	_wire_events()
	set_process(true)


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
	Accessibility.pulse(12, 0.32)


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
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "ProceduralMusic"
	_music_player.bus = BUS_MUSIC
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MUSIC_RATE
	generator.buffer_length = MUSIC_BUFFER
	_music_player.stream = generator
	add_child(_music_player)
	_music_player.play()
	_music_playback = _music_player.get_stream_playback() as AudioStreamGeneratorPlayback


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
	Events.monster_attacked.connect(func(_monster: Node, _target: Node) -> void:
		play_sfx(&"monster_attack", 0.13)
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
	if _music_playback == null:
		return
	var frames := mini(_music_playback.get_frames_available(), 4096)
	for _i in frames:
		_music_playback.push_frame(_music_frame())


## Infinite modal score: Dorian by day, Aeolian at night, with a constant root/fifth drone.
## There is no song boundary to become repetitive during a long world and no per-frame allocation.
func _music_frame() -> Vector2:
	var dt := 1.0 / MUSIC_RATE
	_music_time += dt
	var root := MUSIC_ROOT * lerpf(1.0, 0.5, _night_blend)
	_drone_phase = fmod(_drone_phase + TAU * root * dt, TAU)
	_fifth_phase = fmod(_fifth_phase + TAU * root * 1.4983 * dt, TAU)
	var step := int(_music_time / 1.45)
	var day_scale := [0, 2, 3, 5, 7, 9, 10]
	var night_scale := [0, 2, 3, 5, 7, 8, 10]
	var index := absi(step * 17 + 11) % day_scale.size()
	var semitone := lerpf(float(day_scale[index]), float(night_scale[index]), _night_blend)
	var melody_hz := root * 2.0 * pow(2.0, semitone / 12.0)
	_melody_phase = fmod(_melody_phase + TAU * melody_hz * dt, TAU)
	_blight_phase = fmod(_blight_phase + TAU * root * 0.503 * dt, TAU)
	var local := fmod(_music_time, 1.45)
	var envelope := exp(-local * 2.4) * (0.45 if step % 3 != 1 else 0.0)
	var drone := sin(_drone_phase) * 0.045 + sin(_fifth_phase) * 0.024
	var melody := sin(_melody_phase) * envelope * 0.026
	var breath := sin(_music_time * TAU / 12.0) * 0.006
	# A slow detuned layer makes Blight territory audible before the player opens an overlay.
	var corruption := (sin(_blight_phase) * 0.018 \
		+ sin(_blight_phase * 1.059) * 0.012) * _blight_blend
	var sample := drone + melody + breath + corruption
	return Vector2(sample, sample * 0.96)
