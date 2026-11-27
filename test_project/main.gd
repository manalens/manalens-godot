extends Node
## Headless SDK test. Arguments after `--`:
##   --endpoint=URL       the collector (required)
##   --publishable-key=KEY  a project publishable key (required)
##   --mode=MODE          offline (default), consent, recovery, errors, link, session_age, web_reload, install_kill, shutdown_tick, editor_setup, disabled, overflow, optout, corrupt, marker, fixtures, privacy, before_send, server, auto_identify, platform, traits or steam_link
##   In a web export, the same arguments come from the page URL (?mode=web_id&endpoint=...&publishable-key=...).
##   --run-id=ID          tag for the events (default: random)
##
## offline:  fresh state; queue events against a dead endpoint, check they are
##           on disk, switch to the real endpoint, flush, shut down.
## consent:  fresh state with consent_required; events before consent are not
##           queued and no ID is stored; then set_consent(true).
## recovery: keeps the ID; plants a session that was left open 2 hours ago (a
##           crash) and checks that init ends it with session_end and sends
##           app_crash.
## errors:   fresh state; track_error, before_send, the dedupe limit and an
##           engine error from push_error (Godot 4.5+ logger).
##
## link:     link_url() before and after consent (handoff parameter, query and
##           fragment kept); needs no network.
##
## session_age: a session that is 24 hours old ends and a new one starts; every
##           queued event has a session ID that is not the anonymous ID; the
##           reason of a refusal is read from the response body; properties are
##           trimmed to 50 keys and 8 KB (P-2700). Needs no network.
##
## web_reload: a launch that ends without a quit (a reloaded or closed tab), then
##           a second launch. On web: no app_crash; on windows (the
##           control): one. The old session ends in both. Needs no network.
##
## install_kill: a first launch with no network is killed before any send, tick,
##           focus loss or quit. game_open (is_first_open) is on disk at once,
##           and the next launch, 3 days later, still has it with its original
##           time (P-2773, G-2522). Needs no network.
##
## shutdown_tick: shutdown() waits for a send that never ends while the tick
##           timer fires and the window gets focus. No new session starts
##           after session_end. Needs no network.
##
## editor_setup: Project Settings > Manalens (G-2532). With a key and auto_init
##           the SDK starts by itself at the end of the frame; init() options
##           override the settings; auto_init off starts nothing; the dock's
##           key check; the dock's test event reaches the collector (HTTP 202)
##           when --endpoint is a real collector.
##
## web_id, web_optout, web_after_optout, web_legacy: web export only
##           (scripts/test-godot-web.mjs, P-2791). web_id starts the SDK and
##           prints the anonymous ID at once; the script reloads the page then.
##           web_optout opts out; web_after_optout (the next load) checks that
##           the opt-out is kept. web_legacy: a state file of SDK 0.1.0 moves to
##           localStorage and keeps its anonymous ID.
##
## fixtures: the shared fixture scenario of the delivery contract (the steps of the Unity
##           FixtureTests) with a fixed clock and sequential IDs. The endpoint
##           is the capture server of test_project/run-tests.mjs
##           (pnpm test:godot), which writes or checks the request bodies.
##
## Prints one line `MANALENS_RESULT {json}` and exits 0 on success, 1 on failure.

const OFFLINE_ENDPOINT := "http://127.0.0.1:9"
var _args := {}
var _failures: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := String(arg).trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else "true"
	if OS.has_feature("web"):
		var search := str(JavaScriptBridge.eval("location.search", true)).trim_prefix("?")
		for part in search.split("&", false):
			var pair := part.split("=", true, 1)
			if pair.size() == 2:
				_args[pair[0].uri_decode()] = pair[1].uri_decode()
	if not _args.has("endpoint") or not _args.has("publishable-key"):
		_finish({"error": "pass -- --endpoint=URL --publishable-key=KEY"})
		return
	var run_id := String(_args.get("run-id", str(randi())))
	var mode := String(_args.get("mode", "offline"))
	var result := {"mode": mode, "run_id": run_id}
	match mode:
		"offline": await _offline(run_id, result)
		"consent": await _consent(run_id, result)
		"recovery": await _recovery(run_id, result)
		"errors": await _errors(run_id, result)
		"link": await _link(run_id, result)
		"session_age": await _session_age(run_id, result)
		"web_reload": await _web_reload(run_id, result)
		"install_kill": _install_kill(result)
		"shutdown_tick": await _shutdown_tick(result)
		"editor_setup": await _editor_setup(result)
		"web_id": _web_id(result)
		"web_optout": _web_optout(result)
		"web_after_optout": _web_after_optout(result)
		"web_legacy": _web_legacy(result)
		"disabled": await _disabled(run_id, result)
		"overflow": await _overflow(run_id, result)
		"optout": await _optout(run_id, result)
		"corrupt": await _corrupt(run_id, result)
		"marker": await _marker(run_id, result)
		"fixtures": await _fixtures(run_id, result)
		_: await _more_modes(mode, result)
	_finish(result)


func _options(endpoint: String, consent_required := false) -> Dictionary:
	var options := {
		"endpoint": endpoint,
		"app_version": "0.1.0-test", "build": "godot-test", "storefront": "itch",
		"consent_required": consent_required, "flush_interval_s": 1.0,
		"quit_timeout_s": 5.0, "debug": _args.has("debug"),
		"publishable_key": _args["publishable-key"],
	}
	return options


