extends Node
## Headless SDK test. Arguments after `--`:
##   --endpoint=URL       the collector (required)
##   --publishable-key=KEY  a project publishable key (required; --write-key=KEY,
##                          the old name, passes the key as the deprecated
##                          write_key option)
##   --mode=MODE          offline (default), consent, recovery, errors or link
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


func _fresh() -> void:
	for path in ["user://untitled_analytics.cfg", "user://untitled_analytics_queue.json"]:
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
