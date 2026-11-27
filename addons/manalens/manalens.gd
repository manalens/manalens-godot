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
## sends `app_crash` in that old session.

signal flushed(sent: int, ok: bool)
## Events were dropped and will never be sent. `status` is the HTTP status
## when the collector refused a batch (a 4xx other than 408 and 429), or 0 when
## the SDK dropped events itself (the queue was over max_queue, or events were
## older than 7 days). `dropped` is the number of events. Network errors and 5xx
## responses do not emit it: those events stay queued and are sent later.
signal send_failed(status: int, dropped: int)
## The answer to link_steam() (P-2815). `linked` is true when Steam accepted the
## ticket. `status` is the HTTP status (0 when no request was made or the
## network failed). `code` is the API error code, such as
## STEAM_TICKET_INVALID or STEAM_NOT_CONNECTED, or an SDK code: STEAM_TICKET
## (Steam gave no ticket), NETWORK_ERROR or IDENTITY_CHANGED.
signal steam_linked(linked: bool, status: int, code: String)

const LIBRARY_NAME := "Manalens Godot SDK"
const LIBRARY_VERSION := "0.4.0"
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
## The longest wait that a Retry-After header can ask for (1 hour).
const MAX_RETRY_AFTER_S := 3600.0
const HTTP_MONTHS := ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
const STOREFRONTS := ["steam", "itch", "epic", "gog", "app_store", "play", "psn", "xbox", "nintendo", "other"]
## The `platform` option: the values the collector accepts. Leave the option
## empty to detect the platform with OS.get_name().
const PLATFORMS := ["windows", "macos", "linux", "web", "android", "ios", "ps5", "xbox_series", "xbox_one", "switch", "switch2", "other"]
const AUTO_IDENTIFY := ["steam"]
## GodotSteam may start Steam after the SDK. Try again on the flush timer this
## many times (about one minute with the default flush interval).
const AUTO_IDENTIFY_TRIES := 6
## Protected traits (P-2814): only a server with the secret key may set them.
## The collector drops them from game events, so traits() does not send them.
const PROTECTED_TRAITS := ["email", "itch_user_id", "stripe_customer_id", "paddle_customer_id"]
## link_steam(): the identity of the Steam Web API ticket. The server accepts only this one.
const STEAM_TICKET_IDENTITY := "manalens"
## link_steam() waits for a 429 Retry-After of at most this many seconds, once.
const LINK_MAX_RETRY_AFTER_S := 60.0
## Steam's k_EResultOK in the get_ticket_for_web_api signal.
const STEAM_RESULT_OK := 1
## Project Settings > Manalens (publishable_key, endpoint, auto_init, ...).
const Settings := preload("res://addons/manalens/settings.gd")
const SEVERITIES := ["debug", "info", "warning", "error", "critical"]
## The source of an error: a track_error() call, or an automatic capture.
const SOURCE_MANUAL := "manual"
const SOURCE_AUTO := "auto"
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
	## Empty: detected from OS.get_name(). Set it for a console build (a
	## console port of Godot): ps5, xbox_series, xbox_one, switch or switch2.
	"platform": "",
	## "steam": after consent, identify the player once per launch as
	## steam_<SHA-256 of "<publishable_key>:<SteamID64>"> with the trait
	## storefront = steam, when the GodotSteam addon is present and Steam is
	## running. Off ("") by default. An identify() call from the game wins.
	"auto_identify": "",
	## true: after consent, link the Steam account once per launch (P-2815):
	## the SDK asks GodotSteam for a Web API ticket with the identity
	## "manalens" and posts it to <api_endpoint>/v0/link. Needs the GodotSteam
	## addon and a running Steam client; without them it does nothing. Off by
	## default. See link_steam().
	"steam_link": false,
	## The API URL for link_steam(). Empty: the endpoint with an `events.`
	## host changed to `api.` (https://events.manalens.dev gives
	## https://api.manalens.dev); any other endpoint is used as it is.
	"api_endpoint": "",
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
	## A dedicated server build (the `dedicated_server` feature tag, or the
	## headless display server) is not a player. false (default): on a server
	## build the SDK sends no game_open, session_start, session_end or
	## app_crash, so the server does not count as an install or a
	## session. track() and identify() still work. true: a server build sends
	## them as a client does.
	"track_server_builds": false,
	"debug": false,
}
var _initialized := false
## true on a server build without track_server_builds: no automatic client events.
var _server_quiet := false
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
var _game_identified := false  # the game called identify() in this launch
var _auto_identify_tries := 0  # auto_identify attempts left in this launch
var _deferred_traits := {}  # traits() before consent, merged
var _warned_protected_traits := false
var _steam_link_tries := 0  # steam_link attempts left in this launch
var _steam_link_done := false  # steam_link: the automatic link ran in this launch
var _link_in_flight := false  # a ticket request or a link request is running
var _steam_link_pending = null  # link_steam() before consent: a ticket, or true to ask Steam
var _steam_ticket_handle := 0  # the GodotSteam ticket that the SDK waits for
var _link_http: HTTPRequest
var _link_body := ""
var _link_attempt := 0
var _link_anonymous_id := ""  # the anonymous ID of the request: a retry needs the same
var _http: HTTPRequest
var _timer: Timer
var _label_re := RegEx.create_from_string("^[A-Za-z0-9._+\\- ]+$")
var _closing := false
var _before_send := Callable()
var _in_before_send := false
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
## storefront, platform, auto_identify, consent_required, flush_interval_s, flush_at, max_queue,
## handle_quit, quit_timeout_s, capture_engine_errors, capture_warnings,
## max_auto_errors_per_session, track_server_builds, debug. The values of Project Settings >
## Manalens apply first; the options override them. With a key in Project
## Settings and auto_init on, the autoload calls init({}) itself at the end of
## the first frame, unless your code called init() before.
func init(options: Dictionary = {}) -> void:
	if _initialized:
		push_warning("Manalens: init() was already called")
		return
	var from_settings: Dictionary = Settings.options()
	for key in from_settings:
		_options[key] = from_settings[key]
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
	if String(_options.platform) != "" and not PLATFORMS.has(String(_options.platform)):
		push_warning("Manalens: platform must be one of %s; detected instead" % [PLATFORMS])
		_options.platform = ""
	if String(_options.auto_identify) != "" and not AUTO_IDENTIFY.has(String(_options.auto_identify)):
		push_warning("Manalens: auto_identify must be \"steam\" or empty; ignored")
		_options.auto_identify = ""
	_auto_identify_tries = AUTO_IDENTIFY_TRIES if String(_options.auto_identify) != "" else 0
	_steam_link_tries = AUTO_IDENTIFY_TRIES if bool(_options.steam_link) else 0
	_initialized = true
	_server_quiet = is_server_build() and not bool(_options.track_server_builds)
	if _server_quiet:
		print("Manalens: server build (dedicated_server or headless); no game_open, session or app_crash events. Set track_server_builds to send them")
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
	_link_http = HTTPRequest.new()
	_link_http.timeout = 10.0
	_link_http.request_completed.connect(_on_link_completed)
	add_child(_link_http)
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


