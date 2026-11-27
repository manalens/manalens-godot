extends "res://fixture_sdk.gd"
## The fixture SDK with a fake transport for the event batches (main.gd, mode
## `batch_413`): each request is recorded, and its answer comes from
## `responses` on the next idle frame, as a real HTTPRequest answers later.

var requests: Array = []  # the message IDs of each request
var responses: Array = []  # HTTP status codes; default 202
var failed: Array = []  # the send_failed signals: [status, dropped]


func _ready() -> void:
	send_failed.connect(func(status: int, dropped: int): failed.append([status, dropped]))


func _send_events(_url: String, _headers: PackedStringArray, body: String) -> Error:
	var ids: Array = []
	for event in JSON.parse_string(body).events:
		ids.append(String(event.message_id))
	requests.append(ids)
	var code: int = responses.pop_front() if not responses.is_empty() else 202
	var text := "{\"accepted\":%d}" % ids.size() if code < 300 else "{\"error\":{\"code\":\"%s\"}}" % ("PAYLOAD_TOO_LARGE" if code == 413 else "INVALID_EVENT")
	_on_request_completed.call_deferred(HTTPRequest.RESULT_SUCCESS, code, PackedStringArray(), text.to_utf8_buffer())
	return OK
