extends Node
## Headless SDK test. Arguments after `--`:
##   --endpoint=URL       the collector (required)
##   --publishable-key=KEY  a project publishable key (required)
##   --mode=MODE          offline (default), consent, recovery, errors, link, session_age, web_reload, install_kill, shutdown_tick, disabled, overflow, optout, corrupt, marker or fixtures
##   In a web export, the same arguments come from the page URL (?mode=web_id&endpoint=...&publishable-key=...).
##   --run-id=ID          tag for the events (default: random)
##
## offline:  fresh state; queue events against a dead endpoint, check they are
##           on disk, switch to the real endpoint, flush, shut down.
## consent:  fresh state with consent_required; events before consent are not
##           queued and no ID is stored; then set_consent(true).
## recovery: keeps the ID; plants a session that was left open 2 hours ago (a
##           crash) and checks that init ends it with session_end and sends
##           app_unclean_exit.
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
##           a second launch. On web: no app_unclean_exit; on windows (the
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
## web_id, web_optout, web_after_optout, web_legacy: web export only
##           (scripts/test-godot-web.mjs, P-2791). web_id starts the SDK and
##           prints the anonymous ID at once; the script reloads the page then.
##           web_optout opts out; web_after_optout (the next load) checks that
##           the opt-out is kept. web_legacy: a state file of SDK 0.1.0 moves to
##           localStorage and keeps its anonymous ID.
##
## fixtures: the shared fixture scenario of sdks/SPEC.md (the steps of the Unity
##           FixtureTests) with a fixed clock and sequential IDs. The endpoint
##           is the capture server of scripts/test-godot-sdk-fixtures.mjs
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
		_: _failures.append("unknown mode %s" % mode)
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
		var unclean := 0
		var ended := 0
		for entry in second._queue:
			var event: Dictionary = entry.event
			if String(event.get("event", "")) == "app_unclean_exit":
				unclean += 1
			if String(event.get("event", "")) == "session_end" and String(event.session_id) == session:
				ended += 1
		result["%s_unclean_exit" % platform] = unclean
		_check(ended == 1, "%s: the old session did not end" % platform)
		if platform == "web":
			_check(unclean == 0, "web: a reload sent app_unclean_exit")
		else:
			_check(unclean == 1, "%s: no app_unclean_exit after a launch without a quit" % platform)
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
	sdk.set_before_send(func(props: Dictionary):
		if String(props.message).contains("secret"):
			return null
		props["run_id"] = run_id
		return props)
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
## crashes (no quit). Launch 2 sends app_unclean_exit and session_end of the
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