## true in a dedicated server build: the `dedicated_server` feature tag, or the
## headless display server (`--headless`).
static func is_server_build() -> bool:
	return OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"


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
	_record_error(message, options, SOURCE_MANUAL)


## A function that gets each event before it is queued: track events (also
## error and the automatic events), identify and traits. It gets a copy of the whole
## event Dictionary ("type", "event", "properties", "traits", "user_id",
## "message_id", "anonymous_id", "session_id", "context", ...). Return the
## event to send (changed or not), or null to drop it. The SDK takes "event",
## "properties", "traits" and "user_id" from the result; it keeps the other
## fields. When the result changes or removes "type", "message_id",
## "anonymous_id", "session_id" or "context.app", the SDK sends the original
## event. Errors pass the error limits first, so a dropped error still counts
## in those limits. Do not record events inside the callback: they are
## dropped. Pass Callable() to remove it.
func set_before_send(callback: Callable) -> void:
	_before_send = callback


## Attach a known player ID (1 to 255 characters) and traits to this device.
## A call from the game wins over auto_identify: after it, the SDK does not
## identify the player by Steam in this launch.
func identify(user_id: String, traits: Dictionary = {}) -> void:
	if _disabled:
		return
	if not _initialized:
		push_warning("Manalens: call init() first")
		return
	if user_id.length() < 1 or user_id.length() > 255:
		push_warning("Manalens: user_id must be 1 to 255 characters")
		return
	_game_identified = true
	_auto_identify_tries = 0
	_identify(user_id, traits, "game")


func _identify(user_id: String, traits: Dictionary, source: String) -> void:
	if not _identity_allowed():
		_deferred_identify = [user_id, traits]
		return
	_user_id = user_id
	_cfg.set_value("identity", "user_id", user_id)
	# Who set the user ID: "game" (identify()) or "steam" (auto_identify). A
	# later launch never replaces a user ID that the game set.
	_cfg.set_value("identity", "user_id_source", source)
	_save_cfg()
	_touch()
	var event := _build("identify", "", {})
	event.event["traits"] = _fit(_scalars(traits), "traits")
	_enqueue(event)
	flush()


## Set traits on this player, with or without a user ID (P-2814). Before
## identify() the traits belong to this install's anonymous ID; after it, to
## the user. Values: String, int, float, bool or null (null clears a trait). At
## most 50 keys and 8 KB of JSON. Like identify(), it waits for consent: calls
## before consent are merged and sent then. The protected traits email,
## itch_user_id, stripe_customer_id and paddle_customer_id are not sent (one
## warning): only a server may set them.
func traits(values: Dictionary) -> void:
	if _disabled:
		return
	if not _initialized:
		push_warning("Manalens: call init() first")
		return
	var kept := {}
	var dropped: Array = []
	for key in values:
		if PROTECTED_TRAITS.has(String(key)):
			dropped.append(String(key))
		else:
			kept[key] = values[key]
	if not dropped.is_empty() and not _warned_protected_traits:
		_warned_protected_traits = true
		push_warning("Manalens: traits() does not send %s. Only a server with the secret key can set protected traits" % ", ".join(dropped))
	kept = _fit(_scalars(kept), "traits")
	if kept.is_empty():
		if dropped.is_empty():
			push_warning("Manalens: traits() needs at least one trait")
		return
	if not _identity_active:
		_deferred_traits.merge(kept, true)
		return
	_send_traits(kept)


