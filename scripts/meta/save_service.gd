extends Node
## Three-slot, checksummed save storage. The simulation hands this service an immutable
## dictionary snapshot; serialization, hashing and disk I/O happen on a worker thread.

signal save_completed(sequence: int, duration_ms: float, ok: bool)

const SLOT_COUNT := 3
const SLOT_PREFIX := "user://run_"
const SLOT_SUFFIX := ".dat"
const TEMP_SUFFIX := ".tmp"
const LEGACY_PATH := "user://run.dat"
const LEGACY_TEMP_PATH := "user://run.tmp"
const FILE_MAGIC := "EMBERG1\n"
const CHECKSUM_HEX_BYTES := 64

var _worker := Thread.new()
var _active := false
var _pending: Dictionary = {}
var _next_sequence := 1
var _last_write_ok := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_next_sequence = _highest_sequence_on_disk() + 1


func _process(_delta: float) -> void:
	_reap_worker()


func _exit_tree() -> void:
	flush()


func queue_snapshot(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	_reap_worker()
	# Deep duplication makes the object graph immutable from the worker's point of view.
	# A second request while a write is active replaces the queued request: the newest
	# checkpoint matters, and phase transitions never need a backlog of stale snapshots.
	var snapshot := data.duplicate(true)
	if _active:
		_pending = snapshot
		return true
	return _start_write(snapshot)


func flush() -> bool:
	while _active or not _pending.is_empty():
		if _active:
			_finish_worker()
		if not _pending.is_empty():
			var next := _pending
			_pending = {}
			if not _start_write(next):
				return false
	return _last_write_ok


func has_save() -> bool:
	if _active or not _pending.is_empty() or FileAccess.file_exists(LEGACY_PATH):
		return true
	for i in SLOT_COUNT:
		if FileAccess.file_exists(_slot_path(i)):
			return true
	return false


func clear_all() -> void:
	_pending.clear()
	flush()
	for i in SLOT_COUNT:
		_remove_file(_slot_path(i))
		_remove_file(_temp_path(i))
	_remove_file(LEGACY_PATH)
	_remove_file(LEGACY_TEMP_PATH)
	_next_sequence = 1


## Returns {data, recovered, sequence}. Invalid slots are ignored. If the most
## recently modified slot is damaged, an older valid checkpoint is returned and
## `recovered` tells the run scene to show the player a notice.
func read_latest() -> Dictionary:
	flush()
	var valid: Array[Dictionary] = []
	var newest_invalid_time := 0
	for i in SLOT_COUNT:
		var path := _slot_path(i)
		if not FileAccess.file_exists(path):
			continue
		var row := _read_slot(path)
		if row.is_empty():
			newest_invalid_time = maxi(newest_invalid_time, int(FileAccess.get_modified_time(path)))
		else:
			row["modified"] = int(FileAccess.get_modified_time(path))
			valid.append(row)
	if not valid.is_empty():
		valid.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["sequence"]) > int(b["sequence"])
		)
		var chosen := valid[0]
		return {
			"data": chosen["data"],
			"sequence": int(chosen["sequence"]),
			"recovered": newest_invalid_time >= int(chosen["modified"]),
		}
	return _read_legacy()


func latest_slot_path() -> String:
	## Exposed for deterministic corruption tests and support diagnostics.
	flush()
	var best_sequence := -1
	var best_path := ""
	for i in SLOT_COUNT:
		var path := _slot_path(i)
		var row := _read_slot(path)
		if not row.is_empty() and int(row["sequence"]) > best_sequence:
			best_sequence = int(row["sequence"])
			best_path = path
	return best_path


func _start_write(snapshot: Dictionary) -> bool:
	var sequence := _next_sequence
	_next_sequence += 1
	_worker = Thread.new()
	var error := _worker.start(_write_slot.bind(snapshot, sequence))
	if error != OK:
		push_error("SaveService: could not start save worker (%s)" % error_string(error))
		_last_write_ok = false
		return false
	_active = true
	return true


func _reap_worker() -> void:
	if _active and not _worker.is_alive():
		_finish_worker()
	if not _active and not _pending.is_empty():
		var next := _pending
		_pending = {}
		_start_write(next)