func _offline(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	sdk.init(_options(OFFLINE_ENDPOINT))
	sdk.track("level_start", {"level": 1, "attempt": 1, "run_id": run_id})
	sdk.track("level_complete", {"level": 1, "attempt": 1, "score": 1200, "run_id": run_id})
	sdk.track("resource", {"flow": "source", "currency": "gold", "amount": 25, "item": "chest", "run_id": run_id, "nested": {"dropped": true}})
	sdk.identify("player-%s" % run_id, {"plan": "test"})
	# Wait for two failed sends to the dead endpoint (the second after a backoff).
	if not await _wait_for(func(): return not sdk.is_sending() and sdk._failures >= 2, 10.0):
		_failures.append("no retry while offline")
	sdk._save_queue()
	var queued: int = sdk.get_queue_size()
	result["offline_queued"] = queued
	result["offline_queue_on_disk"] = _queue_on_disk()
	_check(queued >= 6, "expected at least 6 queued events offline, got %d" % queued)
	_check(result.offline_queue_on_disk == queued, "queue file has %d events, memory has %d" % [result.offline_queue_on_disk, queued])
	# Back online.
	sdk.set_endpoint(String(_args["endpoint"]))
	sdk.flush()
	if not await _wait_for(func(): return sdk.get_queue_size() == 0 and not sdk.is_sending(), 15.0):
		_failures.append("queue did not drain online (%d left)" % sdk.get_queue_size())
	sdk.track("test_done", {"run_id": run_id})
	await sdk.shutdown()
	result["after_shutdown_queue"] = sdk.get_queue_size()
	_check(sdk.get_queue_size() == 0, "events left after shutdown")
	result["anonymous_id"] = sdk.get_anonymous_id()


func _consent(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"]), true))
	sdk.track("before_consent", {"run_id": run_id})
	sdk.identify("consent-%s" % run_id, {})
	result["queued_before_consent"] = sdk.get_queue_size()
	result["id_before_consent"] = sdk.get_anonymous_id()
	_check(sdk.get_queue_size() == 0, "events were queued before consent")
	_check(sdk.get_anonymous_id() == "", "an anonymous ID exists before consent")
	_check(not _stored_anonymous_id(), "an anonymous ID was stored before consent")
	sdk.set_consent(true)
	sdk.track("after_consent", {"run_id": run_id})
	await sdk.shutdown()
	_check(sdk.get_queue_size() == 0, "events left after shutdown")
	result["anonymous_id"] = sdk.get_anonymous_id()


func _link(_run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	sdk.init(_options(OFFLINE_ENDPOINT, true))
	var url := "https://example.com/wiki"
	_check(sdk.link_url(url) == url, "link_url added an ID before consent")
	sdk.set_consent(true)
	var id: String = sdk.get_anonymous_id()
	var before := int(Time.get_unix_time_from_system())
	var plain: String = sdk.link_url(url)
	var query: String = sdk.link_url("https://example.com/wiki?page=2#boss")
	var after := int(Time.get_unix_time_from_system())
	result["plain"] = plain
	result["query"] = query
	var prefix := url + "?mana_hid=" + id + "."
	_check(plain.begins_with(prefix), "plain link: %s" % plain)
	var at := int(plain.trim_prefix(prefix))
	_check(at >= before and at <= after, "handoff time %d is not now" % at)
	_check(query.begins_with("https://example.com/wiki?page=2&mana_hid=" + id + ".") and query.ends_with("#boss"), "query link: %s" % query)
	sdk.reset()
	_check(not sdk.link_url(url).contains(id), "link_url kept the old ID after reset()")
	await sdk.shutdown()


## An HTTP date (RFC 9110 IMF-fixdate) for a Unix time.
func _http_date(unix: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(unix)
	var days := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s, %02d %s %d %02d:%02d:%02d GMT" % [days[d.weekday], d.day, months[d.month - 1], d.year, d.hour, d.minute, d.second]


func _session_age(_run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	sdk.init(_options(OFFLINE_ENDPOINT))
	var first: String = sdk.get_session_id()
	# 23 hours old: the same session.
	sdk._session_started_at = sdk._now() - 23.0 * 3600.0
	sdk.track("before_a_day", {})
	_check(sdk.get_session_id() == first, "the session changed before it was 24 hours old")
	# 24 hours old: session_end, then a new session.
	sdk._session_started_at = sdk._now() - 24.0 * 3600.0
	sdk.track("after_a_day", {})
	var second: String = sdk.get_session_id()
	_check(second != first and second != "", "no new session at 24 hours")
	var by_name := {}
	for entry in sdk._queue:
		var event: Dictionary = entry.event
		_check(String(event.get("session_id", "")) != "", "%s has no session_id" % String(event.get("event", event.type)))
		_check(String(event.get("session_id", "")) != String(event.anonymous_id), "%s has the anonymous ID as its session_id" % String(event.get("event", event.type)))
		if not by_name.has(String(event.get("event", ""))):
			by_name[String(event.get("event", ""))] = []
		by_name[String(event.get("event", ""))].append(event)
	_check(by_name.get("session_start", []).size() == 2, "expected 2 session_start events")
	var ends: Array = by_name.get("session_end", [])
	_check(ends.size() == 1 and String(ends[0].session_id) == first, "session_end is not in the first session")
	if ends.size() == 1:
		result["first_session_duration_s"] = int(ends[0].properties.duration_s)
		_check(int(ends[0].properties.duration_s) >= 86400, "the first session is shorter than 24 hours: %d s" % int(ends[0].properties.duration_s))
	_check(String(by_name.get("before_a_day", [{}])[0].get("session_id", "")) == first, "before_a_day is not in the first session")
	_check(String(by_name.get("after_a_day", [{}])[0].get("session_id", "")) == second, "after_a_day is not in the second session")
	# The reason of a refusal, as the collector sends it.
	var body := '{"error":{"code":"INVALID_EVENT","message":"1 of 2 events break the session ID contract. No event of the batch was accepted","refused":[{"index":1,"message_id":"x","code":"SESSION_ID_REQUIRED","message":"m"}]}}'
	var reason: String = sdk._refusal_reason(body.to_utf8_buffer())
	result["refusal_reason"] = reason
	_check(reason.contains("INVALID_EVENT") and reason.contains("SESSION_ID_REQUIRED"), "refusal reason: %s" % reason)
	_check(sdk._refusal_reason("not json".to_utf8_buffer()) == "", "a body that is not JSON gave a reason")
	# P-2794: Retry-After on a retried response (seconds or an HTTP date, at most 1 hour).
	var now := 1800000000.0
	var date_90 := Time.get_datetime_string_from_unix_time(int(now) + 90)
	var http_90 := _http_date(int(now) + 90)
	var retry_cases := [
		[PackedStringArray(["Content-Type: application/json", "Retry-After: 120"]), 120.0],
		[PackedStringArray(["retry-after:  60 "]), 60.0],
		[PackedStringArray(["RETRY-AFTER: 0"]), 0.0],
		[PackedStringArray(["Retry-After: %s" % http_90]), 90.0],
		[PackedStringArray(["Retry-After: %s" % _http_date(int(now) - 1000)]), 0.0],
		[PackedStringArray([]), 0.0],
		[PackedStringArray(["Retry-After: soon"]), 0.0],
		[PackedStringArray(["Retry-After: -5"]), 0.0],
		[PackedStringArray(["Retry-After: 1.5"]), 0.0],
		[PackedStringArray(["Retry-After: %s" % date_90]), 0.0],
		[PackedStringArray(["Retry-After: Wed, 99 Foo 2026 07:28:00 GMT"]), 0.0],
	]
	var parsed_retry := []
	for case in retry_cases:
		var got: float = sdk._parse_retry_after(case[0], now)
		parsed_retry.append(got)
		_check(is_equal_approx(got, float(case[1])), "Retry-After %s: %s, expected %s" % [case[0], got, case[1]])
	result["retry_after_parsed"] = parsed_retry
	# The wait: the backoff, or Retry-After when longer, at most 1 hour.
	_check(is_equal_approx(sdk._retry_wait(1.5, PackedStringArray(["Retry-After: 60"]), now), 60.0), "Retry-After 60 is not followed")
	_check(is_equal_approx(sdk._retry_wait(1.5, PackedStringArray(["Retry-After: 99999"]), now), 3600.0), "Retry-After is not capped at 1 hour")
	_check(is_equal_approx(sdk._retry_wait(1.5, PackedStringArray(["Retry-After: 1"]), now), 1.5), "a short Retry-After cut the backoff")
	_check(is_equal_approx(sdk._retry_wait(1.5, PackedStringArray([]), now), 1.5), "no Retry-After changed the backoff")
	_check(is_equal_approx(sdk._retry_wait(1.5, PackedStringArray(["Retry-After: later"]), now), 1.5), "an invalid Retry-After changed the backoff")
	# P-2787: refused events of an accepted batch.
	var partial := '{"accepted":1,"rejected":2,"errors":[{"index":1,"message_id":null,"code":"INVALID_EVENT","message":"m"},{"index":2,"message_id":null,"code":"SESSION_ID_REQUIRED","message":"m"}]}'
	var refused: Dictionary = sdk._refused_in_accepted(partial.to_utf8_buffer())
	result["refused_in_accepted"] = refused
	_check(int(refused.count) == 2 and String(refused.reason).contains("INVALID_EVENT") and String(refused.reason).contains("SESSION_ID_REQUIRED"), "refused in accepted: %s" % [refused])
	_check(int(sdk._refused_in_accepted('{"accepted":1}'.to_utf8_buffer()).count) == 0, "an older collector body gave refused events")
	_check(int(sdk._refused_in_accepted("not json".to_utf8_buffer()).count) == 0, "a body that is not JSON gave refused events")
	# P-2700: properties are trimmed to 50 keys and 8 KB of JSON.
	var many := {}
	for i in 60:
		many["k%d" % i] = i
	var fitted: Dictionary = sdk._fit(many, "properties")
	result["fit_keys"] = fitted.size()
	_check(fitted.size() == 50 and fitted.has("k49") and not fitted.has("k50"), "expected the first 50 keys, got %d" % fitted.size())
	var big := {}
	for i in 10:
		big["k%d" % i] = "€".repeat(1024)
	fitted = sdk._fit(big, "properties")
	result["fit_big_keys"] = fitted.size()
	_check(fitted.size() == 2 and JSON.stringify(fitted).to_utf8_buffer().size() <= 8192, "expected 2 keys of 3 KB, got %d" % fitted.size())
	_check(sdk._fit({"a": 1}, "properties").size() == 1, "a small object changed")


func _web_reload(_run_id: String, result: Dictionary) -> void:
	for script_path in ["res://web_sdk.gd", "res://fixture_sdk.gd"]:
		_fresh()
		var sdk_script = load(script_path)
		var first = sdk_script.new()
		add_child(first)
		first.init(_fixture_options(OFFLINE_ENDPOINT, {}))
		var session: String = first.get_session_id()
		first.clock += 25.0
		first._on_tick()  # Saves the session; then the tab is reloaded: no quit.
		first._timer.stop()
		first.set_process(false)
		if first._error_logger != null:
			OS.remove_logger(first._error_logger)
			first._error_logger = null
		first._initialized = false
		var second = sdk_script.new()
		second.clock = first.clock + 600.0
		second.next_id = first.next_id
		add_child(second)
		second.init(_fixture_options(OFFLINE_ENDPOINT, {}))
		var platform: String = second._platform()
		var crashes := 0
		var ended := 0
		for entry in second._queue:
			var event: Dictionary = entry.event
			if String(event.get("event", "")) == "app_crash":
				crashes += 1
			if String(event.get("event", "")) == "session_end" and String(event.session_id) == session:
				ended += 1
		result["%s_app_crash" % platform] = crashes
		_check(ended == 1, "%s: the old session did not end" % platform)
		if platform == "web":
			_check(crashes == 0, "web: a reload sent app_crash")
		else:
			_check(crashes == 1, "%s: no app_crash after a launch without a quit" % platform)
		first.queue_free()
		second._timer.stop()
		second.set_process(false)
		if second._error_logger != null:
			OS.remove_logger(second._error_logger)
			second._error_logger = null
		second._initialized = false
		second.queue_free()
	_fresh()


func _install_kill(result: Dictionary) -> void:
	_fresh()
	var sdk_script = load("res://fixture_sdk.gd")
	var first = sdk_script.new()
	add_child(first)
	first.init(_fixture_options(OFFLINE_ENDPOINT, {}))
	var opened: String = first.get_anonymous_id()
	var started: float = first.clock
	# Killed now: no send, no tick, no focus loss, no quit. Only the disk survives.
	_stop(first)
	var on_disk = JSON.parse_string(FileAccess.get_file_as_string("user://manalens_queue.json"))
	var saved := 0
	if typeof(on_disk) == TYPE_ARRAY:
		for entry in on_disk:
			if String(entry.event.get("event", "")) == "game_open" and bool(entry.event.properties.get("is_first_open", false)):
				saved += 1
	result["first_open_on_disk"] = saved
	_check(saved == 1, "game_open with is_first_open is not on disk before any send")
	var second = sdk_script.new()
	second.clock = started + 3 * 86400.0
	second.next_id = first.next_id
	add_child(second)
	second.init(_fixture_options(OFFLINE_ENDPOINT, {}))
	var opens: Array = []
	for entry in second._queue:
		if String(entry.event.get("event", "")) == "game_open":
			opens.append(entry.event)
	result["game_opens"] = opens.size()
	_check(opens.size() == 2, "expected 2 game_open events after the relaunch, got %d" % opens.size())
	if opens.size() == 2:
		_check(bool(opens[0].properties.is_first_open), "the first game_open lost is_first_open")
		_check(String(opens[0].original_timestamp) == "2027-01-15T08:00:00.000Z", "the first game_open has the time %s, not the time it happened" % opens[0].original_timestamp)
		_check(not bool(opens[1].properties.is_first_open), "the second game_open has is_first_open")
		_check(String(opens[0].anonymous_id) == opened and String(opens[1].anonymous_id) == opened, "the anonymous ID changed")
	_stop(second)
	first.queue_free()
	second.queue_free()
	_fresh()


func _shutdown_tick(result: Dictionary) -> void:
	_fresh()
	# A collector that accepts the connection and never answers: the send
	# stays open, so shutdown() waits its full 2.5 s while the 1 s tick fires.
	var server := TCPServer.new()
	_check(server.listen(0, "127.0.0.1") == OK, "could not listen")
	var sdk = load("res://fixture_sdk.gd").new()
	sdk.hold = false
	add_child(sdk)
	sdk.init(_fixture_options("http://127.0.0.1:%d" % server.get_local_port(), {"flush_interval_s": 1.0, "quit_timeout_s": 2.5}))
	# The window gets focus during the shutdown wait.
	get_tree().create_timer(0.5).timeout.connect(func(): sdk.notification(NOTIFICATION_APPLICATION_FOCUS_IN))
	await sdk.shutdown()
	server.stop()
	var names: Array = []
	for entry in sdk._queue:
		names.append(String(entry.event.get("event", entry.event.type)))
	result["queue"] = names
	_check(names.size() > 0 and names[-1] == "session_end", "the queue does not end with session_end: %s" % [names])
	_check(names.count("session_start") == 1, "a tick or a focus event during shutdown() started a new session: %s" % [names])
	_stop(sdk)
	sdk.queue_free()
	_fresh()


func _editor_setup(result: Dictionary) -> void:
	const Settings := preload("res://addons/manalens/settings.gd")
	const TestEvent := preload("res://addons/manalens/test_event.gd")
	var key := String(_args["publishable-key"])
	var endpoint := String(_args["endpoint"])
	var path := Settings.PREFIX
	# Key check of the dock.
	_check(Settings.key_problem("") != "", "an empty key passed")
	_check(Settings.key_problem("mana_sk_" + "a".repeat(51)).contains("secret"), "a secret key passed")
	_check(Settings.key_problem("mana_api_x").contains("API key"), "an API key passed")
	_check(Settings.key_problem("pk_live_x").contains("mana_pk_"), "a key without mana_pk_ passed")
	_check(Settings.key_problem("mana_pk_short").contains("length"), "a short key passed")
	_check(Settings.key_problem("mana_pk_" + "A".repeat(51)) == "", "a well-formed key failed")
	# Auto start from the settings.
	_fresh()
	ProjectSettings.set_setting(path + "publishable_key", "mana_pk_" + "A".repeat(51))
	ProjectSettings.set_setting(path + "endpoint", OFFLINE_ENDPOINT)
	ProjectSettings.set_setting(path + "build", "from-settings")
	ProjectSettings.set_setting(path + "storefront", "itch")
	var auto = load("res://fixture_sdk.gd").new()
	add_child(auto)
	_check(not auto._initialized, "the SDK started before the end of the frame")
	await get_tree().process_frame
	await get_tree().process_frame
	result["auto_started"] = auto._initialized
	_check(auto._initialized and auto._identity_active, "no automatic start with a key in Project Settings")
	_check(String(auto._options.build) == "from-settings" and String(auto._options.storefront) == "itch", "the settings were not used: %s" % [auto._options])
	_stop(auto)
	auto.queue_free()
	# init() before the end of the frame: its options win over the settings.
	_fresh()
	var own = load("res://fixture_sdk.gd").new()
	add_child(own)
	own.init({"build": "from-code"})
	await get_tree().process_frame
	await get_tree().process_frame
	_check(String(own._options.build) == "from-code", "init() options did not override the settings")
	_check(String(own._options.storefront) == "itch", "init() lost the storefront of the settings")
	_stop(own)
	own.queue_free()
	# auto_init off: nothing starts.
	_fresh()
	ProjectSettings.set_setting(path + "auto_init", false)
	var off = load("res://fixture_sdk.gd").new()
	add_child(off)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not off._initialized, "the SDK started with auto_init off")
	off.queue_free()
	for item in Settings.ITEMS:
		ProjectSettings.set_setting(path + item[0], null)
	_fresh()
	# The dock's test event.
	var body := TestEvent.body({"app_version": "1.0.0", "storefront": "itch"}, TestEvent.uuid(), TestEvent.platform(OS.get_name()), Time.get_unix_time_from_system())
	var event: Dictionary = JSON.parse_string(body).events[0]
	_check(event.event == "manalens_test_event" and event.context.app.build == "editor" and event.context.app.engine == "godot", "test event body: %s" % body)
	if endpoint == OFFLINE_ENDPOINT:
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request(TestEvent.url(endpoint), TestEvent.headers(key), HTTPClient.METHOD_POST, body)
	var response: Array = await http.request_completed
	var line := TestEvent.describe(response[0], response[1], response[3].get_string_from_utf8())
	result["test_event"] = line
	_check(response[1] == 202 and line.begins_with("Received"), "test event: %s" % line)
	http.request(TestEvent.url(endpoint), TestEvent.headers("mana_pk_" + "B".repeat(51)), HTTPClient.METHOD_POST, body)
	response = await http.request_completed
	result["test_event_bad_key"] = TestEvent.describe(response[0], response[1], response[3].get_string_from_utf8())
	_check(response[1] == 401, "a wrong key got HTTP %d" % response[1])
	http.queue_free()


func _stop(sdk) -> void:
	sdk._timer.stop()
	sdk.set_process(false)
	if sdk._error_logger != null:
		OS.remove_logger(sdk._error_logger)
		sdk._error_logger = null
	sdk._initialized = false


func _web_id(result: Dictionary) -> void:
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"])))
	result["anonymous_id"] = sdk.get_anonymous_id()
	result["web_storage"] = sdk._web_storage
	_check(sdk.get_anonymous_id() != "", "web_id: no anonymous ID")


func _web_optout(result: Dictionary) -> void:
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"])))
	_check(sdk.get_anonymous_id() != "", "web_optout: no anonymous ID before the opt-out")
	sdk.set_consent(false)
	_check(sdk.get_anonymous_id() == "", "web_optout: the ID is kept after set_consent(false)")
	result["web_storage"] = sdk._web_storage


func _web_after_optout(result: Dictionary) -> void:
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"])))
	sdk.track("after_optout", {})
	result["anonymous_id"] = sdk.get_anonymous_id()
	_check(sdk.get_anonymous_id() == "", "web_after_optout: a new anonymous ID after the opt-out")
	_check(sdk.get_queue_size() == 0, "web_after_optout: events queued after the opt-out")


func _web_legacy(result: Dictionary) -> void:
	# SDK 0.1.0 kept the state in user://manalens.cfg (IndexedDB on web).
	var legacy_id := "00000000-0000-4000-8000-000000000791"
	var cfg := ConfigFile.new()
	cfg.set_value("identity", "anonymous_id", legacy_id)
	cfg.set_value("identity", "first_open_at", "2026-11-01T00:00:00.000Z")
	cfg.save("user://manalens.cfg")
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"])))
	result["anonymous_id"] = sdk.get_anonymous_id()
	_check(sdk._web_storage, "web_legacy: localStorage is not used")
	_check(sdk.get_anonymous_id() == legacy_id, "web_legacy: the anonymous ID of the file is not kept")
	_check(not FileAccess.file_exists("user://manalens.cfg"), "web_legacy: the file is not removed after the move")


func _recovery(run_id: String, result: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://manalens.cfg")
	var now := Time.get_unix_time_from_system()
	var planted := "00000000-0000-4000-8000-%012d" % (randi() % 1000000000000)
	cfg.set_value("session", "id", planted)
	cfg.set_value("session", "started_at", now - 3.0 * 3600.0)
	cfg.set_value("session", "last_activity_at", now - 2.0 * 3600.0)
	cfg.save("user://manalens.cfg")
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"])))
	_check(sdk.get_session_id() != planted, "the stale session was not rotated")
	sdk.track("after_recovery", {"run_id": run_id})
	await sdk.shutdown()
	_check(sdk.get_queue_size() == 0, "events left after shutdown")
	result["planted_session"] = planted
	result["anonymous_id"] = sdk.get_anonymous_id()


func _errors(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	sdk.init(_options(String(_args["endpoint"])))
	sdk.set_before_send(func(event: Dictionary):
		if event.get("event") == "error" and String(event.properties.message).contains("secret"):
			return null
		event.properties["run_id"] = run_id
		return event)
	sdk.track("level_start", {"level": 3, "run_id": run_id})
	sdk.track_error("Save failed for slot 3", {"error_type": "SaveFailed", "severity": "critical", "handled": false, "properties": {"level": 3}})
	# Same type, numbers differ: same fingerprint within 1 s, so dropped.
	sdk.track_error("Save failed for slot 4", {"error_type": "SaveFailed"})
	sdk.track_error("secret token abc")  # before_send drops it
	var queued_manual: int = sdk.get_queue_size()
	_engine_error()
	_engine_error()  # same place: dropped by the dedupe
	await get_tree().process_frame
	await get_tree().process_frame
	result["engine_capture"] = sdk._error_logger != null
	result["queued_after_engine"] = sdk.get_queue_size() - queued_manual
	_check(sdk._error_logger != null, "no engine logger on Godot %s" % Engine.get_version_info().string)
	_check(result.queued_after_engine == 1, "expected 1 engine error, got %d" % result.queued_after_engine)
	await sdk.shutdown()
	_check(sdk.get_queue_size() == 0, "events left after shutdown")
	result["anonymous_id"] = sdk.get_anonymous_id()


func _engine_error() -> void:
	push_error("Engine boom in wave 7")


## enabled = false: every call is a no-op. No ID, no queue, no files.
func _disabled(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	var options := _options(String(_args["endpoint"]))
	options["enabled"] = false
	sdk.init(options)
	sdk.track("test_disabled", {"run_id": run_id})
	sdk.track_error("should not send", {"error_type": "Disabled"})
	sdk.identify("disabled-player")
	sdk.set_consent(true)
	sdk.flush()
	await get_tree().create_timer(1.5).timeout
	var url := "https://example.com/wiki"
	_check(sdk.get_anonymous_id() == "", "disabled: an anonymous ID was made")
	_check(sdk.get_queue_size() == 0, "disabled: events were queued")
	_check(sdk.link_url(url) == url, "disabled: link_url added an ID")
	_check(not FileAccess.file_exists("user://manalens.cfg"), "disabled: the config file was written")
	_check(not FileAccess.file_exists("user://manalens_queue.json"), "disabled: the queue file was written")


## send_failed(0, n) when the queue is over max_queue.
func _overflow(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	var dropped := [0]
	sdk.send_failed.connect(func(status: int, count: int): if status == 0: dropped[0] += count)
	var options := _options(OFFLINE_ENDPOINT)
	options["flush_at"] = 2
	options["max_queue"] = 2
	sdk.init(options)
	for i in 5:
		sdk.track("overflow_%d" % i, {"run_id": run_id})
	result["dropped"] = dropped[0]
	_check(dropped[0] > 0, "overflow: send_failed was not emitted for dropped events")
	_check(sdk.get_queue_size() <= 2, "overflow: queue is over max_queue")
	_fresh()


## set_consent(false) writes the opt-out marker and clears the ID.
func _optout(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = Manalens
	sdk.init(_options(OFFLINE_ENDPOINT))
	_check(sdk.get_anonymous_id() != "", "optout: no ID before opt-out")
	sdk.set_consent(false)
	sdk.track("after_optout", {"run_id": run_id})
	_check(FileAccess.file_exists("user://manalens_optout"), "optout: the marker was not written")
	_check(sdk.get_anonymous_id() == "", "optout: the ID was kept")
	_check(sdk.get_queue_size() == 0, "optout: events were queued")
	_fresh()


## A config file that exists but cannot be read: record nothing, keep the file.
func _corrupt(run_id: String, result: Dictionary) -> void:
	_fresh()
	var garbage := "[consent\ngranted = fal"
	var file := FileAccess.open("user://manalens.cfg", FileAccess.WRITE)
	file.store_string(garbage)
	file.close()
	var sdk = Manalens
	sdk.init(_options(OFFLINE_ENDPOINT))
	sdk.track("after_corrupt", {"run_id": run_id})
	_check(sdk.get_anonymous_id() == "", "corrupt: an ID was made")
	_check(sdk.get_queue_size() == 0, "corrupt: events were queued")
	_check(FileAccess.get_file_as_string("user://manalens.cfg") == garbage, "corrupt: the config file was overwritten")
	_check(FileAccess.file_exists("user://manalens.cfg.unreadable"), "corrupt: no copy was kept")
	sdk.set_consent(true)
	_check(sdk.get_anonymous_id() != "", "corrupt: set_consent(true) did not start tracking")
	_fresh()


## The opt-out marker wins when the config file is missing.
func _marker(run_id: String, result: Dictionary) -> void:
	_fresh()
	var file := FileAccess.open("user://manalens_optout", FileAccess.WRITE)
	file.store_string("opted out\n")
	file.close()
	var sdk = Manalens
	sdk.init(_options(OFFLINE_ENDPOINT))
	sdk.track("after_marker", {"run_id": run_id})
	_check(sdk.get_anonymous_id() == "", "marker: an ID was made")
	_check(sdk.get_queue_size() == 0, "marker: events were queued")
	_fresh()


## The fixture scenario. Launch 1 plays, identifies, hits an error, then
## crashes (no quit). Launch 2 sends app_crash and session_end of the
## crashed session, then quits cleanly.
func _fixtures(_run_id: String, result: Dictionary) -> void:
	_fresh()
	var fixture_sdk = load("res://fixture_sdk.gd")
	var endpoint := String(_args["endpoint"])
	var first = fixture_sdk.new()
	add_child(first)
	first.init(_fixture_options(endpoint, {"flush_at": 50, "app_version": "1.4.0", "build": "571", "storefront": "steam"}))
	first.track("level_start", {"level": 3, "mode": "story"})
	first.track("resource", {
		"flow": "source", "currency": "gold", "amount": 25, "ratio": 0.75, "float": 0.1,
		"big": 9000000000, "price": 4.99, "boss": false, "note": null, "text": "quote \" slash \\ line\nend",
	})
	first.traits({"difficulty": "hard", "level": 3})
	first.identify("player_42", {"plan": "supporter", "level": 12, "vip": true})
	first.track_error("Save failed for slot 3", {"severity": "critical", "error_type": "SaveFailed", "handled": false, "properties": {"slot": 3}})
	first.clock += 5.0
	push_error("Player.jump: the player node is null")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(first._error_logger != null, "fixtures: no engine logger on Godot %s" % Engine.get_version_info().string)
	first.clock += 10.0
	first._on_tick()  # Saves the session; then the process dies.
	first.hold = false
	first.flush()
	_check(await _wait_for(func(): return not first.is_sending() and first.get_queue_size() == 0, 10.0), "fixtures: launch 1 did not send its queue")
	# The crash: no quit, no exit flag, nothing more on disk.
	first._timer.stop()
	first.set_process(false)
	if first._error_logger != null:
		OS.remove_logger(first._error_logger)
		first._error_logger = null
	first._initialized = false
	var second = fixture_sdk.new()
	second.clock = first.clock + 120.0
	second.next_id = first.next_id
	add_child(second)
	second.init(_fixture_options(endpoint, {"app_version": "1.4.1-beta.2+572", "build": "572", "storefront": "itch"}))
	second.track("level_complete", {"level": 3, "score": 1200})
	second.clock += 42.0
	second.hold = false
	await second.shutdown()
	_check(second.get_queue_size() == 0, "fixtures: launch 2 did not send its queue")
	result["anonymous_id"] = second.get_anonymous_id()
	_fresh()


## Modes added after the fixtures. They are here, below _fixtures(), because
## the fixture stacks hold line numbers of this file.
func _more_modes(mode: String, result: Dictionary) -> void:
	match mode:
		"privacy": await _privacy(result)
		"before_send": _before_send_mode(result)
		"server": _server_mode(result)
		"auto_identify": await _auto_identify_mode(result)
		"platform": _platform_mode(result)
		"traits": await _traits_mode(result)
		"steam_link": await _steam_link_mode(result)
		_: _failures.append("unknown mode %s" % mode)


## server: a dedicated server build (G-2533). `--headless` makes the display
## server "headless", so this run is a server build. Without
## track_server_builds: no game_open, session_start, session_end or
## app_crash, and no install; track() and identify() still work. With
## the option (as in this project's Project Settings): the client events come
## back. Needs no network. pnpm test:godot runs it after the fixtures.
func _server_mode(result: Dictionary) -> void:
	const AUTOMATIC := ["game_open", "session_start", "session_end", "app_crash"]
	result["display_server"] = DisplayServer.get_name()
	_check(Manalens.is_server_build(), "server: a --headless run is not a server build (display server %s)" % DisplayServer.get_name())
	# Off (the default): the init() option wins over the Project Setting.
	_fresh()
	var sdk = load("res://fixture_sdk.gd").new()
	add_child(sdk)
	sdk.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50, "track_server_builds": false}))
	_check(sdk._server_quiet, "server: the SDK did not see the server build")
	sdk.track("match_end", {"winner": "red"})
	sdk.identify("server-player")
	# A crash: the next launch finds an open session and the queue on disk.
	sdk._save_session()
	sdk._save_queue()
	_stop(sdk)
	sdk.queue_free()
	var again = load("res://fixture_sdk.gd").new()
	add_child(again)
	again.clock += 60.0
	again.next_id = 100
	again.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50, "track_server_builds": false}))
	again.track("match_end", {"winner": "blue"})
	var quiet := _queued_names(again)
	result["quiet"] = quiet
	for name in AUTOMATIC:
		_check(not quiet.has(name), "server: %s was queued without track_server_builds: %s" % [name, quiet])
	_check(quiet.count("match_end") == 2 and quiet.has("identify"), "server: track() or identify() did not queue: %s" % [quiet])
	_check(again.get_anonymous_id() != "" and again._session_id != "", "server: no anonymous or session ID for track()")
	_stop(again)
	again.queue_free()
	# On: a server build sends the client events.
	_fresh()
	var loud = load("res://fixture_sdk.gd").new()
	add_child(loud)
	loud.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50, "track_server_builds": true}))
	_check(not loud._server_quiet, "server: track_server_builds did not turn the client events on")
	var names := _queued_names(loud)
	result["tracked"] = names
	_check(names.has("game_open") and names.has("session_start"), "server: no game_open or session_start with track_server_builds: %s" % [names])
	_stop(loud)
	loud.queue_free()
	_fresh()


