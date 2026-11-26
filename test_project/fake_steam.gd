extends Object
## A stand-in for the GodotSteam `Steam` singleton (main.gd, modes
## `auto_identify` and `steam_link`). Only the methods and the signal the SDK uses.

signal get_ticket_for_web_api(auth_ticket: int, result: int, ticket_size: int, ticket_buffer: PackedByteArray)

var running := true
var steam_id := 0
## getAuthTicketForWebApi(): the identities asked for, and the answer sent on the next frame.
var identities: Array = []
var ticket_result := 1
var ticket := PackedByteArray([20, 0, 0, 0, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25])
var next_handle := 100


func isSteamRunning() -> bool:
	return running


func getSteamID() -> int:
	return steam_id


func getAuthTicketForWebApi(identity: String) -> int:
	identities.append(identity)
	next_handle += 1
	# Another ticket of the game first: the SDK must wait for its own handle.
	get_ticket_for_web_api.emit.call_deferred(next_handle + 1000, 1, 4, PackedByteArray([1, 2, 3, 4]))
	get_ticket_for_web_api.emit.call_deferred(next_handle, ticket_result, ticket.size(), ticket)
	return next_handle
