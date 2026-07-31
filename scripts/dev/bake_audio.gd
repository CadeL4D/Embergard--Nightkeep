extends Node
## Rebuild all deterministic Phase 5 SFX as ordinary WAV files.

const OUTPUT_DIR := "res://assets/audio/sfx"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var failed := false
	for id: StringName in AudioData.SFX_IDS:
		var stream := AudioData.make(id)
		var path := "%s/%s.wav" % [OUTPUT_DIR, id]
		var error := stream.save_to_wav(path)
		if error != OK:
			failed = true
			push_error("audio bake failed for %s: %s" % [id, error_string(error)])
	if not failed:
		print("baked %d Phase 5 sound effects" % AudioData.SFX_IDS.size())
	get_tree().quit(1 if failed else 0)
