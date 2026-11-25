extends "res://addons/manalens/manalens.gd"
## The SDK for the fixture scenario (main.gd, mode `fixtures`): a fixed clock,
## sequential IDs and a fixed device (windows, en-US, no UTC offset), as the
## Device of the Unity tests. `hold` keeps every send until the scenario
## releases it, so the request bodies are the same on every run.

var clock := 1800000000.0  # 2027-01-15T08:00:00Z, the Unity FakeClock
var next_id := 0
var hold := true


func flush() -> void:
	if hold:
		return
	super()


func _now() -> float:
	return clock


func _uuid() -> String:
	next_id += 1
	return "00000000-0000-4000-8000-%012d" % next_id


func _platform() -> String:
	return "windows"


func _context() -> Dictionary:
	var context := super()
	context["locale"] = "en-US"
	context.erase("utc_offset")
	return context
