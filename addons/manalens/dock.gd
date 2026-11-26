@tool
extends VBoxContainer
## The Manalens dock: the key check of Project Settings, "Send test event"
## and the result of the last test, and a link to the Manalens app.

const Settings := preload("res://addons/manalens/settings.gd")
const TestEvent := preload("res://addons/manalens/test_event.gd")
const APP_URL := "https://app.manalens.dev/"
const DOCS_URL := "https://docs.manalens.dev/sdks/godot"

var editor_settings: EditorSettings
var _key_status: Label
var _start_status: Label
var _send: Button
var _result: Label
var _http: HTTPRequest


func _ready() -> void:
	name = "Manalens"
	add_theme_constant_override("separation", 8)
	var intro := Label.new()
	intro.text = "Set the key in Project > Project Settings > Manalens > General."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(intro)
	_key_status = _label()
	_start_status = _label()
	_send = Button.new()
	_send.text = "Send test event"
	_send.tooltip_text = "Sends one manalens_test_event (build \"editor\") straight to the collector. No install and no session."
	_send.pressed.connect(_on_send)
	add_child(_send)
	_result = _label()
	var links := HBoxContainer.new()
	links.add_theme_constant_override("separation", 16)
	links.add_child(_link("Open Manalens", APP_URL))
	links.add_child(_link("Docs", DOCS_URL))
	add_child(links)
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	_http.request_completed.connect(_on_done)
	add_child(_http)
	if ProjectSettings.has_signal("settings_changed"):
		ProjectSettings.connect("settings_changed", _refresh)
	_refresh()


func _label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(label)
	return label


func _link(text: String, url: String) -> LinkButton:
	var link := LinkButton.new()
	link.text = text
	link.pressed.connect(func(): OS.shell_open(url))
	return link


func _refresh() -> void:
	var problem := Settings.key_problem(String(Settings.get_value("publishable_key")))
	_key_status.text = "Key: OK (publishable key)" if problem == "" else "Key: " + problem
	_key_status.modulate = Color(0.55, 0.85, 0.55) if problem == "" else Color(1.0, 0.7, 0.4)
	if problem != "":
		_start_status.text = "Start: the SDK does not start until you set the key or call Manalens.init()."
	elif bool(Settings.get_value("auto_init")):
		_start_status.text = "Start: automatic, at the end of the first frame (unless your code calls Manalens.init() first)."
	else:
		_start_status.text = "Start: auto_init is off. Call Manalens.init() in your code."
	_send.disabled = problem != "" or String(Settings.get_value("endpoint")).strip_edges() == "" or _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED


func _on_send() -> void:
	var options := Settings.options()
	var error := _http.request(TestEvent.url(String(options.endpoint)), TestEvent.headers(String(options.publishable_key)), HTTPClient.METHOD_POST,
		TestEvent.body(options, _anonymous_id(), TestEvent.platform(OS.get_name()), Time.get_unix_time_from_system()))
	if error != OK:
		_result.text = "Not sent: the request did not start (error %d)." % error
		return
	_send.disabled = true
	_result.text = "Sending..."


func _on_done(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_result.text = TestEvent.describe(result, status, body.get_string_from_utf8())
	_refresh()


## The same test player for this project on this computer, so repeated tests
## count as one player.
func _anonymous_id() -> String:
	if editor_settings == null:
		return TestEvent.uuid()
	var id := String(editor_settings.get_project_metadata("manalens", "test_anonymous_id", ""))
	if id == "":
		id = TestEvent.uuid()
		editor_settings.set_project_metadata("manalens", "test_anonymous_id", id)
	return id
