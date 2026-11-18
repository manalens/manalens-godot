extends Node
## Headless SDK test. Arguments after `--`:
##   --endpoint=URL       the collector (required)
##   --publishable-key=KEY  a project publishable key (required; --write-key=KEY,
##                          the old name, passes the key as the deprecated
##                          write_key option)
##   --mode=MODE          offline (default), consent, recovery, errors, link, session_age, disabled, overflow, optout, corrupt or marker
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
##           reason of a refusal is read from the response body. Needs no network.
##
## Prints one line `UA_RESULT {json}` and exits 0 on success, 1 on failure.

const OFFLINE_ENDPOINT := "http://127.0.0.1:9"
var _args := {}
var _failures: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := String(arg).trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else "true"
	if not _args.has("endpoint") or not (_args.has("publishable-key") or _args.has("write-key")):
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
		"disabled": await _disabled(run_id, result)
		"overflow": await _overflow(run_id, result)
		"optout": await _optout(run_id, result)
		"corrupt": await _corrupt(run_id, result)
		"marker": await _marker(run_id, result)
		_: _failures.append("unknown mode %s" % mode)
	_finish(result)


func _options(endpoint: String, consent_required := false) -> Dictionary:
	var options := {
		"endpoint": endpoint,
		"app_version": "0.1.0-test", "build": "godot-test", "storefront": "itch",
		"consent_required": consent_required, "flush_interval_s": 1.0,
		"quit_timeout_s": 5.0, "debug": _args.has("debug"),
	}
	# --write-key exercises the deprecated write_key option.
	if _args.has("publishable-key"):
		options["publishable_key"] = _args["publishable-key"]
	else:
		options["write_key"] = _args["write-key"]
	return options


func _offline(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = UntitledAnalytics
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
	var sdk = UntitledAnalytics
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
	var sdk = UntitledAnalytics
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
	var prefix := url + "?ua_hid=" + id + "."
	_check(plain.begins_with(prefix), "plain link: %s" % plain)
	var at := int(plain.trim_prefix(prefix))
	_check(at >= before and at <= after, "handoff time %d is not now" % at)
	_check(query.begins_with("https://example.com/wiki?page=2&ua_hid=" + id + ".") and query.ends_with("#boss"), "query link: %s" % query)
	sdk.reset()
	_check(not sdk.link_url(url).contains(id), "link_url kept the old ID after reset()")
	await sdk.shutdown()


func _session_age(_run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = UntitledAnalytics
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


func _recovery(run_id: String, result: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://untitled_analytics.cfg")
	var now := Time.get_unix_time_from_system()
	var planted := "00000000-0000-4000-8000-%012d" % (randi() % 1000000000000)
	cfg.set_value("session", "id", planted)
	cfg.set_value("session", "started_at", now - 3.0 * 3600.0)
	cfg.set_value("session", "last_activity_at", now - 2.0 * 3600.0)
	cfg.save("user://untitled_analytics.cfg")
	var sdk = UntitledAnalytics
	sdk.init(_options(String(_args["endpoint"])))
	_check(sdk.get_session_id() != planted, "the stale session was not rotated")
	sdk.track("after_recovery", {"run_id": run_id})
	await sdk.shutdown()
	_check(sdk.get_queue_size() == 0, "events left after shutdown")
	result["planted_session"] = planted
	result["anonymous_id"] = sdk.get_anonymous_id()


func _errors(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = UntitledAnalytics
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
	var sdk = UntitledAnalytics
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
	_check(not FileAccess.file_exists("user://untitled_analytics.cfg"), "disabled: the config file was written")
	_check(not FileAccess.file_exists("user://untitled_analytics_queue.json"), "disabled: the queue file was written")


## send_failed(0, n) when the queue is over max_queue.
func _overflow(run_id: String, result: Dictionary) -> void:
	_fresh()
	var sdk = UntitledAnalytics
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
	var sdk = UntitledAnalytics
	sdk.init(_options(OFFLINE_ENDPOINT))
	_check(sdk.get_anonymous_id() != "", "optout: no ID before opt-out")
	sdk.set_consent(false)
	sdk.track("after_optout", {"run_id": run_id})
	_check(FileAccess.file_exists("user://untitled_analytics_optout"), "optout: the marker was not written")
	_check(sdk.get_anonymous_id() == "", "optout: the ID was kept")
	_check(sdk.get_queue_size() == 0, "optout: events were queued")
	_fresh()


## A config file that exists but cannot be read: record nothing, keep the file.
func _corrupt(run_id: String, result: Dictionary) -> void:
	_fresh()
	var garbage := "[consent\ngranted = fal"
	var file := FileAccess.open("user://untitled_analytics.cfg", FileAccess.WRITE)
	file.store_string(garbage)
	file.close()
	var sdk = UntitledAnalytics
	sdk.init(_options(OFFLINE_ENDPOINT))
	sdk.track("after_corrupt", {"run_id": run_id})
	_check(sdk.get_anonymous_id() == "", "corrupt: an ID was made")
	_check(sdk.get_queue_size() == 0, "corrupt: events were queued")
	_check(FileAccess.get_file_as_string("user://untitled_analytics.cfg") == garbage, "corrupt: the config file was overwritten")
	_check(FileAccess.file_exists("user://untitled_analytics.cfg.unreadable"), "corrupt: no copy was kept")
	sdk.set_consent(true)
	_check(sdk.get_anonymous_id() != "", "corrupt: set_consent(true) did not start tracking")
	_fresh()


## The opt-out marker wins when the config file is missing.
func _marker(run_id: String, result: Dictionary) -> void:
	_fresh()
	var file := FileAccess.open("user://untitled_analytics_optout", FileAccess.WRITE)
	file.store_string("opted out\n")
	file.close()
	var sdk = UntitledAnalytics
	sdk.init(_options(OFFLINE_ENDPOINT))
	sdk.track("after_marker", {"run_id": run_id})
	_check(sdk.get_anonymous_id() == "", "marker: an ID was made")
	_check(sdk.get_queue_size() == 0, "marker: events were queued")
	_fresh()


func _fresh() -> void:
	for path in ["user://untitled_analytics.cfg", "user://untitled_analytics_queue.json", "user://untitled_analytics_optout", "user://untitled_analytics.cfg.unreadable", "user://untitled_analytics.cfg.tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _queue_on_disk() -> int:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("user://untitled_analytics_queue.json"))
	return parsed.size() if typeof(parsed) == TYPE_ARRAY else -1


func _stored_anonymous_id() -> bool:
	var cfg := ConfigFile.new()
	return cfg.load("user://untitled_analytics.cfg") == OK and String(cfg.get_value("identity", "anonymous_id", "")) != ""


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
	print("UA_RESULT " + JSON.stringify(result))
	get_tree().quit(0 if result.ok else 1)