func _finish_worker() -> void:
	if not _active:
		return
	var result: Dictionary = _worker.wait_to_finish()
	_active = false
	_last_write_ok = bool(result.get("ok", false))
	if not _last_write_ok:
		push_error("SaveService: %s" % String(result.get("error", "save failed")))
	save_completed.emit(int(result.get("sequence", 0)),
		float(result.get("duration_ms", 0.0)), _last_write_ok)


func _write_slot(snapshot: Dictionary, sequence: int) -> Dictionary:
	var started := Time.get_ticks_usec()
	var payload := var_to_bytes(snapshot)
	var checksum := _sha256(payload)
	var slot := posmod(sequence - 1, SLOT_COUNT)
	var temp_path := _temp_path(slot)
	var target_path := _slot_path(slot)
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _write_result(sequence, started, false, "cannot open %s" % temp_path)
	# A small fixed header lets validation reject a torn or foreign file without
	# asking Variant decoding to parse arbitrary bytes (which would log engine errors).
	file.store_buffer(FILE_MAGIC.to_ascii_buffer())
	file.store_64(sequence)
	file.store_64(payload.size())
	file.store_buffer(checksum.to_ascii_buffer())
	file.store_buffer(payload)
	file.flush()
	file.close()

	# Rename only after the complete envelope reaches disk. Other slots remain valid
	# throughout, so even a process kill between replace steps leaves recoverable data.
	var dir := DirAccess.open("user://")
	if dir == null:
		return _write_result(sequence, started, false, "cannot open the save directory")
	var target_name := target_path.get_file()
	var temp_name := temp_path.get_file()
	if dir.file_exists(target_name) and dir.remove(target_name) != OK:
		return _write_result(sequence, started, false, "cannot replace %s" % target_name)
	var error := dir.rename(temp_name, target_name)
	if error != OK:
		return _write_result(sequence, started, false, "cannot commit %s: %s" % [
			target_name, error_string(error)])
	return _write_result(sequence, started, true, "")


func _write_result(sequence: int, started_usec: int, ok: bool, error: String) -> Dictionary:
	return {
		"sequence": sequence,
		"duration_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"ok": ok,
		"error": error,
	}


func _read_slot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var minimum_size := FILE_MAGIC.length() + 16 + CHECKSUM_HEX_BYTES + 1
	if file.get_length() < minimum_size:
		file.close()
		return {}
	var magic := file.get_buffer(FILE_MAGIC.length()).get_string_from_ascii()
	if magic != FILE_MAGIC:
		file.close()
		return {}
	var sequence := int(file.get_64())
	var payload_size := int(file.get_64())
	var remaining := file.get_length() - file.get_position()
	if payload_size <= 0 or remaining != CHECKSUM_HEX_BYTES + payload_size:
		file.close()
		return {}
	var expected := file.get_buffer(CHECKSUM_HEX_BYTES).get_string_from_ascii()
	var payload := file.get_buffer(payload_size)
	file.close()
	if payload.size() != payload_size:
		return {}
	var actual := _sha256(payload)
	if expected.is_empty() or not expected.matchn(actual):
		return {}
	var data = bytes_to_var(payload)
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return {"sequence": sequence, "data": data}


func _read_legacy() -> Dictionary:
	if not FileAccess.file_exists(LEGACY_PATH):
		return {}
	var file := FileAccess.open(LEGACY_PATH, FileAccess.READ)
	if file == null:
		return {}
	var data = file.get_var()
	file.close()
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("SaveService: legacy save is not a dictionary")
		return {}
	return {"data": data, "sequence": 0, "recovered": false}


func _highest_sequence_on_disk() -> int:
	var highest := 0
	for i in SLOT_COUNT:
		var row := _read_slot(_slot_path(i))
		if not row.is_empty():
			highest = maxi(highest, int(row["sequence"]))
	return highest


func _sha256(payload: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(payload) != OK:
		return ""
	return context.finish().hex_encode()


func _slot_path(index: int) -> String:
	return "%s%d%s" % [SLOT_PREFIX, index, SLOT_SUFFIX]


func _temp_path(index: int) -> String:
	return "%s%d%s" % [SLOT_PREFIX, index, TEMP_SUFFIX]


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if error != OK:
			push_warning("SaveService: could not remove %s (%s)" % [path, error_string(error)])
