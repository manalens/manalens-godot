extends Node
## Untitled Analytics for Godot 4 (autoload singleton `UntitledAnalytics`).
##
## Sends game events to `POST /v0/events` with the public project write key,
## the same envelope as the Untitled Analytics web SDK, and `context.app` in
## place of `context.page`.
##
##   UntitledAnalytics.init({
##       "write_key": "ua_...",
##       "endpoint": "https://collector.example.com",
##       "app_version": "1.4.0", "build": "571", "storefront": "steam",
##   })
##   UntitledAnalytics.track("level_complete", {"level": 3, "score": 1200})
##
## Identity: a persistent anonymous UUID in `user://untitled_analytics.cfg`.
## Sessions rotate after 30 minutes without focus or events. `game_open`,
## `session_start` and `session_end` are automatic. Events are batched, kept in
## an offline file queue (`user://untitled_analytics_queue.json`, at most 1000
## events and 7 days), and retried with backoff.
##
## Errors: `track_error()` sends an `error` event. On Godot 4.5+ the SDK also
## sends engine and script errors (`capture_engine_errors`). When the last run
## ended without a normal exit (a crash or a killed process), the next launch
## sends `app_unclean_exit` in that old session.

signal flushed(sent: int, ok: bool)

const LIBRARY_NAME := "Untitled Analytics Godot SDK"
const LIBRARY_VERSION := "0.1.0"
const CONFIG_PATH := "user://untitled_analytics.cfg"
const QUEUE_PATH := "user://untitled_analytics_queue.json"
const SESSION_TIMEOUT_S := 30.0 * 60.0
## The collector accepts app events up to 7 days old. Keep a margin for clock skew.
const MAX_EVENT_AGE_S := 7.0 * 24.0 * 3600.0 - 3600.0
const MAX_BACKOFF_S := 300.0
const STOREFRONTS := ["steam", "itch", "epic", "gog", "app_store", "play", "other"]
const SEVERITIES := ["debug", "info", "warning", "error", "critical"]
const ERROR_LOGGER_PATH := "res://addons/untitled_analytics/error_logger.gd"
## Error limits (as Sentry Godot): the same fingerprint at most once a second,
## at most 20 errors in 10 seconds, at most 5 automatic errors in one frame.
const ERROR_DEDUPE_MS := 1000
const ERROR_WINDOW_MS := 10000
const ERROR_WINDOW_MAX := 20
const AUTO_ERRORS_PER_FRAME := 5
const BREADCRUMBS := 20
## The collector keeps string properties up to 1024 characters.
const MAX_STRING := 1024

var _options := {
	"write_key": "",
	"endpoint": "",
	"app_version": "",
	"build": "",
	"storefront": "",
	## true: no events and no persistent ID until set_consent(true).
	"consent_required": false,
	"flush_interval_s": 10.0,
	## Flush when this many events are queued; also the batch size (collector max 50).
	"flush_at": 20,
	"max_queue": 1000,
	## true: the SDK delays the window close to send session_end and flush.
	"handle_quit": true,
	"quit_timeout_s": 2.0,
	## Godot 4.5+: send engine and script errors as `error` events.
	"capture_engine_errors": true,
	## Also send engine warnings (off: they are often noisy).
	"capture_warnings": false,
	## Automatic errors in one session; track_error() calls do not count.
	"max_auto_errors_per_session": 50,
	"debug": false,
}
var _initialized := false
var _identity_active := false
var _cfg := ConfigFile.new()
var _queue: Array = []  # [{ "at": unix seconds, "event": envelope }]
var _queue_dirty := false
var _anonymous_id := ""
var _user_id := ""
var _session_id := ""
var _session_started_at := 0.0
var _last_activity_at := 0.0
var _focused := true
var _sending := false
var _in_flight: Array = []  # message IDs of the batch being sent
var _failures := 0
var _backoff_until := 0.0
var _deferred_identify = null  # [user_id, traits] before consent
var _http: HTTPRequest
var _timer: Timer
var _label_re := RegEx.create_from_string("^[A-Za-z0-9._+\\- ]+$")
var _closing := false
var _before_send := Callable()
var _breadcrumbs: Array = []  # the last event names, oldest first
var _error_seen := {}  # fingerprint -> ticks (ms) of the last send
var _error_times: Array = []  # ticks (ms) of the errors sent in the last 10 s
var _auto_errors := 0  # automatic errors sent in this session
var _errors_dropped := 0  # errors the limits dropped in this session
var _error_logger = null  # error_logger.gd instance (Godot 4.5+)
var _number_re := RegEx.create_from_string("0x[0-9A-Fa-f]+|\\d+")
var _quoted_re := RegEx.create_from_string("\"[^\"]*\"|'[^']*'")