func _send_traits(values: Dictionary) -> void:
	_touch()
	var event := _build("traits", "", {})
	event.event["traits"] = values
	_enqueue(event)


## Link the Steam account of this player (P-2815). Manalens checks the ticket
## with Steam and reads which of your apps the account owns. The player does
## not sign in. Once per launch, after consent.
##
## With no argument the SDK asks GodotSteam for a Web API ticket itself:
## Steam.getAuthTicketForWebApi("manalens"), then the get_ticket_for_web_api
## signal. Without the GodotSteam addon or a running Steam client it does
## nothing. With your own ticket bytes (from GetAuthTicketForWebApi with the
## identity "manalens"), the SDK sends those. The answer comes in the
## steam_linked signal. A refused ticket is not sent again; a 429 with
## Retry-After (60 s or less) is tried once more.
func link_steam(ticket: PackedByteArray = PackedByteArray()) -> void:
	if _disabled:
		return
	if not _initialized:
		push_warning("Manalens: call init() first")
		return
	if not ticket.is_empty() and (ticket.size() < 16 or ticket.size() > 2048):
		push_warning("Manalens: link_steam() needs a ticket of 16 to 2048 bytes")
		return
	if _link_in_flight:
		return
	_steam_link_tries = 0  # A call from the game replaces the steam_link option.
	if not _identity_active:
		_steam_link_pending = true if ticket.is_empty() else ticket
		return
	if ticket.is_empty():
		_request_steam_ticket()
	else:
		_send_link(ticket.hex_encode())


## steam_link = true: once per launch, after consent, when Steam runs. Tried
## again on the flush timer: the game may start Steam after the SDK.
func _try_steam_link() -> void:
	if _steam_link_tries <= 0 or _steam_link_done or not _identity_active or _server_quiet:
		return
	_steam_link_tries -= 1
	if not Engine.has_singleton("Steam"):
		_steam_link_tries = 0  # No GodotSteam addon: nothing to do.
		return
	if _steam_id() == "":
		return  # Steam is not running yet.
	_steam_link_tries = 0
	_request_steam_ticket()


func _request_steam_ticket() -> void:
	if _link_in_flight or not Engine.has_singleton("Steam"):
		return
	var steam: Object = Engine.get_singleton("Steam")
	if steam == null or not steam.has_method("getAuthTicketForWebApi") or not steam.has_signal("get_ticket_for_web_api"):
		return
	if steam.has_method("isSteamRunning") and not bool(steam.call("isSteamRunning")):
		return
	_steam_link_done = true
	_link_in_flight = true
	if not steam.is_connected("get_ticket_for_web_api", _on_steam_ticket):
		steam.connect("get_ticket_for_web_api", _on_steam_ticket)
	_steam_ticket_handle = int(steam.call("getAuthTicketForWebApi", STEAM_TICKET_IDENTITY))
	if _steam_ticket_handle == 0:
		steam.disconnect("get_ticket_for_web_api", _on_steam_ticket)
		_link_finished(false, 0, "STEAM_TICKET")


## GodotSteam: get_ticket_for_web_api(auth_ticket, result, ticket_size, ticket_buffer).
func _on_steam_ticket(auth_ticket: int, result: int, ticket_size: int, ticket_buffer: PackedByteArray) -> void:
	if auth_ticket != _steam_ticket_handle:
		return  # A ticket that the game asked for itself.
	_steam_ticket_handle = 0
	var steam: Object = Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	if steam != null and steam.is_connected("get_ticket_for_web_api", _on_steam_ticket):
		steam.disconnect("get_ticket_for_web_api", _on_steam_ticket)
	var bytes := ticket_buffer.slice(0, ticket_size) if ticket_size > 0 else ticket_buffer
	if result != STEAM_RESULT_OK or bytes.size() < 16 or bytes.size() > 2048:
		if _options.debug:
			print("Manalens: Steam gave no Web API ticket (result %d)" % result)
		_link_finished(false, 0, "STEAM_TICKET")
		return
	_send_link(bytes.hex_encode())


func _send_link(ticket_hex: String) -> void:
	if not _identity_active or _anonymous_id == "":
		_link_finished(false, 0, "CONSENT_REQUIRED")
		return
	_steam_link_done = true
	_link_in_flight = true
	_link_attempt = 0
	_link_anonymous_id = _anonymous_id
	_link_body = JSON.stringify({"provider": "steam", "ticket": ticket_hex, "anonymous_id": _anonymous_id})
	_link_request()


