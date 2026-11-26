extends Node
## Manalens for Godot 4 (autoload singleton `Manalens`).
##
## Sends game events to `POST /v0/events` with the project publishable key,
## the same envelope as the Manalens web SDK, and `context.app` in
## place of `context.page`.
##
##   Manalens.init({
##       "publishable_key": "mana_pk_...",
##       "endpoint": "https://collector.example.com",
##       "app_version": "1.4.0", "build": "571", "storefront": "steam",
##   })
##   Manalens.track("level_complete", {"level": 3, "score": 1200})
##
## Identity: a persistent anonymous UUID in `user://manalens.cfg`.
## Sessions rotate after 30 minutes without focus or events. `game_open`,
## `session_start` and `session_end` are automatic. Events are batched, kept in
## an offline file queue (`user://manalens_queue.json`, at most 1000
## events and 7 days), and retried with backoff.
##
## Errors: `track_error()` sends an `error` event. On Godot 4.5+ the SDK also
## sends engine and script errors (`capture_engine_errors`). When the last run
## ended without a normal exit (a crash or a killed process), the next launch
## sends `app_unclean_exit` in that old session.

signal flushed(sent: int, ok: bool)
## Events were dropped and will never be sent. `status` is the HTTP status
## when the collector refused a batch (a 4xx other than 408 and 429), or 0 when
## the SDK dropped events itself (the queue was over max_queue, or events were
## older than 7 days). `dropped` is the number of events. Network errors and 5xx
## responses do not emit it: those events stay queued and are sent later.
signal send_failed(status: int, dropped: int)

const LIBRARY_NAME := "Manalens Godot SDK"
const LIBRARY_VERSION := "0.1.2"
const CONFIG_PATH := "user://manalens.cfg"
const QUEUE_PATH := "user://manalens_queue.json"
## Written by set_consent(false). While it exists the SDK records nothing,
## whatever the config file says (fail closed if that file is lost or damaged).
const OPTOUT_PATH := "user://manalens_optout"
const SESSION_TIMEOUT_S := 30.0 * 60.0
## A session is never older than this. A game that stays open gets a
## session_end and a session_start every 24 hours.
const SESSION_MAX_AGE_S := 24.0 * 60.0 * 60.0
## The collector accepts app events up to 7 days old. Keep a margin for clock skew.
const MAX_EVENT_AGE_S := 7.0 * 24.0 * 3600.0 - 3600.0
const MAX_BACKOFF_S := 300.0
const STOREFRONTS := ["steam", "itch", "epic", "gog", "app_store", "play", "other"]
const SEVERITIES := ["debug", "info", "warning", "error", "critical"]
const ERROR_LOGGER_PATH := "res://addons/manalens/error_logger.gd"
## Error limits (as Sentry Godot): the same fingerprint at most once a second,
## at most 20 errors in 10 seconds, at most 5 automatic errors in one frame.
const ERROR_DEDUPE_MS := 1000
const ERROR_WINDOW_MS := 10000
const ERROR_WINDOW_MAX := 20
const AUTO_ERRORS_PER_FRAME := 5
const BREADCRUMBS := 20
## The collector keeps string properties up to 1024 characters.
const MAX_STRING := 1024
## The collector refuses properties or traits with more keys, or with more
## UTF-8 bytes of JSON (P-2700). The SDK drops the extra keys with a warning.
const MAX_PROPERTY_KEYS := 50
const MAX_PROPERTY_BYTES := 8 * 1024
## Identity handoff (P-2523): the URL parameter that the web SDK reads.
const HANDOFF_PARAM := "mana_hid"

