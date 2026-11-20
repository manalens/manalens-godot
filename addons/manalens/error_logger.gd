extends Logger
## Godot 4.5+ only (the Logger class is new in 4.5). The SDK loads this file
## with `OS.add_logger()` when `capture_engine_errors` is on.
##
## Godot calls `_log_error` from any thread, and also while it handles an
## error. So this logger only copies the error into a list under a Mutex. It
## never calls print, push_error or the SDK. The SDK takes the list on the
## main thread (`take()`) and sends the errors.

const MAX_PENDING := 100
## 0 = ERROR_TYPE_ERROR, 1 = ERROR_TYPE_WARNING, 2 = ERROR_TYPE_SCRIPT, 3 = ERROR_TYPE_SHADER.
const KINDS := ["error", "warning", "script", "shader"]

var capture_warnings := false
var _mutex := Mutex.new()
var _pending: Array = []
var _overflow := 0


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var kind: String = KINDS[error_type] if error_type >= 0 and error_type < KINDS.size() else "error"
	if kind == "shader" or (kind == "warning" and not capture_warnings):
		return
	var message := rationale if rationale != "" else code
	if message.begins_with("Manalens:"):
		return  # The SDK's own warnings: never send them (no loop).
	var item := {"kind": kind, "message": message, "file": file, "line": line, "function": function, "stack": ""}
	# The first script frame is the place in the game code; the C++ place is
	# the engine function that reported the error.
	for backtrace in script_backtraces:
		if backtrace != null and backtrace.get_frame_count() > 0:
			item.file = backtrace.get_frame_file(0)
			item.line = backtrace.get_frame_line(0)
			item.function = backtrace.get_frame_function(0)
			item.stack = backtrace.format()
			break
	_mutex.lock()
	if _pending.size() < MAX_PENDING:
		_pending.append(item)
	else:
		_overflow += 1
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass


## Returns [errors, overflow count] and clears the list. Main thread only.
func take() -> Array:
	_mutex.lock()
	var out := [_pending, _overflow]
	_pending = []
	_overflow = 0
	_mutex.unlock()
	return out
