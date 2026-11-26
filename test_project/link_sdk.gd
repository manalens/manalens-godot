extends "res://fixture_sdk.gd"
## The fixture SDK with a mocked HTTP layer for link_steam() (main.gd, mode
## `steam_link`): requests are recorded, answers come from `link_responses`,
## and a Retry-After wait runs only when the test calls it.

var link_requests: Array = []  # {url, headers, body}
var link_responses: Array = []  # [result, code, headers, body text]; default 200
var waits: Array = []  # [seconds, callback]
var linked: Array = []  # the steam_linked signals: [linked, status, code]


func _ready() -> void:
	steam_linked.connect(func(ok: bool, status: int, code: String): linked.append([ok, status, code]))


func _link_send(url: String, headers: PackedStringArray, body: String) -> void:
	link_requests.append({"url": url, "headers": headers, "body": JSON.parse_string(body)})
	var answer: Array = link_responses.pop_front() if not link_responses.is_empty() else [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), "{\"linked\":true,\"provider\":\"steam\"}"]
	_on_link_completed(answer[0], answer[1], answer[2], String(answer[3]).to_utf8_buffer())


func _link_after(seconds: float, callback: Callable) -> void:
	waits.append([seconds, callback])