func _queued_names(sdk) -> Array:
	var names := []
	for item in sdk._queue:
		names.append(String(item.event.get("event", item.event.get("type", ""))))
	return names


## privacy: set_consent(false) and reset() clear the breadcrumbs and the error
## limits; captured engine messages are cleaned (paths, URLs, emails, tokens)
## and track_error() text is not (P-2783). Needs no network. pnpm test:godot
## runs it after the fixtures.
func _privacy(result: Dictionary) -> void:
	_fresh()
	var sdk = load("res://fixture_sdk.gd").new()
	add_child(sdk)
	sdk.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50}))
	# Consent withdrawn, then given again.
	sdk.track("secret_level")
	sdk.track_error("Save failed")
	sdk.track_error("Save failed")  # the 1-second limit drops it: errors_dropped 1
	sdk.set_consent(false)
	sdk.set_consent(true)
	sdk.track_error("Save failed")
	var error = _last_named(sdk, "error")
	_check(error != null and String(error.properties.get("breadcrumbs", "")) == "session_start,game_open", "privacy: breadcrumbs after consent are %s" % [null if error == null else error.properties.get("breadcrumbs")])
	_check(sdk._errors_dropped == 0, "privacy: errors_dropped kept after the withdrawal")
	# Reset: the old session reports its dropped errors, then the history is cleared.
	sdk.track("secret_level")
	sdk.track_error("Save failed")  # dropped: errors_dropped 1
	sdk.reset()
	var ended = _last_named(sdk, "session_end")
	_check(ended != null and int(ended.properties.get("errors_dropped", 0)) == 1, "privacy: session_end before reset has no errors_dropped 1")
	sdk.track_error("Save failed")
	error = _last_named(sdk, "error")
	_check(error != null and String(error.properties.get("breadcrumbs", "")) == "session_start", "privacy: breadcrumbs after reset are %s" % [null if error == null else error.properties.get("breadcrumbs")])
	# The cleaning rules (the cases of the Unreal test Manalens.Errors.LogMessageCleaning).
	var home := ["/Users/anna/", "/Users/anna/Documents/"]
	var cases := [
		["Failed to open /Users/anna/Saved/x.sav", "Failed to open ~/Saved/x.sav"],
		["at \\Users\\anna\\Saved", "at ~\\Saved"],
		["read /Users/dave/Library/a.ini", "read ~/Library/a.ini"],
		["read /home/bob/game/log.txt", "read ~/game/log.txt"],
		["read C:\\Users\\Carol\\AppData\\x.ini", "read ~\\AppData\\x.ini"],
		["read d:/users/Carol/x.ini", "read ~/x.ini"],
		["GET https://user:pass@api.example.com/v1/items?id=3&sig=abc#frag failed", "GET https://api.example.com/v1/items failed"],
		["connect wss://u@play.example.com?ticket=1", "connect wss://play.example.com"],
		["GET https://api.example.com/v1/items", "GET https://api.example.com/v1/items"],
		["No account for jane.doe+x@mail.example.com.", "No account for [email]."],
		["Actor@Level failed", "Actor@Level failed"],
		["api_key=abc123 token=xyz&secret=s3 PASSWORD=hunter2", "api_key=[redacted] token=[redacted]&secret=[redacted] PASSWORD=[redacted]"],
		["Authorization: Bearer abc.def", "Authorization: [redacted]"],
		["sent bearer xyz.123 to the server", "sent bearer [redacted] to the server"],
		["session ABCDEFGHIJKLMNOPQRSTUV_- expired", "session [redacted] expired"],
		["session ABCDEFGHIJKLMNOPQRSTUVW expired", "session ABCDEFGHIJKLMNOPQRSTUVW expired"],
		["id 6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b", "id [redacted]"],
		["Invalid call. Nonexistent function 'jump' in base 'Nil'.", "Invalid call. Nonexistent function 'jump' in base 'Nil'."],
		["password=\"hunter2 two\" and key='a b'", "password=\"[redacted]\" and key='[redacted]'"],
		["{\"token\": \"abc def\", \"api_key\":\"k1\", \"user\": 3}", "{\"token\": \"[redacted]\", \"api_key\":\"[redacted]\", \"user\": 3}"],
		["{\"password\": \"p w\", \"secret\": 42}", "{\"password\": \"[redacted]\", \"secret\": [redacted]}"],
		["token: abc123 password : hunter2", "token: [redacted] password : [redacted]"],
		["\"Authorization\": \"Bearer abc\"", "\"Authorization\": \"[redacted]\""],
		["header token: Bearer abc", "header token: [redacted] [redacted]"],
		["jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln. failed", "jwt [redacted]. failed"],
		["blob aGVsbG8gd29ybGQgaGVsbG8+d29ybGQ end", "blob [redacted] end"],
		["blob aGVsbG8gd29ybGQgaGVsbG8vd29ybGQ= end", "blob [redacted] end"],
		["load res://levels/boss_room_final/arena.tscn failed", "load res://levels/boss_room_final/arena.tscn failed"],
	]
	for item in cases:
		var cleaned: String = sdk._clean_log_message(item[0], home)
		_check(cleaned == item[1], "privacy: clean(%s) = %s, expected %s" % [item[0], cleaned, item[1]])
	var real_home := OS.get_environment("HOME") if OS.get_environment("HOME") != "" else OS.get_environment("USERPROFILE")
	if real_home != "":
		var real: String = sdk._clean_log_message(real_home.path_join("Saved/a.sav"), sdk._home_dirs())
		_check(real == "~/Saved/a.sav" or real == "~\\Saved/a.sav", "privacy: the real home folder is kept: %s" % real)
	# A captured engine error reaches the queue cleaned; track_error() text does not change.
	push_error("Cannot load /Users/anna/Saved/a.sav for anna@example.com?token=abc")
	await get_tree().process_frame
	await get_tree().process_frame
	error = _last_named(sdk, "error")
	_check(error != null and error.properties.get("source") == "auto", "privacy: the engine error was not captured")
	if error != null:
		_check(String(error.properties.get("log_type", "")) == "error", "privacy: the engine error log_type is %s" % error.properties.get("log_type"))
		_check(String(error.properties.message) == "Cannot load ~/Saved/a.sav for [email]?token=[redacted]", "privacy: the engine message is %s" % error.properties.message)
	sdk.track_error("Mail support@example.com about /Users/anna/x")
	error = _last_named(sdk, "error")
	_check(error != null and String(error.properties.message) == "Mail support@example.com about /Users/anna/x", "privacy: track_error text was changed")
	result["queued"] = sdk.get_queue_size()
	sdk._timer.stop()
	sdk.set_process(false)
	if sdk._error_logger != null:
		OS.remove_logger(sdk._error_logger)
		sdk._error_logger = null
	sdk._initialized = false
	sdk.queue_free()
	_fresh()