var _options := {
	## false: the SDK sends nothing, writes no files and keeps no ID. Use
	## `"enabled": not OS.has_feature("editor")` to keep editor runs out of
	## your reports.
	"enabled": true,
	## The project publishable key (`mana_pk_...`).
	"publishable_key": "",
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
## true when init() ran with enabled = false: every call is a no-op.
var _disabled := false
## The config file exists but could not be read: it may hold an opt-out, so
## record nothing this run and never overwrite it (until set_consent(true)).
var _state_unreadable := false
## set_consent(false) could not write the opt-out marker: stay off, retry.
var _optout_pending := false
var _identity_active := false
## Web export with localStorage: the state, the queue and the opt-out marker are
## there, written at once (P-2791). user:// on web is IndexedDB, which Godot
## writes a moment after a file is closed, so a reload in that moment lost the
## state and the next load made a new anonymous ID.
var _web_storage := false
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

## Start the SDK. Keys: publishable_key, endpoint (required); enabled, app_version, build,
## storefront, consent_required, flush_interval_s, flush_at, max_queue,
## handle_quit, quit_timeout_s, capture_engine_errors, capture_warnings,
## max_auto_errors_per_session, debug.
func init(options: Dictionary) -> void:
	if _initialized:
		push_warning("Manalens: init() was already called")
		return
	for key in options:
		if _options.has(key):
			_options[key] = options[key]
		else:
			push_warning("Manalens: unknown option %s" % key)
	if not bool(_options.enabled):
		# Turned off (for example in the editor): every call is a silent no-op.
		_disabled = true
		_initialized = true
		if _options.debug:
			print("Manalens: disabled (enabled = false); no events are sent")
		return
	if String(_options.publishable_key) == "" or String(_options.endpoint) == "":
		push_error("Manalens: publishable_key and endpoint are required")
		return
	# Only the publishable key may ship in a game build: never a secret key (mana_sk_) or an API key (mana_api_).
	var key := String(_options.publishable_key)
	if not key.begins_with("mana_pk_"):
		push_error("Manalens: publishable_key must be the publishable key (mana_pk_...). Never put a secret key or an API key in a game build")
		return
	_options.flush_at = clampi(int(_options.flush_at), 1, 50)
	_options.max_queue = maxi(int(_options.max_queue), int(_options.flush_at))
	_check_label("app_version", 32)
	_check_label("build", 64)
	if String(_options.storefront) != "" and not STOREFRONTS.has(String(_options.storefront)):
		push_warning("Manalens: storefront must be one of %s; ignored" % [STOREFRONTS])
		_options.storefront = ""
	_initialized = true
	_web_storage = OS.has_feature("web") and _web_storage_available()
	if _web_storage:
		var text = _store_read(CONFIG_PATH)
		if text != null:
			var parse_error := ERR_FILE_CANT_READ if text is bool else _cfg.parse(String(text))
			if parse_error != OK:
				_state_unreadable = true
				_cfg = ConfigFile.new()
				if text is String:
					_store_write(CONFIG_PATH + ".unreadable", text)
				push_warning("Manalens: could not read the saved state (error %d); no events until set_consent(true)" % parse_error)
	elif FileAccess.file_exists(CONFIG_PATH):
		var load_error := _cfg.load(CONFIG_PATH)
		if load_error != OK:
			# Fail closed: keep a copy, record nothing, and never overwrite the file.
			_state_unreadable = true
			_cfg = ConfigFile.new()
			DirAccess.copy_absolute(CONFIG_PATH, CONFIG_PATH + ".unreadable")
			push_warning("Manalens: could not read %s (error %d); no events until set_consent(true)" % [CONFIG_PATH, load_error])
	# A missing file is a first run.
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
		push_warning("Manalens: event name must be 1 to 128 characters")
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
	if _disabled:
		return
	if not _initialized:
		push_warning("Manalens: call init() first")
		return
	if user_id.length() < 1 or user_id.length() > 255:
		push_warning("Manalens: user_id must be 1 to 255 characters")
		return
	if not _identity_allowed():
		_deferred_identify = [user_id, traits]
		return
	_user_id = user_id
	_cfg.set_value("identity", "user_id", user_id)
	_save_cfg()
	_touch()
	var event := _build("identify", "", {})
	event.event["traits"] = _fit(_scalars(traits), "traits")
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
	if _disabled:
		return
	if granted:
		if _store_exists(OPTOUT_PATH) and not _store_remove(OPTOUT_PATH):
			push_warning("Manalens: could not remove the opt-out marker; tracking stays off")
			return
		_optout_pending = false
		# An unreadable config is replaced by a new one after an explicit opt-in.
		_state_unreadable = false
	else:
		_write_optout()
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
	if _store_exists(QUEUE_PATH):
		_store_remove(QUEUE_PATH)


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
	var headers := PackedStringArray(["Content-Type: application/json", "x-publishable-key: %s" % _options.publishable_key])
	_sending = true
	var error := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify({"events": batch}))
	if error != OK:
		_on_request_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


## End the session and try to send everything, for at most quit_timeout_s.
## Call `await Manalens.shutdown()` before your own quit when
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


