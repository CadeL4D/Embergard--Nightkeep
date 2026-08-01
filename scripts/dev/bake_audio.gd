extends Node
## Rebuild all deterministic Phase 5 SFX as ordinary WAV files.

const SFX_OUTPUT_DIR := "res://assets/audio/sfx"
const MUSIC_OUTPUT_DIR := "res://assets/audio/music"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SFX_OUTPUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MUSIC_OUTPUT_DIR))
	var failed := false
	for id: StringName in AudioData.SFX_IDS:
		var stream := AudioData.make(id)
		var path := "%s/%s.wav" % [SFX_OUTPUT_DIR, id]
		var error := stream.save_to_wav(path)
		if error != OK:
			failed = true
			push_error("audio bake failed for %s: %s" % [id, error_string(error)])
	for id: StringName in AudioData.MUSIC_IDS:
		var stream := AudioData.make_music(id)
		var path := "%s/%s.wav" % [MUSIC_OUTPUT_DIR, id]
		var error := stream.save_to_wav(path)
		if error != OK:
			failed = true
			push_error("music bake failed for %s: %s" % [id, error_string(error)])
	if not failed:
		print("baked %d sound effects and %d music layers" % [
			AudioData.SFX_IDS.size(), AudioData.MUSIC_IDS.size()])
	get_tree().quit(1 if failed else 0)