## before_send: the hook gets every event (track, identify, the automatic
## events, error), can sample and scrub, and cannot break the envelope
## (G-2527). Needs no network. pnpm test:godot runs it after the fixtures.
func _before_send_mode(result: Dictionary) -> void:
	_fresh()
	var sdk = load("res://fixture_sdk.gd").new()
	add_child(sdk)
	var seen := []
	var state := {"jumps": 0, "mode": "scrub"}
	sdk.set_before_send(func(event: Dictionary):
		seen.append("%s:%s" % [event.type, event.get("event", "")])
		match state.mode:
			"break_id":
				event["message_id"] = "changed"
				event.properties["level"] = 99
				return event
			"break_app":
				event.context.app.erase("platform")
				return event
			"no_anonymous_id":
				event.erase("anonymous_id")
				return event
			"wrong_type":
				return "nope"
			"nested":
				sdk.track("from_the_hook")
				return event
		if event.get("event") == "player_jump":
			state.jumps += 1
			if state.jumps % 10 != 1:
				return null  # keep 1 in 10
		if event.has("properties"):
			event.properties.erase("email")
		if event.has("traits"):
			event.traits.erase("email")
		if event.get("event") == "error" and String(event.properties.get("message", "")).contains("secret"):
			return null
		return event)
	sdk.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50}))
	_check(seen.has("track:session_start") and seen.has("track:game_open"), "before_send: automatic events skipped the hook: %s" % [seen])
	for index in 20:
		sdk.track("player_jump", {"index": index})
	var jumps: int = sdk._queue.filter(func(entry): return entry.event.get("event") == "player_jump").size()
	_check(jumps == 2, "before_send: sampling kept %d of 20 player_jump, expected 2" % jumps)
	sdk.track("signup", {"email": "ana@example.com", "level": 1})
	var signup = _last_named(sdk, "signup")
	_check(signup != null and not signup.properties.has("email") and signup.properties.get("level") == 1, "before_send: signup was not scrubbed: %s" % [signup])
	sdk.identify("player_42", {"email": "ana@example.com", "plan": "supporter"})
	var identify = sdk._queue.back().event
	_check(identify.type == "identify" and not identify.traits.has("email") and identify.traits.get("plan") == "supporter", "before_send: identify traits were not scrubbed: %s" % [identify])
	# Errors: the limits run first, so a dropped error still counts in them.
	sdk.track_error("a secret value")
	sdk.track_error("a secret value")  # the 1-second limit: errors_dropped 1
	_check(_last_named(sdk, "error") == null, "before_send: the secret error was queued")
	_check(sdk._errors_dropped == 1, "before_send: errors_dropped is %d, expected 1" % sdk._errors_dropped)
	sdk.track_error("kept")
	_check(_last_named(sdk, "error") != null, "before_send: a normal error was dropped")
	var crumbs: String = String(_last_named(sdk, "error").properties.get("breadcrumbs", ""))
	_check(crumbs.count("player_jump") == 2, "before_send: dropped events are in the breadcrumbs: %s" % crumbs)
	# A hook that breaks the envelope: the original event is sent.
	for mode in ["break_id", "break_app", "no_anonymous_id"]:
		state.mode = mode
		var size: int = sdk.get_queue_size()
		sdk.track("level_start", {"level": 3})
		var last: Dictionary = sdk._queue.back().event
		_check(sdk.get_queue_size() == size + 1 and last.get("event") == "level_start" and last.properties.get("level") == 3 and last.message_id != "changed" and last.has("anonymous_id") and last.context.app.has("platform"), "before_send %s: the original event was not sent: %s" % [mode, last])
	state.mode = "wrong_type"
	var before: int = sdk.get_queue_size()
	sdk.track("level_start")
	_check(sdk.get_queue_size() == before, "before_send: a wrong return type did not drop the event")
	state.mode = "nested"
	before = sdk.get_queue_size()
	sdk.track("level_start")
	_check(sdk.get_queue_size() == before + 1 and _last_named(sdk, "from_the_hook") == null, "before_send: an event recorded inside the hook was queued")
	sdk.set_before_send(Callable())
	sdk.track("after_removal", {"email": "kept@example.com"})
	_check(_last_named(sdk, "after_removal") != null and _last_named(sdk, "after_removal").properties.has("email"), "before_send: Callable() did not remove the hook")
	result["queued"] = sdk.get_queue_size()
	sdk._timer.stop()
	sdk.set_process(false)
	if sdk._error_logger != null:
		OS.remove_logger(sdk._error_logger)
		sdk._error_logger = null
	sdk._initialized = false
	sdk.queue_free()
	_fresh()