## Add this install's handoff parameter to a website URL before the game opens
## it, so the website joins the browser to this player without identify():
##
##   OS.shell_open(Manalens.link_url("https://example.com/wiki"))
##
## The parameter is `mana_hid=<anonymous ID>.<unix seconds>`. The website's
## Manalens SDK removes it from the address bar, and the collector
## accepts it for 10 minutes. Before consent (or before init) the URL is
## returned unchanged.
func link_url(url: String) -> String:
	if not _identity_active or _anonymous_id == "":
		return url
	var fragment := ""
	var hash_at := url.find("#")
	if hash_at >= 0:
		fragment = url.substr(hash_at)
		url = url.substr(0, hash_at)
	var separator := "&" if url.contains("?") else "?"
	if url.ends_with("?") or url.ends_with("&"):
		separator = ""
	return "%s%s%s=%s.%d%s" % [url, separator, HANDOFF_PARAM, _anonymous_id, int(Time.get_unix_time_from_system()), fragment]


func get_session_id() -> String:
	return _session_id


func get_queue_size() -> int:
	return _queue.size()


func is_sending() -> bool:
	return _sending


# Lifecycle -------------------------------------------------------------------

func _notification(what: int) -> void:
	if not _initialized or _disabled:
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
				# Only an open session: after shutdown() the next event starts a new one.
				if _session_id != "":
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
	if _initialized and not _disabled:
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
	if _optout_pending:
		_write_optout()
	if not _identity_active:
		return
	# While the game has focus the player is active: keep the session alive.
	# Only an open one: during shutdown() a tick must not start a new session.
	if _focused and _session_id != "":
		_touch()
	_save_session()
	_save_queue()
	flush()


# Identity and sessions -------------------------------------------------------

func _identity_allowed() -> bool:
	if _state_unreadable or _optout_pending or _store_exists(OPTOUT_PATH):
		return false
	if _cfg.has_section_key("consent", "granted"):
		return bool(_cfg.get_value("consent", "granted"))
	return not _options.consent_required


func _ready_to_record() -> bool:
	if not _initialized:
		push_warning("Manalens: call init() first")
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
		# is not a crash. On web a closed or reloaded tab has no quit event,
		# so every relaunch would look like a crash: no crash detection there.
		if not bool(_cfg.get_value("session", "exited", false)) and bool(_cfg.get_value("session", "focused", true)) and _platform() != "web":
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
	# Write game_open (the install signal) and app_unclean_exit to disk before
	# any send: a process killed before the next save would lose them.
	_save_queue()
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


## Record activity. Rotates the session after 30 minutes without activity,
## and when the session is 24 hours old (the collector's session rule does not
## use a client session of more than 24 hours).
func _touch() -> void:
	var now := _now()
	if _session_id == "":
		_start_session(now)
	elif now - _last_activity_at > SESSION_TIMEOUT_S:
		_end_session(_last_activity_at)
		_start_session(now)
	elif now - _session_started_at >= SESSION_MAX_AGE_S:
		if _options.debug:
			print("Manalens: the session is 24 hours old; a new session starts")
		_end_session(now)
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
	if _state_unreadable:
		return  # Never overwrite a config that could not be read.
	if _web_storage:
		if not _store_write(CONFIG_PATH, _cfg.encode_to_text()) and _options.debug:
			push_warning("Manalens: could not save the state in localStorage")
		return
	# Write a temp file, then rename, so a crash never leaves a cut-off config.
	var tmp := CONFIG_PATH + ".tmp"
	var error := _cfg.save(tmp)
	if error == OK:
		error = DirAccess.rename_absolute(tmp, CONFIG_PATH)
	if error != OK and _options.debug:
		push_warning("Manalens: could not save %s (%s)" % [CONFIG_PATH, error])


## Write the opt-out marker (temp file, then rename). On failure stay off and retry.
func _write_optout() -> void:
	if _web_storage:
		_optout_pending = not _store_write(OPTOUT_PATH, "opted out\n")
		if _optout_pending:
			push_warning("Manalens: could not write the opt-out marker; tracking stays off and the write is retried")
		return
	var tmp := OPTOUT_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	var ok := file != null
	if ok:
		file.store_string("opted out\n")
		file.close()
		ok = DirAccess.rename_absolute(tmp, OPTOUT_PATH) == OK
	_optout_pending = not ok
	if not ok:
		push_warning("Manalens: could not write the opt-out marker; tracking stays off and the write is retried")


# Storage ---------------------------------------------------------------------
# One place for the files of the SDK. On web with localStorage (_web_storage):
# the browser's localStorage, written at once. Keys start with the user data
# folder, which has the project name: games on one origin (for example
# html-classic.itch.zone) share one localStorage. A file from SDK 0.1.0 moves
# to localStorage on its first read. Elsewhere: the files in user://.

func _web_storage_available() -> bool:
	return str(JavaScriptBridge.eval("(function(){try{var k='__manalens_probe__';localStorage.setItem(k,'1');localStorage.removeItem(k);return '1'}catch(e){return '0'}})()", true)) == "1"


