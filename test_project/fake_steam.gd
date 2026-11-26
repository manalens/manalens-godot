extends Object
## A stand-in for the GodotSteam `Steam` singleton (main.gd, mode
## `auto_identify`). Only the two methods the SDK calls.

var running := true
var steam_id := 0


func isSteamRunning() -> bool:
	return running


func getSteamID() -> int:
	return steam_id