# Public API ------------------------------------------------------------------

## Start the SDK. Keys: write_key, endpoint (required); app_version, build,
## storefront, consent_required, flush_interval_s, flush_at, max_queue,
## handle_quit, quit_timeout_s, capture_engine_errors, capture_warnings,
## max_auto_errors_per_session, debug.
func init(options: Dictionary) -> void:
	if _initialized:
		push_warning("UntitledAnalytics: init() was already called")
		return
	for key in options:
		if _options.has(key):
			_options[key] = options[key]
		else:
			push_warning("UntitledAnalytics: unknown option %s" % key)
	if String(_options.write_key) == "" or String(_options.endpoint) == "":
		push_error("UntitledAnalytics: write_key and endpoint are required")
		return
	_options.flush_at = clampi(int(_options.flush_at), 1, 50)
	_options.max_queue = maxi(int(_options.max_queue), int(_options.flush_at))
	_check_label("app_version", 32)
	_check_label("build", 64)
	if String(_options.storefront) != "" and not STOREFRONTS.has(String(_options.storefront)):
		push_warning("UntitledAnalytics: storefront must be one of %s; ignored" % [STOREFRONTS])
		_options.storefront = ""
	_initialized = true
	_cfg.load(CONFIG_PATH)  # A missing file is fine.
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_timer = Timer.new()
	_timer.wait_time = maxf(float(_options.flush_interval_s), 1.0)
	_timer.autostart = true
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	if _options.handle_quit:
		get_tree().set_auto_accept_quit(false)
	if _options.capture_engine_errors:
		_install_error_logger()
	if _identity_allowed():
		_start_identity()


## Record a named event with scalar properties (String, int, float, bool, null).
func track(event: String, properties: Dictionary = {}) -> void:
	if not _ready_to_record():
		return
	if event.length() < 1 or event.length() > 128:
		push_warning("UntitledAnalytics: event name must be 1 to 128 characters")
		return
	_touch()
	_enqueue(_build("track", event, _scalars(properties)))


## Record an error as an `error` event. Options (all optional):
##   severity     debug, info, warning, error (default) or critical
##   error_type   the error class, for example "SaveFailed"
##   handled      false when the game could not recover (default true)
##   stack        a stack trace text (cut to 1024 characters)
##   file, line, function   where the error happened
##   fingerprint  your own grouping key; by default a hash of error_type and
##                file and function, or of the message without numbers
##   properties   more scalar properties (level, mode, ...)
func track_error(message: String, options: Dictionary = {}) -> void:
	_record_error(message, options, "manual")


## A function that gets the properties of each `error` event before it is
## queued. Return a Dictionary to send (for example without personal data),
## or null to drop the error. Pass Callable() to remove it.
func set_before_send(callback: Callable) -> void:
	_before_send = callback


## Attach a known player ID (1 to 255 characters) and traits to this device.
func identify(user_id: String, traits: Dictionary = {}) -> void:
	if not _initialized:
		push_warning("UntitledAnalytics: call init() first")
		return
	if user_id.length() < 1 or user_id.length() > 255:
		push_warning("UntitledAnalytics: user_id must be 1 to 255 characters")
		return
	if not _identity_allowed():
		_deferred_identify = [user_id, traits]
		return
	_user_id = user_id
	_cfg.set_value("identity", "user_id", user_id)
	_save_cfg()
	_touch()
	var event := _build("identify", "", {})
	event["traits"] = _scalars(traits)
	_enqueue(event)
	flush()


## Forget the player: ends the session, clears user_id, makes a new anonymous ID
## and starts a new session.
func reset() -> void:
	if not _identity_active:
		_user_id = ""
		_deferred_identify = null
		return
	_end_session(_now())
	_user_id = ""
	_anonymous_id = _uuid()
	_cfg.set_value("identity", "user_id", "")
	_cfg.set_value("identity", "anonymous_id", _anonymous_id)
	_start_session(_now())
	_save_cfg()