## auto_identify: the opt-in Steam identify (P-2513) with a fake GodotSteam
## singleton. Needs no network. pnpm test:godot runs it after the fixtures.
func _auto_identify_mode(result: Dictionary) -> void:
	const STEAM_ID := 76561197960287930
	# SHA-256 of "mana_pk_fixture:76561197960287930" (the same in every SDK).
	const EXPECTED := "steam_5995b6bebc38aced1a509474218a3e5fccfe5b3fe26cd3ff82ed1a950b0cffe6"
	var key := String(_args["publishable-key"])
	_check(key == "mana_pk_fixture", "auto_identify: the expected hash needs the key mana_pk_fixture, not %s" % key)
	_check(Manalens.steam_user_id(key, str(STEAM_ID)) == EXPECTED, "auto_identify: wrong hash %s" % Manalens.steam_user_id(key, str(STEAM_ID)))
	var on := {"flush_at": 50, "auto_identify": "steam"}

	# 1. No GodotSteam addon: nothing happens and nothing fails.
	_fresh()
	var plain = await _auto_sdk(on)
	_check(_identifies(plain).is_empty() and plain._user_id == "", "auto_identify: identified without Steam: %s" % [_identifies(plain)])
	_check(plain._auto_identify_tries == 0, "auto_identify: still trying without the addon")
	_stop(plain)
	plain.queue_free()

	var steam = load("res://fake_steam.gd").new()
	steam.steam_id = STEAM_ID
	Engine.register_singleton("Steam", steam)

	# 2. Off by default: Steam is running, but no identify.
	_fresh()
	var off = await _auto_sdk({"flush_at": 50})
	_check(_identifies(off).is_empty(), "auto_identify: identified with the option off")
	_stop(off)
	off.queue_free()

	# 3. On: one identify with the hashed ID and storefront = steam.
	_fresh()
	var sdk = await _auto_sdk(on)
	var sent := _identifies(sdk)
	result["identified"] = sent
	_check(sent.size() == 1 and String(sent[0].get("user_id", "")) == EXPECTED, "auto_identify: expected one identify as %s: %s" % [EXPECTED, sent])
	_check(sent.size() == 1 and sent[0].get("traits", {}) == {"storefront": "steam"}, "auto_identify: wrong traits: %s" % [sent])
	_check(not JSON.stringify(sdk._queue).contains(str(STEAM_ID)), "auto_identify: the raw SteamID64 is in the queue")
	sdk._on_tick()
	_check(_identifies(sdk).size() == 1, "auto_identify: identified twice in one launch")
	_stop(sdk)
	sdk.queue_free()

	# 4. The next launch identifies again (once per launch) as the same user.
	DirAccess.remove_absolute("user://manalens_queue.json")  # keep the saved identity, not the old events
	var next = await _auto_sdk(on)
	_check(_identifies(next).size() == 1 and next._user_id == EXPECTED, "auto_identify: the next launch did not identify once: %s" % [_identifies(next)])
	_stop(next)
	next.queue_free()

	# 5. The game calls identify() right after init(): the game wins.
	_fresh()
	var game = load("res://fixture_sdk.gd").new()
	add_child(game)
	game.init(_fixture_options(OFFLINE_ENDPOINT, on))
	game.identify("player-42")
	await get_tree().process_frame
	await get_tree().process_frame
	game._on_tick()
	var ids := _identifies(game).map(func(event): return String(event.get("user_id", "")))
	_check(ids == ["player-42"] and game._user_id == "player-42", "auto_identify: the game identify did not win: %s" % [ids])
	_stop(game)
	game.queue_free()

	# 6. A user ID that the game set in an earlier launch stays.
	DirAccess.remove_absolute("user://manalens_queue.json")  # keep the saved identity, not the old events
	var later = await _auto_sdk(on)
	_check(_identifies(later).is_empty() and later._user_id == "player-42", "auto_identify: replaced the game's user ID: %s, %s" % [_identifies(later), later._user_id])
	_stop(later)
	later.queue_free()

	# 7. Consent: nothing before set_consent(true), then one identify.
	_fresh()
	var consent = load("res://fixture_sdk.gd").new()
	add_child(consent)
	var with_consent := on.duplicate()
	with_consent["consent_required"] = true
	consent.init(_fixture_options(OFFLINE_ENDPOINT, with_consent))
	await get_tree().process_frame
	consent._on_tick()
	_check(consent._queue.is_empty() and consent._user_id == "", "auto_identify: identified before consent")
	consent.set_consent(true)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_identifies(consent).size() == 1 and consent._user_id == EXPECTED, "auto_identify: no identify after consent: %s" % [_identifies(consent)])
	_stop(consent)
	consent.queue_free()

	# 8. Steam starts after the SDK (ID 0 at first): a later tick identifies.
	_fresh()
	steam.steam_id = 0
	var slow = await _auto_sdk(on)
	_check(_identifies(slow).is_empty(), "auto_identify: identified with SteamID 0")
	steam.steam_id = STEAM_ID
	slow._on_tick()
	_check(_identifies(slow).size() == 1, "auto_identify: no identify after Steam started")
	_stop(slow)
	slow.queue_free()

	# 9. Steam not running: nothing.
	_fresh()
	steam.running = false
	var closed = await _auto_sdk(on)
	closed._on_tick()
	_check(_identifies(closed).is_empty(), "auto_identify: identified while Steam is not running")
	_stop(closed)
	closed.queue_free()

	# 10. An unknown value is ignored.
	_fresh()
	steam.running = true
	var wrong = await _auto_sdk({"flush_at": 50, "auto_identify": "epic"})
	_check(_identifies(wrong).is_empty() and String(wrong._options.auto_identify) == "", "auto_identify: an unknown value was used")
	_stop(wrong)
	wrong.queue_free()

	Engine.unregister_singleton("Steam")
	steam.free()
	_fresh()