func _link_request() -> void:
	var headers := PackedStringArray(["Content-Type: application/json", "x-publishable-key: %s" % _options.publishable_key])
	_link_send(_link_url(), headers, _link_body)


## The HTTP call of link_steam(). Tests replace it.
func _link_send(url: String, headers: PackedStringArray, body: String) -> void:
	if _link_http == null or _link_http.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
		_on_link_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


## Run `callback` after `seconds`. Tests replace it.
func _link_after(seconds: float, callback: Callable) -> void:
	get_tree().create_timer(seconds).timeout.connect(callback)


func _link_url() -> String:
	var base := String(_options.api_endpoint).trim_suffix("/")
	if base == "":
		base = String(_options.endpoint).trim_suffix("/")
		var scheme := base.find("://")
		if scheme >= 0 and base.substr(scheme + 3).begins_with("events."):
			base = base.left(scheme + 3) + "api." + base.substr(scheme + 3 + "events.".length())
	return base + "/v0/link"


func _on_link_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_link_finished(false, 0, "NETWORK_ERROR")
		return
	if code >= 200 and code < 300:
		if _options.debug:
			print("Manalens: Steam account linked")
		_link_finished(true, code, "")
		return
	var wait := _retry_after_seconds(headers)
	if code == 429 and _link_attempt == 0 and wait >= 0.0 and wait <= LINK_MAX_RETRY_AFTER_S:
		_link_attempt = 1
		_link_after(wait, _link_retry)
		return
	var error_code := ""
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("error")) == TYPE_DICTIONARY:
		error_code = String(parsed.error.get("code", ""))
	push_warning("Manalens: link_steam() failed (HTTP %d%s)" % [code, "" if error_code == "" else " " + error_code])
	_link_finished(false, code, error_code)


func _link_finished(linked: bool, status: int, code: String) -> void:
	_link_in_flight = false
	steam_linked.emit(linked, status, code)


## The one retry after a 429. Only with the same gates as the first send: after
## set_consent(false), an opt-out or reset() the old ticket and ID are not sent.
func _link_retry() -> void:
	if _disabled or not _identity_active or not _identity_allowed():
		_link_finished(false, 0, "CONSENT_REQUIRED")
		return
	if _anonymous_id != _link_anonymous_id:
		_link_finished(false, 0, "IDENTITY_CHANGED")
		return
	_link_request()


## Retry-After in seconds (a number of seconds or an HTTP date), or -1 without the header.
func _retry_after_seconds(headers: PackedStringArray) -> float:
	for header in headers:
		var colon := String(header).find(":")
		if colon > 0 and String(header).substr(0, colon).strip_edges().to_lower() == "retry-after":
			return _parse_retry_after(headers, _now())
	return -1.0


## Forget the player: ends the session, clears user_id, makes a new anonymous ID
## and starts a new session.
func reset() -> void:
	_deferred_traits.clear()
	_steam_link_pending = null
	if not _identity_active:
		_user_id = ""
		_deferred_identify = null
		_clear_error_history()
		return
	_end_session(_now())  # Sends errors_dropped of the old session.
	_clear_error_history()
	_user_id = ""
	_anonymous_id = _uuid()
	_cfg.set_value("identity", "user_id", "")
	_cfg.set_value("identity", "user_id_source", "")
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
	_deferred_traits.clear()
	_steam_link_pending = null
	_anonymous_id = ""
	_user_id = ""
	_session_id = ""
	for key in ["anonymous_id", "user_id", "user_id_source", "first_open_at"]:
		if _cfg.has_section_key("identity", key):
			_cfg.erase_section_key("identity", key)
	if _cfg.has_section("session"):
		_cfg.erase_section("session")
	_save_cfg()
	_queue.clear()
	if _store_exists(QUEUE_PATH):
		_store_remove(QUEUE_PATH)
	_clear_error_history()


## Event names and error counts of the old player must never reach a later error.
func _clear_error_history() -> void:
	_breadcrumbs.clear()
	_error_seen.clear()
	_error_times.clear()
	_errors_dropped = 0


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
	# sent_at: the device clock now. The collector corrects the event times with it, so a wrong clock gives right times (P-2799).
	var error := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify({"events": batch, "sent_at": _iso(_now())}))
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
	if not Engine.is_editor_hint():
		_auto_init.call_deferred()


## Project Settings > Manalens: start the SDK when a key is set and auto_init
## is on. Runs after the _ready() of the first scene, so a game that calls
## init() there keeps its own options.
func _auto_init() -> void:
	if _initialized or not bool(Settings.get_value("auto_init")):
		return
	if String(Settings.get_value("publishable_key")).strip_edges() == "":
		return
	if _options.debug:
		print("Manalens: starting from Project Settings")
	init()