## Consent mode: true starts the persistent identity and sends game_open;
## false deletes the ID, the session and every queued event.
func set_consent(granted: bool) -> void:
	_cfg.set_value("consent", "granted", granted)
	if not _initialized:
		return
	if granted:
		_save_cfg()
		if not _identity_active:
			_start_identity()
		return
	_identity_active = false
	_deferred_identify = null
	_anonymous_id = ""
	_user_id = ""
	_session_id = ""
	for key in ["anonymous_id", "user_id", "first_open_at"]:
		if _cfg.has_section_key("identity", key):
			_cfg.erase_section_key("identity", key)
	if _cfg.has_section("session"):
		_cfg.erase_section("session")
	_save_cfg()
	_queue.clear()
	if FileAccess.file_exists(QUEUE_PATH):
		DirAccess.remove_absolute(QUEUE_PATH)


## Send queued events now (one batch; the rest follows when it succeeds).
func flush() -> void:
	if not _identity_active or _sending or _queue.is_empty() or _now() < _backoff_until:
		return
	_prune()
	if _queue.is_empty():
		return
	var batch: Array = []
	_in_flight.clear()
	for entry in _queue.slice(0, int(_options.flush_at)):
		batch.append(entry.event)
		_in_flight.append(entry.event.message_id)
	var url := String(_options.endpoint).trim_suffix("/") + "/v0/events"
	var headers := PackedStringArray(["Content-Type: application/json", "x-write-key: %s" % _options.write_key])
	_sending = true
	var error := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify({"events": batch}))
	if error != OK:
		_on_request_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


## End the session and try to send everything, for at most quit_timeout_s.
## Call `await UntitledAnalytics.shutdown()` before your own quit when
## handle_quit is false. Unsent events stay on disk for the next launch.
func shutdown() -> void:
	if not _identity_active:
		return
	_end_session(_now())
	_save_queue()
	var deadline := Time.get_ticks_msec() + int(float(_options.quit_timeout_s) * 1000.0)
	_backoff_until = 0.0
	while Time.get_ticks_msec() < deadline:
		if not _sending:
			if _queue.is_empty():
				break
			flush()
			if not _sending:
				break  # Request could not start.
		await get_tree().process_frame
	_save_queue()


## Change the collector URL (for example after a config download).
func set_endpoint(endpoint: String) -> void:
	_options.endpoint = endpoint
	_backoff_until = 0.0
	_failures = 0


func get_anonymous_id() -> String:
	return _anonymous_id


func get_session_id() -> String:
	return _session_id


func get_queue_size() -> int:
	return _queue.size()


func is_sending() -> bool:
	return _sending


# Lifecycle -------------------------------------------------------------------

func _notification(what: int) -> void:
	if not _initialized:
		return
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			if _options.handle_quit and not _closing:
				_closing = true
				_close()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			if _identity_active:
				_focused = false
				_last_activity_at = _now()
				_save_session()
				_save_queue()
				flush()
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			if _identity_active:
				_focused = true
				_touch()
		NOTIFICATION_PREDELETE:
			_save_queue()


func _close() -> void:
	await shutdown()
	get_tree().quit()


func _exit_tree() -> void:
	if _error_logger != null:
		OS.remove_logger(_error_logger)
		_error_logger = null
	if _initialized:
		_save_session()
		# The game quit without shutdown(): a normal exit, not a crash.
		if _cfg.has_section("session"):
			_cfg.set_value("session", "exited", true)
			_save_cfg()
		_save_queue()


func _ready() -> void:
	set_process(false)


## Send the errors that the engine logger collected (main thread).
func _process(_delta: float) -> void:
	if _error_logger == null:
		return
	var taken: Array = _error_logger.take()
	var items: Array = taken[0]
	_errors_dropped += int(taken[1]) + maxi(0, items.size() - AUTO_ERRORS_PER_FRAME)
	for item in items.slice(0, AUTO_ERRORS_PER_FRAME):
		var kind := String(item.kind)
		_record_error(String(item.message), {
			"severity": "warning" if kind == "warning" else "error",
			"error_type": "engine_warning" if kind == "warning" else ("script_error" if kind == "script" else "engine_error"),
			"handled": false,
			"stack": String(item.stack),
			"file": String(item.file),
			"line": int(item.line),
			"function": String(item.function),
			"properties": {"engine_error_type": kind},
		}, "godot_logger")


