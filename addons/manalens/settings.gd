@tool
extends RefCounted
## The Manalens section of Project Settings (Project > Project Settings >
## Manalens > General, with Advanced Settings on for the less common items).
## The autoload starts the SDK from these values at the end of the first frame
## when a publishable key is set and auto_init is on. Options given to
## Manalens.init() override them.

const PREFIX := "manalens/general/"
const STOREFRONTS := ",steam,itch,epic,gog,app_store,play,psn,xbox,nintendo,other"
const PLATFORMS := ",windows,macos,linux,web,android,ios,ps5,xbox_series,xbox_one,switch,switch2,other"
## key, type, default, hint, hint string, shown without Advanced Settings.
const ITEMS := [
	["publishable_key", TYPE_STRING, "", PROPERTY_HINT_NONE, "", true],
	["endpoint", TYPE_STRING, "https://events.manalens.dev", PROPERTY_HINT_NONE, "", true],
	["auto_init", TYPE_BOOL, true, PROPERTY_HINT_NONE, "", true],
	["consent_required", TYPE_BOOL, false, PROPERTY_HINT_NONE, "", true],
	["app_version", TYPE_STRING, "", PROPERTY_HINT_NONE, "", false],
	["build", TYPE_STRING, "", PROPERTY_HINT_NONE, "", false],
	["storefront", TYPE_STRING, "", PROPERTY_HINT_ENUM_SUGGESTION, STOREFRONTS, false],
	["platform", TYPE_STRING, "", PROPERTY_HINT_ENUM_SUGGESTION, PLATFORMS, false],
	["auto_identify", TYPE_STRING, "", PROPERTY_HINT_ENUM_SUGGESTION, ",steam", false],
	["steam_link", TYPE_BOOL, false, PROPERTY_HINT_NONE, "", false],
	["track_server_builds", TYPE_BOOL, false, PROPERTY_HINT_NONE, "", false],
]


## Adds the settings that are missing. Returns true when one was added.
static func register() -> bool:
	var added := false
	for item in ITEMS:
		var path: String = PREFIX + item[0]
		if not ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, item[2])
			added = true
		ProjectSettings.set_initial_value(path, item[2])
		ProjectSettings.add_property_info({"name": path, "type": item[1], "hint": item[3], "hint_string": item[4]})
		ProjectSettings.set_as_basic(path, item[5])
	return added


static func get_value(key: String):
	for item in ITEMS:
		if item[0] == key:
			return ProjectSettings.get_setting(PREFIX + key, item[2])
	return null


## The init() options that the settings give: empty strings are left out, so
## the SDK defaults apply.
static func options() -> Dictionary:
	var out := {}
	for item in ITEMS:
		var key: String = item[0]
		if key == "auto_init":
			continue
		var value = get_value(key)
		if typeof(value) == TYPE_STRING and String(value).strip_edges() == "":
			continue
		out[key] = String(value).strip_edges() if typeof(value) == TYPE_STRING else value
	return out


## Why the value cannot be the publishable key, or "" when it can be.
static func key_problem(key: String) -> String:
	key = key.strip_edges()
	if key == "":
		return "No publishable key yet. Copy it from your project in Manalens (it starts with mana_pk_)."
	if key.begins_with("mana_sk_"):
		return "This is a secret key (mana_sk_). Never put a secret key in a game build. Use the publishable key (mana_pk_...)."
	if key.begins_with("mana_api_"):
		return "This is an API key. Never put an API key in a game build. Use the publishable key (mana_pk_...)."
	if not key.begins_with("mana_pk_"):
		return "This is not a publishable key: it must start with mana_pk_."
	if key.length() != "mana_pk_".length() + 43 + 8:
		return "The key has the wrong length. Check that you copied all of it."
	return ""