func _web_key(path: String) -> String:
	return "manalens:%s:%s" % [OS.get_user_data_dir(), path.trim_prefix("user://")]


## The text, null when it is missing, or false when it could not be read.
func _store_read(path: String) -> Variant:
	if not _web_storage:
		if not FileAccess.file_exists(path):
			return null
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return false
		return file.get_as_text()
	var result := str(JavaScriptBridge.eval("(function(){try{var v=localStorage.getItem(%s);return v===null?'0':'1'+v}catch(e){return '2'}})()" % JSON.stringify(_web_key(path)), true))
	if result.begins_with("1"):
		return result.substr(1)
	if result != "0":
		return false
	# Missing in localStorage: move the file of SDK 0.1.0 once.
	if not FileAccess.file_exists(path):
		return null
	var old := FileAccess.get_file_as_string(path)
	if _store_write(path, old):
		DirAccess.remove_absolute(path)
	return old


func _store_write(path: String, text: String) -> bool:
	return str(JavaScriptBridge.eval("(function(){try{localStorage.setItem(%s,%s);return '1'}catch(e){return '0'}})()" % [JSON.stringify(_web_key(path)), JSON.stringify(text)], true)) == "1"


func _store_exists(path: String) -> bool:
	if not _web_storage:
		return FileAccess.file_exists(path)
	return _store_read(path) != null


## Also removes the file: a later read must not bring an old value back.
func _store_remove(path: String) -> bool:
	var removed := true
	if _web_storage:
		removed = str(JavaScriptBridge.eval("(function(){try{localStorage.removeItem(%s);return '1'}catch(e){return '0'}})()" % JSON.stringify(_web_key(path)), true)) == "1"
	if FileAccess.file_exists(path):
		removed = DirAccess.remove_absolute(path) == OK and removed
	return removed


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
		"properties": _fit(properties, "properties"),
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
	var context := {
		"app": app,
		"locale": OS.get_locale().replace("_", "-").left(32),
		"library_name": LIBRARY_NAME,
		"library_version": LIBRARY_VERSION,
	}
	# The clock's offset from UTC in minutes (480 for UTC+8). The collector uses
	# it only to match an install to a website visit, and accepts -720 to 840.
	var offset := int(Time.get_time_zone_from_system().get("bias", 9999))
	if offset >= -720 and offset <= 840:
		context["utc_offset"] = offset
	return context


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
		send_failed.emit(0, overflow)
	_queue_dirty = true
	if _options.debug:
		print("Manalens: queued %s %s" % [entry.event.type, entry.event.get("event", "")])
	if _queue.size() >= int(_options.flush_at):
		_save_queue()
		flush()


## Drop events the collector would refuse as more than 7 days old.
func _prune() -> void:
	var oldest := _now() - MAX_EVENT_AGE_S
	var kept := _queue.filter(func(entry): return float(entry.at) >= oldest)
	if kept.size() != _queue.size():
		send_failed.emit(0, _queue.size() - kept.size())
		_queue = kept
		_queue_dirty = true


## The reason of a refusal from the response body: the message, and the
## reason code of each refused event (for example SESSION_ID_REQUIRED).
func _refusal_reason(body: PackedByteArray) -> String:
	# JSON.new().parse() does not log an engine error for a body that is not JSON.
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return ""
	var parsed = json.data
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("error")) != TYPE_DICTIONARY:
		return ""
	var error: Dictionary = parsed.error
	var reason := "%s: %s" % [String(error.get("code", "")), String(error.get("message", ""))]
	var codes := {}
	if typeof(error.get("refused")) == TYPE_ARRAY:
		for item in error.refused:
			if typeof(item) == TYPE_DICTIONARY:
				codes[String(item.get("code", ""))] = true
	if not codes.is_empty():
		reason += " (%s)" % ", ".join(PackedStringArray(codes.keys()))
	return reason