## Send the errors that the engine logger collected (main thread).
func _process(_delta: float) -> void:
	if _error_logger == null:
		return
	var taken: Array = _error_logger.take()
	var items: Array = taken[0]
	_errors_dropped += int(taken[1]) + maxi(0, items.size() - AUTO_ERRORS_PER_FRAME)
	for item in items.slice(0, AUTO_ERRORS_PER_FRAME):
		var kind := String(item.kind)
		# A log line can hold paths, URLs, emails, and tokens: clean it before it
		# is queued. The fingerprint is computed from the cleaned text, so the
		# same error on two machines with different user names groups together.
		_record_error(_clean_log_message(String(item.message), _home_dirs()), {
			"severity": "warning" if kind == "warning" else "error",
			"error_type": "engine_warning" if kind == "warning" else ("script_error" if kind == "script" else "engine_error"),
			"handled": false,
			"stack": String(item.stack),
			"file": String(item.file),
			"line": int(item.line),
			"function": String(item.function),
			"properties": {"log_type": kind},
		}, SOURCE_AUTO)


func _on_tick() -> void:
	if _optout_pending:
		_write_optout()
	if not _identity_active:
		return
	# While the game has focus the player is active: keep the session alive.
	# Only an open one: during shutdown() a tick must not start a new session.
	if _focused and _session_id != "":
		_touch()
	_try_auto_identify()
	_try_steam_link()
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
		if not _server_quiet and not bool(_cfg.get_value("session", "exited", false)) and bool(_cfg.get_value("session", "focused", true)) and _platform() != "web":
			var crash := {"previous_session_id": previous}
			for key in ["build", "app_version"]:
				var value := String(_cfg.get_value("session", key, ""))
				if value != "":
					crash["previous_" + key] = value
			_enqueue(_build("track", "app_crash", crash, _last_activity_at))
		_end_session(_last_activity_at)
	_start_session(now)
	if not _server_quiet:
		_enqueue(_build("track", "game_open", {"is_first_open": first_open, "first_open_at": String(_cfg.get_value("identity", "first_open_at", _iso(now)))}))
	_save_cfg()
	# Write game_open (the install signal) and app_crash to disk before
	# any send: a process killed before the next save would lose them.
	_save_queue()
	if _deferred_identify != null:
		var pending: Array = _deferred_identify
		_deferred_identify = null
		_identify(pending[0], pending[1], "game")
	if not _deferred_traits.is_empty():
		var held := _deferred_traits
		_deferred_traits = {}
		_send_traits(held)
	if _steam_link_pending != null:
		var link = _steam_link_pending
		_steam_link_pending = null
		if link is PackedByteArray:
			_send_link(link.hex_encode())
		else:
			_request_steam_ticket()
	# Next frame: an identify() that the game calls right after init() wins.
	_try_auto_identify.call_deferred()
	_try_steam_link.call_deferred()
	flush()


## auto_identify = "steam" (P-2513): identify the player by a salted hash of
## the SteamID64, once per launch, after consent. Needs the GodotSteam addon
## (the `Steam` singleton) and a running Steam client; without them it does
## nothing. Skipped when the game called identify() in this launch, when the
## saved user ID came from the game, and on a quiet server build.
func _try_auto_identify() -> void:
	if _auto_identify_tries <= 0 or _game_identified or not _identity_active or _server_quiet:
		return
	_auto_identify_tries -= 1
	if String(_cfg.get_value("identity", "user_id_source", "game" if _user_id != "" else "")) == "game":
		_auto_identify_tries = 0
		return
	if not Engine.has_singleton("Steam"):
		_auto_identify_tries = 0  # No GodotSteam addon: nothing to do.
		return
	var steam_id := _steam_id()
	if steam_id == "":
		return  # Try again on the next tick: the game may start Steam later.
	_auto_identify_tries = 0
	_identify(steam_user_id(String(_options.publishable_key), steam_id), {"storefront": "steam"}, "steam")


## The SteamID64 of the signed-in Steam user as text, or "" when the GodotSteam
## addon is missing, Steam is not running, or the ID is 0. Never a hard
## dependency: the SDK looks the singleton up by name.
func _steam_id() -> String:
	if not Engine.has_singleton("Steam"):
		return ""
	var steam: Object = Engine.get_singleton("Steam")
	if steam == null or not steam.has_method("getSteamID"):
		return ""
	if steam.has_method("isSteamRunning") and not bool(steam.call("isSteamRunning")):
		return ""
	var id = steam.call("getSteamID")
	if (typeof(id) != TYPE_INT and typeof(id) != TYPE_STRING) or String.num_int64(int(id)) == "0":
		return ""
	return String.num_int64(int(id))


## The user ID of auto_identify: "steam_" and the SHA-256 (hex) of
## "<publishable_key>:<SteamID64>". The key is the per-project salt: the same
## player gets the same ID in one project and a different ID in another. This
## is pseudonymous, not anonymous: the key ships in the game and SteamIDs are
## few, so the hash can be reversed by brute force.
static func steam_user_id(publishable_key: String, steam_id64: String) -> String:
	return "steam_" + ("%s:%s" % [publishable_key, steam_id64]).sha256_text()


func _start_session(at: float) -> void:
	_session_id = _uuid()
	_session_started_at = at
	_last_activity_at = at
	_auto_errors = 0
	_save_session()
	if not _server_quiet:
		_enqueue(_build("track", "session_start", {}, at))