func _on_tick() -> void:
	if not _identity_active:
		return
	# While the game has focus the player is active: keep the session alive.
	if _focused:
		_touch()
	_save_session()
	_save_queue()
	flush()


# Identity and sessions -------------------------------------------------------

func _identity_allowed() -> bool:
	if _cfg.has_section_key("consent", "granted"):
		return bool(_cfg.get_value("consent", "granted"))
	return not _options.consent_required


func _ready_to_record() -> bool:
	if not _initialized:
		push_warning("UntitledAnalytics: call init() first")
		return false
	return _identity_active  # No events at all before consent.


func _start_identity() -> void:
	_identity_active = true
	var now := _now()
	_anonymous_id = String(_cfg.get_value("identity", "anonymous_id", ""))
	var first_open := _anonymous_id == ""
	if first_open:
		_anonymous_id = _uuid()
		_cfg.set_value("identity", "anonymous_id", _anonymous_id)
		_cfg.set_value("identity", "first_open_at", _iso(now))
	_user_id = String(_cfg.get_value("identity", "user_id", ""))
	_load_queue()
	# A session left open by a crash or a killed process ends at its last activity.
	var previous := String(_cfg.get_value("session", "id", ""))
	if previous != "":
		_session_id = previous
		_session_started_at = float(_cfg.get_value("session", "started_at", now))
		_last_activity_at = float(_cfg.get_value("session", "last_activity_at", _session_started_at))
		# No normal exit and the game had focus: count it as a crash (as the
		# Sentry "abnormal" session). A game the OS closed in the background
		# is not a crash.
		if not bool(_cfg.get_value("session", "exited", false)) and bool(_cfg.get_value("session", "focused", true)):
			var crash := {"previous_session_id": previous}
			for key in ["build", "app_version"]:
				var value := String(_cfg.get_value("session", key, ""))
				if value != "":
					crash["previous_" + key] = value
			_enqueue(_build("track", "app_unclean_exit", crash, _last_activity_at))
		_end_session(_last_activity_at)
	_start_session(now)
	_enqueue(_build("track", "game_open", {"is_first_open": first_open, "first_open_at": String(_cfg.get_value("identity", "first_open_at", _iso(now)))}))
	_save_cfg()
	if _deferred_identify != null:
		var pending: Array = _deferred_identify
		_deferred_identify = null
		identify(pending[0], pending[1])
	flush()


func _start_session(at: float) -> void:
	_session_id = _uuid()
	_session_started_at = at
	_last_activity_at = at
	_auto_errors = 0
	_save_session()
	_enqueue(_build("track", "session_start", {}, at))


func _end_session(at: float) -> void:
	if _session_id == "":
		return
	var duration := maxf(0.0, at - _session_started_at)
	var ended := {"duration_s": int(round(duration))}
	if _errors_dropped > 0:
		ended["errors_dropped"] = _errors_dropped
		_errors_dropped = 0
	_enqueue(_build("track", "session_end", ended, at))
	_session_id = ""
	if _cfg.has_section("session"):
		_cfg.erase_section("session")
	_save_cfg()


## Record activity. Rotates the session after 30 minutes without activity.
func _touch() -> void:
	var now := _now()
	if _session_id == "":
		_start_session(now)
	elif now - _last_activity_at > SESSION_TIMEOUT_S:
		_end_session(_last_activity_at)
		_start_session(now)
	_last_activity_at = now


func _save_session() -> void:
	if _session_id == "":
		return
	_cfg.set_value("session", "id", _session_id)
	_cfg.set_value("session", "started_at", _session_started_at)
	_cfg.set_value("session", "last_activity_at", _last_activity_at)
	_cfg.set_value("session", "focused", _focused)
	_cfg.set_value("session", "exited", false)
	_cfg.set_value("session", "build", String(_options.build))
	_cfg.set_value("session", "app_version", String(_options.app_version))
	_save_cfg()


func _save_cfg() -> void:
	var error := _cfg.save(CONFIG_PATH)
	if error != OK and _options.debug:
		push_warning("UntitledAnalytics: could not save %s (%s)" % [CONFIG_PATH, error])


# Events and queue ------------------------------------------------------------

