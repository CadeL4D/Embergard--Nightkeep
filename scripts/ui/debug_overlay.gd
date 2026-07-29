extends CanvasLayer
## Development HUD: the numbers that tell you whether the sim is healthy, plus the
## controls that let you skip to the part you are working on.
##
## Built at milestone 1 on purpose. Every later system — the flow field, the labour
## reconciler, the wave director — is far easier to debug with a live readout and a
## time-scale control than without, and retrofitting this once there is real content
## means debugging blind for months.
##
## The node tree lives in debug_overlay.tscn; this script only fills in the text and
## keeps the layout inside the display safe area.
##
## Hidden by default and toggled with F3. It occupies the top-left corner, which is
## also where the real HUD's phase clock sits — two overlapping readouts made both
## unreadable, and the player-facing one has to win.

const KEY_HINT := "[R] reseed   [ [ / ] ] speed   [F3] hide"
const REFRESH_INTERVAL := 0.2

@onready var _safe_area: MarginContainer = $SafeArea
@onready var _readout: Label = $SafeArea/Align/Panel/Readout

var _accum: float = 0.0


func _ready() -> void:
	_apply_safe_area()
	get_tree().root.size_changed.connect(_apply_safe_area)


func _apply_safe_area() -> void:
	SafeArea.apply(_safe_area, 6)


func _process(delta: float) -> void:
	if not visible:
		return
	# Refresh at 5 Hz. A per-frame Label update allocates a new string every frame
	# and shows up in the profiler as the debug tool's own cost, which is exactly
	# the noise you do not want while profiling.
	_accum += delta
	if _accum < REFRESH_INTERVAL:
		return
	_accum = 0.0
	_readout.text = _compose()


func _compose() -> String:
	var phase_name: String = ["DAY", "DUSK", "NIGHT", "DAWN"][Sim.phase]
	var blight_pct := 0.0
	var frontier := 0
	if World.blight_field:
		blight_pct = World.blight_field.coverage() * 100.0
		frontier = World.blight_field.frontier_size()

	var queued := World.paths.last_queue_length if World.paths else 0
	var ember_text: String = str(World.grid.coord(Divine.ember_cell)) if Divine.ember_cell != -1 else "-"

	return "\n".join([
		"%d fps   |   seed %d   |   %.2fx speed" % [
			Engine.get_frames_per_second(), World.seed_value, Sim.time_scale
		],
		"Day %d  %s  %ds left   |   tick %d" % [
			Sim.day, phase_name, int(Sim.seconds_remaining()), Sim.tick
		],
		"pop %d   |   agents %d   |   paths queued %d" % [
			Colony.population(), Sim.agents.size(), queued
		],
		"faith %.0f   |   blight %.1f%%  frontier %d   |   ember %s" % [
			Divine.faith, blight_pct, frontier, ember_text
		],
		KEY_HINT,
	])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_overlay"):
		visible = not visible
		get_viewport().set_input_as_handled()