func _end_session(at: float) -> void:
	if _session_id == "":
		return
	var duration := maxf(0.0, at - _session_started_at)
	var ended := {"duration_s": int(round(duration))}
	if _errors_dropped > 0:
		ended["errors_dropped"] = _errors_dropped
		_errors_dropped = 0
	if not _server_quiet:
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
	var platform := String(_options.platform)
	var app := {"platform": platform if platform != "" else _platform(), "engine": "godot"}
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


## Queues an event after before_send. Returns false when before_send dropped it.
func _enqueue(entry: Dictionary) -> bool:
	var envelope = _apply_before_send(entry.event)
	if envelope == null:
		if _options.debug:
			print("Manalens: before_send dropped %s %s" % [entry.event.type, entry.event.get("event", "")])
		return false
	entry.event = envelope
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
	return true


## Runs before_send on a copy of the envelope. Returns the envelope to queue,
## or null to drop it.
func _apply_before_send(envelope: Dictionary) -> Variant:
	if not _before_send.is_valid():
		return envelope
	if _in_before_send:
		push_warning("Manalens: an event recorded inside before_send is dropped")
		return null
	_in_before_send = true
	var changed = _before_send.call(envelope.duplicate(true))
	_in_before_send = false
	if changed == null:
		return null
	if typeof(changed) != TYPE_DICTIONARY:
		push_warning("Manalens: before_send must return a Dictionary or null; event dropped")
		return null
	var out := envelope.duplicate()
	var ok := true
	for key in ["type", "message_id", "anonymous_id", "session_id"]:
		if envelope.has(key) != changed.has(key) or (envelope.has(key) and str(changed[key]) != str(envelope[key])):
			ok = false
	var context = changed.get("context")
	if typeof(context) != TYPE_DICTIONARY or typeof(context.get("app")) != TYPE_DICTIONARY or context.app != envelope.context.app:
		ok = false
	if envelope.has("event"):
		var name = changed.get("event")
		if (typeof(name) != TYPE_STRING and typeof(name) != TYPE_STRING_NAME) or String(name).length() < 1 or String(name).length() > 128:
			ok = false
		else:
			out["event"] = String(name)
	for field in ["properties", "traits"]:
		if envelope.has(field):
			if typeof(changed.get(field, {})) != TYPE_DICTIONARY:
				ok = false
			else:
				out[field] = _fit(_scalars(changed.get(field, {})), field)
	var user = changed.get("user_id")
	var user_is_text := typeof(user) == TYPE_STRING or typeof(user) == TYPE_STRING_NAME
	if user == null or (user_is_text and String(user) == ""):
		out.erase("user_id")
	elif user_is_text and String(user).length() <= 255:
		out["user_id"] = String(user)
	else:
		ok = false
	if envelope.type == "identify" and not out.has("user_id"):
		ok = false
	if not ok:
		push_warning("Manalens: before_send changed or removed type, message_id, anonymous_id, session_id, context.app, or gave a wrong event, properties, traits or user_id; the original event is sent")
		return envelope
	return out


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


## The wait in seconds that the Retry-After header of a response asks for: an
## integer number of seconds, or an HTTP date (then the time until that date).
## A missing or invalid value, or a date in the past, gives 0. Not capped:
## _retry_wait() applies MAX_RETRY_AFTER_S.
func _parse_retry_after(headers: PackedStringArray, now: float) -> float:
	var value := ""
	var found := false
	for line in headers:
		var colon := line.find(":")
		if colon > 0 and line.substr(0, colon).strip_edges().to_lower() == "retry-after":
			value = line.substr(colon + 1).strip_edges()
			found = true
			break
	if not found or value == "":
		return 0.0
	var digits := true
	for c in value:
		if c < "0" or c > "9":
			digits = false
			break
	if digits:
		return value.to_float()
	# An HTTP date: "Wed, 21 Oct 2026 07:28:00 GMT".
	var parts := value.replace(",", " ").split(" ", false)
	if parts.size() != 6 or parts[5].to_upper() != "GMT":
		return 0.0
	var month := HTTP_MONTHS.find(parts[2].to_lower())
	var clock := parts[4].split(":")
	if month < 0 or not parts[1].is_valid_int() or not parts[3].is_valid_int() or clock.size() != 3:
		return 0.0
	for piece in clock:
		if not piece.is_valid_int():
			return 0.0
	var day := int(parts[1])
	var hour := int(clock[0])
	var minute := int(clock[1])
	var second := int(clock[2])
	if day < 1 or day > 31 or hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 60:
		return 0.0
	var at := Time.get_unix_time_from_datetime_dict({"year": int(parts[3]), "month": month + 1, "day": day, "hour": hour, "minute": minute, "second": second})
	return maxf(0.0, float(at) - now)


## The wait before the next try after a retried response: the backoff with
## jitter, or the Retry-After of the response when it is longer (at most 1 hour).
func _retry_wait(backoff: float, headers: PackedStringArray, now: float) -> float:
	return maxf(backoff, minf(MAX_RETRY_AFTER_S, _parse_retry_after(headers, now)))