func _build(type: String, event: String, properties: Dictionary, at: float = -1.0) -> Dictionary:
	var when := _now() if at < 0.0 else at
	var envelope := {
		"type": type,
		"message_id": _uuid(),
		"channel": "app",
		"version": LIBRARY_VERSION,
		"original_timestamp": _iso(when),
		"context": _context(),
		"properties": properties,
		"anonymous_id": _anonymous_id,
		"session_id": _session_id,
	}
	if event != "":
		envelope["event"] = event
	if _user_id != "":
		envelope["user_id"] = _user_id
	if _session_id == "":
		envelope.erase("session_id")
	return {"at": when, "event": envelope}


func _context() -> Dictionary:
	var app := {"platform": _platform(), "engine": "godot"}
	for key in ["app_version", "build", "storefront"]:
		if String(_options[key]) != "":
			app[key] = String(_options[key])
	return {
		"app": app,
		"locale": OS.get_locale().replace("_", "-").left(32),
		"library_name": LIBRARY_NAME,
		"library_version": LIBRARY_VERSION,
	}


func _enqueue(entry: Dictionary) -> void:
	var name := String(entry.event.get("event", ""))
	if entry.event.type == "track" and name != "error":
		_breadcrumbs.append(name)
		if _breadcrumbs.size() > BREADCRUMBS:
			_breadcrumbs.pop_front()
	_queue.append(entry)
	var overflow := _queue.size() - int(_options.max_queue)
	if overflow > 0:
		_queue = _queue.slice(overflow)
	_queue_dirty = true
	if _options.debug:
		print("UntitledAnalytics: queued %s %s" % [entry.event.type, entry.event.get("event", "")])
	if _queue.size() >= int(_options.flush_at):
		_save_queue()
		flush()


## Drop events the collector would refuse as more than 7 days old.
func _prune() -> void:
	var oldest := _now() - MAX_EVENT_AGE_S
	var kept := _queue.filter(func(entry): return float(entry.at) >= oldest)
	if kept.size() != _queue.size():
		_queue = kept
		_queue_dirty = true


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var count := _in_flight.size()
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	# A 4xx other than 408 and 429 will fail again: drop the batch (as the
	# Immutable and web SDKs do). Network errors and 5xx stay and back off.
	var rejected := result == HTTPRequest.RESULT_SUCCESS and code >= 400 and code < 500 and code != 408 and code != 429
	if ok or rejected:
		var sent := {}
		for id in _in_flight:
			sent[id] = true
		_queue = _queue.filter(func(entry): return not sent.has(entry.event.message_id))
		_queue_dirty = true
		_failures = 0
		_backoff_until = 0.0
		if rejected:
			push_warning("UntitledAnalytics: collector refused %d events (HTTP %d)" % [count, code])
	else:
		_failures += 1
		var delay := minf(MAX_BACKOFF_S, pow(2.0, float(_failures)))
		_backoff_until = _now() + delay * randf_range(0.5, 1.0)
		if _options.debug:
			print("UntitledAnalytics: send failed (result %d, HTTP %d); retry in %.0f s" % [result, code, delay])
	_in_flight.clear()
	_sending = false
	_save_queue()
	flushed.emit(count if ok else 0, ok)
	if (ok or rejected) and not _queue.is_empty():
		flush.call_deferred()


func _load_queue() -> void:
	if not FileAccess.file_exists(QUEUE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(QUEUE_PATH))
	if typeof(parsed) != TYPE_ARRAY:
		return
	for entry in parsed:
		if typeof(entry) == TYPE_DICTIONARY and entry.has("at") and typeof(entry.get("event")) == TYPE_DICTIONARY:
			_queue.append(entry)
	_prune()


func _save_queue() -> void:
	if not _queue_dirty or not _identity_active:
		return
	var file := FileAccess.open(QUEUE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_queue))
	file.close()
	_queue_dirty = false


# Errors ----------------------------------------------------------------------

func _install_error_logger() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		if _options.debug:
			print("UntitledAnalytics: engine error capture needs Godot 4.5 or later")
		return
	var script = load(ERROR_LOGGER_PATH)
	if script == null:
		return
	_error_logger = script.new()
	_error_logger.capture_warnings = bool(_options.capture_warnings)
	OS.add_logger(_error_logger)
	set_process(true)


