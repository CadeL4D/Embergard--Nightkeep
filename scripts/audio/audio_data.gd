class_name AudioData
extends RefCounted
## Deterministic one-shot synthesis used by bake_audio.gd.
##
## The shipped game loads ordinary WAV files; synthesis happens only during the bake so mobile
## playback is cheap, predictable and cannot underrun during a crowded night.

const RATE := 22050
const SFX_IDS: Array[StringName] = [
	&"ui_press", &"ui_back", &"build_place", &"build_complete", &"resource_drop",
	&"power_cast", &"warning", &"wave", &"monster_die", &"villager_die",
	&"tome_written", &"dawn",
	&"tower_fire", &"monster_attack", &"production", &"injury", &"hand_lift",
	&"hand_drop", &"route_depart", &"route_arrive", &"route_lost", &"weather_storm",
	&"boss", &"repair", &"heal",
]

const SPECS := {
	&"ui_press": [0.070, 620.0, 460.0, 0.05, 0.0],
	&"ui_back": [0.090, 360.0, 250.0, 0.04, 0.0],
	&"build_place": [0.145, 125.0, 72.0, 0.08, 0.25],
	&"build_complete": [0.360, 330.0, 660.0, 0.12, 0.02],
	&"resource_drop": [0.105, 240.0, 190.0, 0.06, 0.12],
	&"power_cast": [0.520, 180.0, 760.0, 0.16, 0.08],
	&"warning": [0.480, 210.0, 165.0, 0.16, 0.04],
	&"wave": [0.720, 95.0, 55.0, 0.18, 0.22],
	&"monster_die": [0.280, 150.0, 48.0, 0.12, 0.35],
	&"villager_die": [0.520, 310.0, 105.0, 0.13, 0.08],
	&"tome_written": [0.650, 440.0, 880.0, 0.11, 0.015],
	&"dawn": [1.150, 220.0, 440.0, 0.12, 0.01],
	&"tower_fire": [0.175, 520.0, 150.0, 0.11, 0.09],
	&"monster_attack": [0.210, 135.0, 82.0, 0.1, 0.22],
	&"production": [0.190, 260.0, 390.0, 0.07, 0.04],
	&"injury": [0.155, 310.0, 120.0, 0.09, 0.16],
	&"hand_lift": [0.280, 190.0, 570.0, 0.1, 0.03],
	&"hand_drop": [0.250, 520.0, 170.0, 0.1, 0.06],
	&"route_depart": [0.480, 294.0, 440.0, 0.09, 0.025],
	&"route_arrive": [0.560, 392.0, 784.0, 0.1, 0.015],
	&"route_lost": [0.650, 220.0, 92.0, 0.12, 0.08],
	&"weather_storm": [0.950, 92.0, 45.0, 0.11, 0.4],
	&"boss": [1.050, 82.0, 55.0, 0.17, 0.18],
	&"repair": [0.180, 420.0, 230.0, 0.07, 0.1],
	&"heal": [0.360, 350.0, 620.0, 0.08, 0.015],
}


static func make(id: StringName) -> AudioStreamWAV:
	var spec: Array = SPECS.get(id, [0.1, 220.0, 220.0, 0.1, 0.0])
	var duration := float(spec[0])
	var start_hz := float(spec[1])
	var end_hz := float(spec[2])
	var gain := float(spec[3])
	var noise_amount := float(spec[4])
	var frames := maxi(1, roundi(duration * RATE))
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)
	var phase := 0.0
	var noise_state := absi(String(id).hash()) | 1
	for i in frames:
		var progress := float(i) / float(frames)
		var frequency := lerpf(start_hz, end_hz, progress)
		phase += TAU * frequency / RATE
		noise_state = int((noise_state * 1103515245 + 12345) & 0x7fffffff)
		var noise := float(noise_state % 65536) / 32767.5 - 1.0
		var attack := minf(progress / 0.045, 1.0)
		var decay := pow(1.0 - progress, 2.1)
		var body := sin(phase) + sin(phase * 2.01) * 0.22 + sin(phase * 0.5) * 0.12
		if id in [&"warning", &"wave"]:
			body *= 0.68 + sin(progress * TAU * (5.0 if id == &"warning" else 2.0)) * 0.32
		elif id in [&"build_complete", &"tome_written", &"dawn"]:
			var harmony := 1.5 if id != &"dawn" else 1.3348
			body += sin(phase * harmony) * 0.45
		var sample := clampf((body * (1.0 - noise_amount) + noise * noise_amount)
			* attack * decay * gain, -0.95, 0.95)
		var pcm := int(sample * 32767.0)
		bytes[i * 2] = pcm & 0xff
		bytes[i * 2 + 1] = (pcm >> 8) & 0xff
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	return stream
