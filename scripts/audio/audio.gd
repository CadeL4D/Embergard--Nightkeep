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

const POOL_SIZE := 12


func _ready() -> void:
	_ensure_buses()
	load_settings()


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
func play_sfx(id: StringName, pitch_variance: float = 0.08) -> void:
	var stream: AudioStream = _sfx.get(id)
	if stream == null or _pool.is_empty():
		return
	var p := _pool[_pool_cursor]
	_pool_cursor = (_pool_cursor + 1) % _pool.size()
	p.stream = stream
	# A touch of pitch scatter. Twenty identical one-shots in a night wave is the single
	# fastest way to make a soundscape grating.
	p.pitch_scale = 1.0 + randf_range(-pitch_variance, pitch_variance)
	p.play()


## Hook for the procedural music layer. No-ops until that exists, so the phase machine can
## already be wired to it.
func set_music_mood(_phase: int) -> void:
	pass