func _auto_sdk(values: Dictionary):
	var sdk = load("res://fixture_sdk.gd").new()
	add_child(sdk)
	sdk.init(_fixture_options(OFFLINE_ENDPOINT, values))
	await get_tree().process_frame
	await get_tree().process_frame
	return sdk


func _identifies(sdk) -> Array:
	var out := []
	for item in sdk._queue:
		if String(item.event.get("type", "")) == "identify":
			out.append(item.event)
	return out


## platform: the `platform` option names a console build; a wrong value falls
## back to the detected platform. Console storefronts are accepted (P-2776).
func _platform_mode(result: Dictionary) -> void:
	var seen := {}
	for platform in ["ps5", "xbox_series", "xbox_one", "switch", "switch2"]:
		_fresh()
		var sdk = load("res://fixture_sdk.gd").new()
		add_child(sdk)
		sdk.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50, "platform": platform}))
		seen[platform] = sdk._context().app.platform
		_stop(sdk)
		sdk.queue_free()
	result["platforms"] = seen
	for platform in seen:
		_check(seen[platform] == platform, "platform: %s was sent as %s" % [platform, seen[platform]])
	for storefront in ["psn", "xbox", "nintendo"]:
		_fresh()
		var store = load("res://fixture_sdk.gd").new()
		add_child(store)
		store.init(_fixture_options(OFFLINE_ENDPOINT, {"flush_at": 50, "storefront": storefront, "platform": "ps4"}))
		var app: Dictionary = store._context().app
		_check(app.get("storefront", "") == storefront, "platform: storefront %s was dropped" % storefront)
		_check(app.platform == "windows", "platform: the wrong value ps4 was not replaced by the detected platform: %s" % app.platform)
		_stop(store)
		store.queue_free()
	_fresh()


