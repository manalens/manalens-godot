@tool
extends RefCounted
## The test event of the Manalens dock: one `manalens_test_event` sent from
## the editor, straight to the collector, with the Project Settings key. It
## has build "editor", so you can filter it out of your reports. It sends no
## game_open and no session events, so it adds no install and no session.

const EVENT := "manalens_test_event"
const Sdk := preload("res://addons/manalens/manalens.gd")


static func url(endpoint: String) -> String:
	return endpoint.strip_edges().trim_suffix("/") + "/v0/events"


static func headers(key: String) -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json", "x-publishable-key: %s" % key.strip_edges()])


## The request body. anonymous_id stays the same for this project on this
## computer (editor project metadata), so repeated tests count as one player.
static func body(options: Dictionary, anonymous_id: String, platform: String, unix: float) -> String:
	var app := {"platform": platform, "engine": "godot", "build": "editor"}
	if String(options.get("app_version", "")) != "":
		app["app_version"] = String(options.app_version)
	if String(options.get("storefront", "")) != "":
		app["storefront"] = String(options.storefront)
	var event := {
		"type": "track",
		"event": EVENT,
		"message_id": uuid(),
		"channel": "app",
		"version": Sdk.LIBRARY_VERSION,
		"original_timestamp": iso(unix),
		"anonymous_id": anonymous_id,
		"session_id": uuid(),
		"context": {"app": app, "library_name": Sdk.LIBRARY_NAME, "library_version": Sdk.LIBRARY_VERSION},
		"properties": {"source": "godot_editor"},
	}
	return JSON.stringify({"events": [event]})


## One line for the dock: what the collector did with the test event.
static func describe(result: int, status: int, text: String) -> String:
	if result != HTTPRequest.RESULT_SUCCESS:
		return "Not sent: no answer from the endpoint (HTTPRequest result %d). Check the endpoint and your network." % result
	var parsed = JSON.parse_string(text) if text != "" else null
	var reasons := ""
	if typeof(parsed) == TYPE_DICTIONARY:
		var parts: Array = []
		for error in parsed.get("errors", []):
			if typeof(error) == TYPE_DICTIONARY:
				parts.append("%s: %s" % [error.get("code", "?"), error.get("message", "")])
		if parts.is_empty() and typeof(parsed.get("error")) == TYPE_DICTIONARY:
			parts.append("%s: %s" % [parsed.error.get("code", "?"), parsed.error.get("message", "")])
		elif parts.is_empty() and parsed.has("message"):
			parts.append(String(parsed.message))
		reasons = "; ".join(parts)
		if status == 202 and int(parsed.get("accepted", 1)) > 0:
			return "Received (HTTP 202). Open Manalens: the install page shows the first event."
	if status == 401 or status == 403:
		return "Refused (HTTP %d): the collector does not accept this key here. %s" % [status, reasons]
	return "Refused (HTTP %d). %s" % [status, reasons if reasons != "" else text.left(300)]


static func platform(os_name: String) -> String:
	match os_name:
		"Windows": return "windows"
		"macOS": return "macos"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD": return "linux"
	return "other"


static func iso(unix: float) -> String:
	var whole := floori(unix)
	return "%s.%03dZ" % [Time.get_datetime_string_from_unix_time(whole), int((unix - whole) * 1000.0)]


static func uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