func _record_error(message: String, options: Dictionary, source: String) -> void:
	if not _initialized or not _identity_active:
		if source == "manual":
			_ready_to_record()  # Warns before init().
		return
	var severity := String(options.get("severity", "error"))
	if not SEVERITIES.has(severity):
		severity = "error"
	var error_type := String(options.get("error_type", "")).left(128)
	var file := String(options.get("file", "")).left(256)
	var function := String(options.get("function", "")).left(256)
	var props := _scalars(options.get("properties", {}) if typeof(options.get("properties")) == TYPE_DICTIONARY else {})
	props.merge({
		"severity": severity,
		"message": message.left(MAX_STRING),
		"handled": bool(options.get("handled", true)),
		"source": source,
		"fingerprint": String(options.get("fingerprint", "")).left(128),
	}, true)
	if props.fingerprint == "":
		props.fingerprint = _fingerprint(error_type, message, file, function)
	if error_type != "":
		props["error_type"] = error_type
	if file != "":
		props["file"] = file
		props["line"] = int(options.get("line", 0))
	if function != "":
		props["function"] = function
	var stack := String(options.get("stack", ""))
	if stack != "":
		props["stack"] = stack.left(MAX_STRING)
	if not _breadcrumbs.is_empty():
		props["breadcrumbs"] = ",".join(_breadcrumbs).right(MAX_STRING)
	if not _error_allowed(String(props.fingerprint), source):
		_errors_dropped += 1
		return
	if _before_send.is_valid():
		var changed = _before_send.call(props)
		if changed == null:
			return
		if typeof(changed) != TYPE_DICTIONARY:
			push_warning("UntitledAnalytics: before_send must return a Dictionary or null; error dropped")
			return
		props = _scalars(changed)
	if source != "manual":
		_auto_errors += 1
	_touch()
	_enqueue(_build("track", "error", props))
	# Keep the error on disk now: a crash can follow it.
	_save_queue()


## The limits. Manual errors skip only the per-session cap.
func _error_allowed(fingerprint: String, source: String) -> bool:
	var now := Time.get_ticks_msec()
	if _error_seen.has(fingerprint) and now - int(_error_seen[fingerprint]) < ERROR_DEDUPE_MS:
		return false
	_error_times = _error_times.filter(func(at): return now - int(at) < ERROR_WINDOW_MS)
	if _error_times.size() >= ERROR_WINDOW_MAX:
		return false
	if source != "manual" and _auto_errors >= int(_options.max_auto_errors_per_session):
		return false
	_error_seen[fingerprint] = now
	_error_times.append(now)
	if _error_seen.size() > 500:
		_error_seen.clear()
	return true


## Group errors as PostHog and Sentry do: the error type and the place in the
## code (no line number, so an edit above it keeps the group), else the
## message without numbers and quoted values.
func _fingerprint(error_type: String, message: String, file: String, function: String) -> String:
	var basis := ""
	if file != "" or function != "":
		basis = "%s|%s|%s" % [error_type, file, function]
	else:
		basis = "%s|%s" % [error_type, _number_re.sub(_quoted_re.sub(message, "?", true), "N", true)]
	return basis.sha1_text().left(16)


# Helpers ---------------------------------------------------------------------

func _platform() -> String:
	match OS.get_name():
		"Windows": return "windows"
		"macOS": return "macos"
		"Linux": return "linux"
		"Android": return "android"
		"iOS": return "ios"
		"Web": return "web"
	return "other"


## Keep scalar values; the collector refuses nested objects and arrays.
func _scalars(values: Dictionary) -> Dictionary:
	var out := {}
	for key in values:
		var name := String(key)
		var value = values[key]
		if name.length() < 1 or name.length() > 100:
			continue
		match typeof(value):
			TYPE_NIL, TYPE_BOOL, TYPE_INT:
				out[name] = value
			TYPE_FLOAT:
				if is_finite(value):
					out[name] = value
			TYPE_STRING, TYPE_STRING_NAME:
				out[name] = String(value).left(1024)
			_:
				push_warning("UntitledAnalytics: property %s is not a scalar; dropped" % name)
	return out


func _check_label(key: String, max_length: int) -> void:
	var value := String(_options[key])
	if value != "" and (value.length() > max_length or _label_re.search(value) == null):
		push_warning("UntitledAnalytics: %s must be 1 to %d letters, digits, spaces or . _ + -; ignored" % [key, max_length])
		_options[key] = ""


func _now() -> float:
	return Time.get_unix_time_from_system()


func _iso(unix: float) -> String:
	var whole := floori(unix)
	return "%s.%03dZ" % [Time.get_datetime_string_from_unix_time(whole), int((unix - whole) * 1000.0)]


func _uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