func _last_named(sdk, name: String):
	for index in range(sdk._queue.size() - 1, -1, -1):
		var event: Dictionary = sdk._queue[index].event
		if event.get("event", "") == name:
			return event
	return null


func _fixture_options(endpoint: String, values: Dictionary) -> Dictionary:
	var options := {
		"endpoint": endpoint, "publishable_key": String(_args["publishable-key"]),
		"flush_interval_s": 10.0, "handle_quit": false, "quit_timeout_s": 5.0, "debug": _args.has("debug"),
	}
	options.merge(values, true)
	return options


func _fresh() -> void:
	for path in ["user://manalens.cfg", "user://manalens_queue.json", "user://manalens_queue.json.tmp", "user://manalens_optout", "user://manalens.cfg.unreadable", "user://manalens.cfg.tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _queue_on_disk() -> int:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("user://manalens_queue.json"))
	return parsed.size() if typeof(parsed) == TYPE_ARRAY else -1


func _stored_anonymous_id() -> bool:
	var cfg := ConfigFile.new()
	return cfg.load("user://manalens.cfg") == OK and String(cfg.get_value("identity", "anonymous_id", "")) != ""


func _wait_for(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().create_timer(0.1).timeout
	return condition.call()


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)


func _finish(result: Dictionary) -> void:
	result["failures"] = _failures
	result["ok"] = _failures.is_empty() and not result.has("error")
	print("MANALENS_RESULT " + JSON.stringify(result))
	if OS.has_feature("web"):
		return  # A page stays open; the script reloads or closes it.
	get_tree().quit(0 if result.ok else 1)


func _traits_of(sdk) -> Array:
	var out := []
	for item in sdk._queue:
		if String(item.event.get("type", "")) == "traits":
			out.append(item.event)
	return out


## traits: a traits event with the anonymous ID and no user ID; the user ID
## after identify(); protected traits are not sent; it waits for consent
## (P-2814). Needs no network.
func _traits_mode(result: Dictionary) -> void:
	_fresh()
	var sdk = await _auto_sdk({"flush_at": 50})
	sdk.traits({"level": 3, "difficulty": "hard", "note": null})
	var sent := _traits_of(sdk)
	result["traits"] = sent
	_check(sent.size() == 1, "traits: expected one traits event: %s" % [sent])
	if sent.size() == 1:
		var event: Dictionary = sent[0]
		_check(event.traits == {"level": 3, "difficulty": "hard", "note": null}, "traits: wrong traits %s" % [event.traits])
		_check(not event.has("event") and not event.has("user_id"), "traits: an event name or a user ID: %s" % [event])
		_check(event.anonymous_id == sdk.get_anonymous_id() and event.session_id != "" and event.channel == "app", "traits: wrong identity: %s" % [event])
	sdk.traits({"email": "ana@example.com", "itch_user_id": "9", "plan": "pro"})
	sdk.traits({"stripe_customer_id": "cus_1"})
	sent = _traits_of(sdk)
	_check(sent.size() == 2 and sent[1].traits == {"plan": "pro"}, "traits: protected traits were sent: %s" % [sent])
	_check(sdk._warned_protected_traits, "traits: no warning for protected traits")
	_check(not JSON.stringify(sdk._queue).contains("ana@example.com"), "traits: the email is in the queue")
	sdk.traits({})
	_check(_traits_of(sdk).size() == 2, "traits: an empty call was queued")
	sdk.identify("player-7")
	sdk.traits({"level": 4})
	sent = _traits_of(sdk)
	_check(sent.size() == 3 and sent[2].get("user_id", "") == "player-7", "traits: no user ID after identify(): %s" % [sent])
	_stop(sdk)
	sdk.queue_free()

	# Consent: held and merged before consent, sent once after; forgotten after set_consent(false).
	_fresh()
	var consent = await _auto_sdk({"flush_at": 50, "consent_required": true})
	consent.traits({"level": 1, "mode": "easy"})
	consent.traits({"level": 2})
	_check(consent._queue.is_empty(), "traits: queued before consent")
	consent.set_consent(true)
	sent = _traits_of(consent)
	_check(sent.size() == 1 and sent[0].traits == {"level": 2, "mode": "easy"}, "traits: held traits not sent once after consent: %s" % [sent])
	consent.set_consent(false)
	consent.traits({"level": 3})
	consent.reset()
	consent.set_consent(true)
	_check(_traits_of(consent).is_empty(), "traits: traits from before reset() were sent: %s" % [_traits_of(consent)])
	_stop(consent)
	consent.queue_free()
	_fresh()


func _link_sdk(values: Dictionary):
	var sdk = load("res://link_sdk.gd").new()
	add_child(sdk)
	sdk.init(_fixture_options(OFFLINE_ENDPOINT, values))
	await get_tree().process_frame
	await get_tree().process_frame
	return sdk


func _limited(seconds: String) -> Array:
	return [HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(["Retry-After: " + seconds]), "{\"error\":{\"code\":\"RATE_LIMITED\"}}"]


## steam_link: link_steam() and the steam_link option with a stand-in
## GodotSteam and a mocked HTTP layer (P-2815): the ticket identity, the body
## and the URL; once per launch; consent; no retry of a refusal; one retry
## after a 429 with Retry-After, and none when consent or the identity changed
## during the wait. Needs no network.
func _steam_link_mode(result: Dictionary) -> void:
	var ticket_hex := "140000000a0b0c0d0e0f1011121314151617181900".left(40)
	var on := {"flush_at": 50, "steam_link": true}

	# 1. No GodotSteam addon: nothing happens and nothing fails.
	_fresh()
	var plain = await _link_sdk(on)
	plain.link_steam()
	_check(plain.link_requests.is_empty() and plain.linked.is_empty(), "steam_link: a request without Steam")
	_stop(plain)
	plain.queue_free()

	var steam = load("res://fake_steam.gd").new()
	steam.steam_id = 76561197960287930
	Engine.register_singleton("Steam", steam)

	# 2. Off by default: no request.
	_fresh()
	var off = await _link_sdk({"flush_at": 50})
	off._on_tick()
	_check(off.link_requests.is_empty() and steam.identities.is_empty(), "steam_link: a request with the option off")
	_stop(off)
	off.queue_free()

	# 3. On: one ticket for "manalens", one request with the hex ticket and the anonymous ID.
	_fresh()
	var sdk = await _link_sdk(on)
	await get_tree().process_frame
	result["requests"] = sdk.link_requests
	_check(steam.identities == ["manalens"], "steam_link: wrong ticket identity %s" % [steam.identities])
	_check(sdk.link_requests.size() == 1, "steam_link: expected one request: %s" % [sdk.link_requests])
	if sdk.link_requests.size() == 1:
		var request: Dictionary = sdk.link_requests[0]
		_check(request.url == OFFLINE_ENDPOINT + "/v0/link", "steam_link: wrong URL %s" % request.url)
		_check(request.body == {"provider": "steam", "ticket": ticket_hex, "anonymous_id": sdk.get_anonymous_id()}, "steam_link: wrong body %s" % [request.body])
		_check(request.headers.has("x-publishable-key: mana_pk_fixture"), "steam_link: no publishable key header")
	_check(sdk.linked == [[true, 200, ""]], "steam_link: wrong signal %s" % [sdk.linked])
	sdk._on_tick()
	await get_tree().process_frame
	_check(sdk.link_requests.size() == 1 and steam.identities.size() == 1, "steam_link: linked twice in one launch")
	_check(not JSON.stringify(sdk._queue).contains("76561197960287930"), "steam_link: the SteamID64 is in the queue")
	_stop(sdk)
	sdk.queue_free()

	# 4. The URL: events. becomes api.; api_endpoint wins.
	_fresh()
	var urls = await _link_sdk({"flush_at": 50})
	urls._options.endpoint = "https://events.manalens.dev/"
	_check(urls._link_url() == "https://api.manalens.dev/v0/link", "steam_link: wrong API URL %s" % urls._link_url())
	urls._options.api_endpoint = "https://example.com/mana/"
	_check(urls._link_url() == "https://example.com/mana/v0/link", "steam_link: api_endpoint ignored: %s" % urls._link_url())
	_stop(urls)
	urls.queue_free()

	# 5. Consent: nothing before set_consent(true), then one link.
	_fresh()
	steam.identities.clear()
	var with_consent := on.duplicate()
	with_consent["consent_required"] = true
	var consent = await _link_sdk(with_consent)
	consent._on_tick()
	consent.link_steam()
	_check(consent.link_requests.is_empty() and steam.identities.is_empty(), "steam_link: a request before consent")
	consent.set_consent(true)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(consent.link_requests.size() == 1, "steam_link: no request after consent: %s" % [consent.link_requests])
	_stop(consent)
	consent.queue_free()

	# 6. Steam gives no ticket: no request, the signal says STEAM_TICKET.
	_fresh()
	steam.ticket_result = 2
	var failed = await _link_sdk(on)
	await get_tree().process_frame
	_check(failed.link_requests.is_empty() and failed.linked == [[false, 0, "STEAM_TICKET"]], "steam_link: a failed ticket: %s, %s" % [failed.link_requests, failed.linked])
	steam.ticket_result = 1
	_stop(failed)
	failed.queue_free()

	# 7. The game's own ticket; a 4xx or 5xx is not sent again; a network error returns.
	_fresh()
	var manual = await _link_sdk({"flush_at": 50})
	var bytes := ticket_hex.hex_decode()
	for answer in [[400, "STEAM_TICKET_INVALID"], [401, "UNAUTHORIZED"], [403, "FORBIDDEN"], [409, "STEAM_NOT_CONNECTED"], [502, "STEAM_UNAVAILABLE"], [503, "NOT_CONFIGURED"]]:
		manual.link_requests.clear()
		manual.linked.clear()
		manual.link_responses.append([HTTPRequest.RESULT_SUCCESS, answer[0], PackedStringArray(), "{\"error\":{\"code\":\"%s\"}}" % answer[1]])
		manual.link_steam(bytes)
		_check(manual.link_requests.size() == 1 and manual.waits.is_empty(), "steam_link: HTTP %d was sent again" % answer[0])
		_check(manual.linked == [[false, answer[0], answer[1]]], "steam_link: wrong signal for %d: %s" % [answer[0], manual.linked])
	manual.link_requests.clear()
	manual.linked.clear()
	manual.link_responses.append([HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), ""])
	manual.link_steam(bytes)
	_check(manual.link_requests.size() == 1 and manual.linked == [[false, 0, "NETWORK_ERROR"]], "steam_link: network error: %s" % [manual.linked])
	manual.link_steam(PackedByteArray([1, 2, 3]))
	_check(manual.link_requests.size() == 1, "steam_link: a short ticket was sent")

	# 8. A 429 with Retry-After: one more try after the wait, then no loop; over 60 s: no wait.
	manual.link_requests.clear()
	manual.linked.clear()
	manual.link_responses.append_array([_limited("2"), _limited("2")])
	manual.link_steam(bytes)
	_check(manual.waits.size() == 1 and float(manual.waits[0][0]) == 2.0, "steam_link: no Retry-After wait: %s" % [manual.waits])
	manual.link_steam(bytes)  # in flight: ignored
	_check(manual.link_requests.size() == 1, "steam_link: a second call while one waits was sent")
	if manual.waits.size() == 1:
		manual.waits.pop_front()[1].call()
	_check(manual.link_requests.size() == 2 and manual.waits.is_empty(), "steam_link: not one retry: %d requests" % manual.link_requests.size())
	_check(manual.linked == [[false, 429, "RATE_LIMITED"]], "steam_link: wrong 429 signal %s" % [manual.linked])
	manual.link_requests.clear()
	manual.linked.clear()
	manual.link_responses.append(_limited("120"))
	manual.link_steam(bytes)
	_check(manual.link_requests.size() == 1 and manual.waits.is_empty(), "steam_link: waited for a Retry-After over 60 s")

	# 9. Consent withdrawn during the wait: no second request.
	manual.link_requests.clear()
	manual.linked.clear()
	manual.link_responses.append(_limited("2"))
	manual.link_steam(bytes)
	manual.set_consent(false)
	if manual.waits.size() == 1:
		manual.waits.pop_front()[1].call()
	_check(manual.link_requests.size() == 1 and manual.linked == [[false, 0, "CONSENT_REQUIRED"]], "steam_link: sent after set_consent(false): %s" % [manual.linked])
	manual.set_consent(true)

	# 10. reset() during the wait: no second request with the old ID.
	manual.link_requests.clear()
	manual.linked.clear()
	manual.link_responses.append(_limited("2"))
	manual.link_steam(bytes)
	manual.reset()
	if manual.waits.size() == 1:
		manual.waits.pop_front()[1].call()
	_check(manual.link_requests.size() == 1 and manual.linked == [[false, 0, "IDENTITY_CHANGED"]], "steam_link: sent after reset(): %s" % [manual.linked])
	_stop(manual)
	manual.queue_free()

	Engine.unregister_singleton("Steam")
	steam.free()
	_fresh()