## The refused events of an accepted batch (P-2787): the collector stores the
## valid events and lists the others in "errors". Returns the "rejected" count
## and the reason codes, or a count of 0 when the body has none.
func _refused_in_accepted(body: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return {"count": 0, "reason": ""}
	var parsed = json.data
	if typeof(parsed) != TYPE_DICTIONARY or not (typeof(parsed.get("rejected")) in [TYPE_INT, TYPE_FLOAT]) or int(parsed.rejected) <= 0:
		return {"count": 0, "reason": ""}
	var codes := {}
	if typeof(parsed.get("errors")) == TYPE_ARRAY:
		for item in parsed.errors:
			if typeof(item) == TYPE_DICTIONARY:
				codes[String(item.get("code", ""))] = true
	return {"count": int(parsed.rejected), "reason": ", ".join(PackedStringArray(codes.keys()))}


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
			# Dropped, not sent again: the same batch would be refused again.
			var reason := _refusal_reason(_body)
			push_warning("Manalens: collector refused %d events (HTTP %d)%s; they are dropped" % [count, code, "" if reason == "" else " " + reason])
			send_failed.emit(code, count)
		else:
			# An accepted batch can still list refused events (P-2787). They are
			# not sent again: the same events would be refused again.
			var refused := _refused_in_accepted(_body)
			var dropped := mini(count, int(refused.count))
			if dropped > 0:
				push_warning("Manalens: collector refused %d of %d events (HTTP %d)%s; they are dropped" % [dropped, count, code, "" if refused.reason == "" else " " + refused.reason])
				send_failed.emit(code, dropped)
				count -= dropped
	else:
		_failures += 1
		var delay := minf(MAX_BACKOFF_S, pow(2.0, float(_failures)))
		_backoff_until = _now() + delay * randf_range(0.5, 1.0)
		if _options.debug:
			print("Manalens: send failed (result %d, HTTP %d); retry in %.0f s" % [result, code, delay])
	_in_flight.clear()
	_sending = false
	_save_queue()
	flushed.emit(count if ok else 0, ok)
	if (ok or rejected) and not _queue.is_empty():
		flush.call_deferred()


func _load_queue() -> void:
	var text = _store_read(QUEUE_PATH)
	if not text is String:
		return
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		return
	for entry in parsed:
		if typeof(entry) == TYPE_DICTIONARY and entry.has("at") and typeof(entry.get("event")) == TYPE_DICTIONARY:
			_queue.append(entry)
	_prune()


func _save_queue() -> void:
	if not _queue_dirty or not _identity_active:
		return
	if _web_storage:
		if _store_write(QUEUE_PATH, JSON.stringify(_queue)):
			_queue_dirty = false
		return
	# Write a temp file, then rename, so a crash never leaves a cut-off queue.
	var tmp := QUEUE_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_queue))
	file.close()
	if DirAccess.rename_absolute(tmp, QUEUE_PATH) == OK:
		_queue_dirty = false


# Errors ----------------------------------------------------------------------

func _install_error_logger() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		if _options.debug:
			print("Manalens: engine error capture needs Godot 4.5 or later")
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
	# The error's own keys come first, so a trim to the limits (_fit) drops custom keys first.
	var props := {
		"severity": severity,
		"message": message.left(MAX_STRING),
		"handled": bool(options.get("handled", true)),
		"source": source,
		"fingerprint": String(options.get("fingerprint", "")).left(128),
	}
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
	props.merge(_scalars(options.get("properties", {}) if typeof(options.get("properties")) == TYPE_DICTIONARY else {}), false)
	if not _error_allowed(String(props.fingerprint), source):
		_errors_dropped += 1
		return
	if _before_send.is_valid():
		var changed = _before_send.call(props)
		if changed == null:
			return
		if typeof(changed) != TYPE_DICTIONARY:
			push_warning("Manalens: before_send must return a Dictionary or null; error dropped")
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


## Keep keys in order while there are at most MAX_PROPERTY_KEYS keys and
## MAX_PROPERTY_BYTES of JSON. The collector refuses a whole batch for one
## event over a limit, so the SDK drops the extra keys with a warning.
func _fit(values: Dictionary, field: String) -> Dictionary:
	if values.size() <= MAX_PROPERTY_KEYS and JSON.stringify(values).to_utf8_buffer().size() <= MAX_PROPERTY_BYTES:
		return values
	var out := {}
	var used := 2
	for key in values:
		if out.size() >= MAX_PROPERTY_KEYS:
			break
		var entry := JSON.stringify({key: values[key]}).to_utf8_buffer().size() - 2 + (1 if out.size() > 0 else 0)
		if used + entry > MAX_PROPERTY_BYTES:
			break
		out[key] = values[key]
		used += entry
	push_warning("Manalens: %s over the limit of %d keys or %d bytes; %d keys dropped" % [field, MAX_PROPERTY_KEYS, MAX_PROPERTY_BYTES, values.size() - out.size()])
	return out


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
				push_warning("Manalens: property %s is not a scalar; dropped" % name)
	return out


func _check_label(key: String, max_length: int) -> void:
	var value := String(_options[key])
	if value != "" and (value.length() > max_length or _label_re.search(value) == null):
		push_warning("Manalens: %s must be 1 to %d letters, digits, spaces or . _ + -; ignored" % [key, max_length])
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