func _on_request_completed(result: int, code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
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
		# Wait at least what the collector asks for (Retry-After on a 429 or 503), at most 1 hour.
		var wait := _retry_wait(delay * randf_range(0.5, 1.0), headers, _now())
		_backoff_until = _now() + wait
		if _options.debug:
			print("Manalens: send failed (result %d, HTTP %d); retry in %.0f s" % [result, code, wait])
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
		if source == SOURCE_MANUAL:
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
	_touch()
	# before_send runs in _enqueue, after the fingerprint and the limits.
	if not _enqueue(_build("track", "error", props)):
		return
	if source == SOURCE_AUTO:
		_auto_errors += 1
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
	if source == SOURCE_AUTO and _auto_errors >= int(_options.max_auto_errors_per_session):
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


# Cleaning of captured engine messages (the rules of the Unreal plugin) --------

## The player's home folder, as the OS names it. Paths under it become ~.
func _home_dirs() -> Array:
	var dirs := []
	for name in ["HOME", "USERPROFILE"]:
		var value := OS.get_environment(name)
		if value != "":
			dirs.append(value)
	return dirs


## Removes personal data from an engine log message: the home folder and
## /Users/<name>, /home/<name>, X:\Users\<name> become ~; URLs lose their
## user, query, and fragment; emails become [email]; the values after key=,
## token=, secret=, password=, authorization: and bearer, and runs of 24 or
## more letters, digits, _ and - become [redacted]. track_error() text is not
## changed.
func _clean_log_message(message: String, home_dirs: Array) -> String:
	var text := message
	for dir in home_dirs:
		text = _clean_dir(text, String(dir))
	text = _clean_home_patterns(text)
	text = _clean_urls(text)
	text = _clean_emails(text)
	text = _clean_key_values(text)
	return _clean_long_tokens(text)


static func _is_alnum(c: int) -> bool:
	return (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)


static func _is_separator(c: int) -> bool:
	return c == 47 or c == 92  # / and \


static func _is_token_char(c: int) -> bool:
	return _is_alnum(c) or c == 95 or c == 45  # _ and -


## Whitespace, quotes, < > ( ): the end of a path, URL, or value.
static func _is_end(c: int) -> bool:
	return c in [32, 9, 10, 11, 12, 13, 34, 39, 60, 62, 40, 41]


static func _is_email_local(c: int) -> bool:
	return _is_alnum(c) or c in [46, 95, 37, 43, 45]  # . _ % + -


static func _is_email_domain(c: int) -> bool:
	return _is_alnum(c) or c == 46 or c == 45


## Each occurrence of a directory (and so the path under it) becomes ~.
func _clean_dir(text: String, dir: String) -> String:
	dir = dir.replace("\\", "/")
	while dir.length() > 0 and _is_separator(dir.unicode_at(dir.length() - 1)):
		dir = dir.left(-1)
	if dir.length() < 3:
		return text
	for form in [dir, dir.replace("/", "\\")]:
		var from := 0
		while true:
			var at := text.findn(form, from)
			if at < 0:
				break
			var end: int = at + form.length()
			if end < text.length() and not _is_separator(text.unicode_at(end)) and not _is_end(text.unicode_at(end)):
				from = end  # A longer name, for example /Users/annabel for /Users/anna.
				continue
			text = text.left(at) + "~" + text.substr(end)
			from = at + 1
	return text


## /Users/<name>, /home/<name>, and X:\Users\<name> become ~.
func _clean_home_patterns(text: String) -> String:
	var out := PackedStringArray()
	var index := 0
	var start := 0
	while index < text.length():
		var name_at := -1
		var rest := text.substr(index, 9).to_lower()
		var boundary := index == 0 or not (_is_alnum(text.unicode_at(index - 1)) or text.unicode_at(index - 1) == 95)
		if rest.begins_with("/users/"):
			name_at = index + 7
		elif rest.begins_with("/home/"):
			name_at = index + 6
		elif boundary and rest.length() == 9 and rest.unicode_at(0) >= 97 and rest.unicode_at(0) <= 122 and rest.unicode_at(1) == 58 \
				and _is_separator(rest.unicode_at(2)) and rest.substr(3, 5) == "users" and _is_separator(rest.unicode_at(8)):
			name_at = index + 9
		if name_at >= 0:
			var end := name_at
			while end < text.length() and not _is_separator(text.unicode_at(end)) and not _is_end(text.unicode_at(end)):
				end += 1
			if end > name_at:
				out.append(text.substr(start, index - start))
				out.append("~")
				index = end
				start = end
				continue
		index += 1
	out.append(text.substr(start))
	return "".join(out)


## scheme://user:pass@host/path?query#fragment becomes scheme://host/path.
func _clean_urls(text: String) -> String:
	var from := 0
	while true:
		var at := text.find("://", from)
		if at < 0:
			break
		var end := at + 3
		while end < text.length() and not _is_end(text.unicode_at(end)):
			end += 1
		var rest := text.substr(at + 3, end - at - 3)
		for index in rest.length():
			if rest.unicode_at(index) == 63 or rest.unicode_at(index) == 35:  # ? and #
				rest = rest.left(index)
				break
		var slash := rest.find("/")
		var authority := rest if slash < 0 else rest.left(slash)
		var path := "" if slash < 0 else rest.substr(slash)
		var at_sign := authority.rfind("@")
		if at_sign >= 0:
			authority = authority.substr(at_sign + 1)
		var clean := authority + path
		text = text.left(at + 3) + clean + text.substr(end)
		from = at + 3 + clean.length()
	return text


func _clean_emails(text: String) -> String:
	var at := 0
	while at < text.length():
		if text.unicode_at(at) == 64:  # @
			var start := at
			while start > 0 and _is_email_local(text.unicode_at(start - 1)):
				start -= 1
			var end := at + 1
			while end < text.length() and _is_email_domain(text.unicode_at(end)):
				end += 1
			while end > at + 1 and (text.unicode_at(end - 1) == 46 or text.unicode_at(end - 1) == 45):
				end -= 1  # A full stop after the address.
			if start < at and text.substr(at + 1, end - at - 1).contains("."):
				text = text.left(start) + "[email]" + text.substr(end)
				at = start + 6
		at += 1
	return text


## The value after key, token, secret, password, or authorization with = or :
## (also the JSON form "token": "...") and after bearer. A quoted value is
## redacted up to its closing quote.
func _clean_key_values(text: String) -> String:
	const REDACTED := "[redacted]"
	# bearer first, so "token: Bearer abc" loses both words.
	for name in ["bearer", "authorization", "key", "token", "secret", "password"]:
		var from := 0
		while true:
			var at := text.findn(name, from)
			if at < 0:
				break
			var start: int = at + name.length()
			if name == "bearer":
				if start >= text.length() or text.unicode_at(start) != 32:
					from = at + 1
					continue
			else:
				if start < text.length() and text.unicode_at(start) in [34, 39]:
					start += 1  # the closing quote of a JSON key
				while start < text.length() and text.unicode_at(start) == 32:
					start += 1
				if start >= text.length() or not (text.unicode_at(start) in [58, 61]):  # : and =
					from = at + 1
					continue
				start += 1
			while start < text.length() and text.unicode_at(start) == 32:
				start += 1
			var end := start
			if start < text.length() and text.unicode_at(start) in [34, 39]:
				# A quoted value: up to the closing quote (or the end of the text).
				var quote := text.substr(start, 1)
				start += 1
				end = text.find(quote, start)
				if end < 0:
					end = text.length()
			elif name == "authorization":
				# Authorization: <scheme> <credentials>, to the end of the line.
				while end < text.length() and not (text.unicode_at(end) in [10, 13, 34, 39]):
					end += 1
			else:
				while end < text.length() and not _is_end(text.unicode_at(end)) and not (text.unicode_at(end) in [38, 44, 59, 93, 125]):  # & , ; ] }
					end += 1
			if end > start and text.substr(start, end - start) != REDACTED:
				text = text.left(start) + REDACTED + text.substr(end)
				end = start + REDACTED.length()
			from = maxi(end, at + 1)
	return text


static func _is_base64_char(c: int) -> bool:
	return _is_token_char(c) or c == 43 or c == 47 or c == 61  # + / =


## Keys, tokens, and IDs: a JWT (eyJ... with two dots), a base64 run of 24 or
## more characters with + or a trailing =, and runs of 24 or more characters
## from A-Z, a-z, 0-9, _, and -. File paths (with / but no + or =) stay.
func _clean_long_tokens(text: String) -> String:
	var out := PackedStringArray()
	var index := 0
	var start := 0
	while index < text.length():
		var end := index
		while end < text.length() and _is_token_char(text.unicode_at(end)):
			end += 1
		var redact_to := -1
		if text.substr(index, 3) == "eyJ":
			var jwt_end := index
			var dots := 0
			while jwt_end < text.length() and (_is_token_char(text.unicode_at(jwt_end)) or text.unicode_at(jwt_end) == 46):
				if text.unicode_at(jwt_end) == 46:
					dots += 1
				jwt_end += 1
			while jwt_end > index and text.unicode_at(jwt_end - 1) == 46:
				jwt_end -= 1  # a full stop after the token
				dots -= 1
			if dots >= 2:
				redact_to = jwt_end
		if redact_to < 0:
			var b64_end := index
			while b64_end < text.length() and _is_base64_char(text.unicode_at(b64_end)):
				b64_end += 1
			var run := text.substr(index, b64_end - index)
			if run.length() >= 24 and (run.contains("+") or run.ends_with("=")):
				redact_to = b64_end
		if redact_to < 0 and end - index >= 24:
			redact_to = end
		if redact_to >= 0:
			out.append(text.substr(start, index - start))
			out.append("[redacted]")
			start = redact_to
			index = redact_to
		elif end > index:
			index = end
		else:
			index += 1
	out.append(text.substr(start))
	return "".join(out)


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
