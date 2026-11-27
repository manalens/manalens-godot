# Manalens for Godot 4

Game analytics for Godot 4 in plain GDScript (no native code). It works on every export target that has `HTTPRequest`: Windows, macOS, Linux, Android, iOS and Web.

It sends events to the Manalens collector (`POST /v0/events`) with your project's **Publishable key** (the `publishable_key` option, sent in the `x-publishable-key` header). The Publishable key is safe to ship in a game build. Never put a Secret key or an API key in a build. Events go in the same envelope as the web SDK, with `context.app` in place of `context.page`. See the [Godot docs](https://docs.manalens.dev/sdks/godot) and the [app events reference](https://docs.manalens.dev/sdks/app-events).

## Install

1. Copy `addons/manalens` into your project's `addons/` folder.
2. Open **Project > Project Settings > Plugins** and enable **Manalens**. This adds the `Manalens` autoload.

## Use

```gdscript
func _ready() -> void:
    Manalens.init({
        "publishable_key": "YOUR_PUBLISHABLE_KEY",
        "endpoint": "https://your-collector.example.com",
        "app_version": "1.4.0",
        "build": "571",
        "storefront": "steam",  # steam, itch, epic, gog, app_store, play, psn, xbox, nintendo, other
    })

func _on_level_completed(level: int, score: int) -> void:
    Manalens.track("level_complete", {"level": level, "score": score})

func _on_signed_in(player_id: String) -> void:
    Manalens.identify(player_id, {"plan": "supporter"})
```

| Function | What it does |
| --- | --- |
| `init(options)` | Starts the SDK. Sends `session_start` and `game_open` (`is_first_open`, `first_open_at`). |
| `track(event, properties)` | Records an event. Property values are String, int, float, bool or null; other values are dropped. |
| `identify(user_id, traits)` | Attaches a player ID (kept on disk) and traits. |
| `traits(traits)` | Sets traits on this player, with or without a player ID. See [Traits](#traits). |
| `link_steam(ticket)` | Verifies the Steam account of this player. See [Verify Steam ownership](#verify-steam-ownership). |
| `link_url(url)` | Adds the handoff parameter (`mana_hid`) to a website URL, so the website joins this player without `identify()`. Use it with `OS.shell_open()`. Unchanged before consent. |
| `reset()` | Ends the session, forgets the player ID, makes a new anonymous ID and starts a new session. |
| `set_consent(granted)` | Consent mode. `true` starts tracking; `false` deletes the ID, the session and the queue. |
| `track_error(message, options)` | Sends an `error` event. Options: `severity`, `error_type`, `handled`, `stack`, `file`, `line`, `function`, `fingerprint`, `properties`. |
| `set_before_send(callable)` | Gets a copy of each event (track, identify, error, automatic events) before it is queued; return it (changed or not), or null to drop it. See [before_send](#before_send). |
| `flush()` | Sends queued events now. |
| `await shutdown()` | Sends `session_end` and flushes, for at most `quit_timeout_s`. |

Options: `enabled` (true; editor runs send events like a live game, and dev and live data go to the same project: to tell test builds apart, set `build` (for example `"dev"`) and filter by it), `publishable_key` and `endpoint` (required), `app_version`, `build`, `storefront`, `platform` (empty: detected; set `ps5`, `xbox_series`, `xbox_one`, `switch`, or `switch2` in a console port), `auto_identify` (empty; `"steam"` identifies the player by a salted hash of the Steam ID, see below), `steam_link` (false; `true` verifies the Steam account once per launch, see below), `api_endpoint` (empty: the `endpoint` with `events.` changed to `api.`; the URL of `link_steam()`), `consent_required` (false), `flush_interval_s` (10), `flush_at` (20, also the batch size), `max_queue` (1000), `handle_quit` (true), `quit_timeout_s` (2), `capture_engine_errors` (true, Godot 4.5+), `capture_warnings` (false), `max_auto_errors_per_session` (50), `track_server_builds` (false: a dedicated server or `--headless` build sends no `game_open`, sessions or `app_crash`), `debug` (false).

## before_send

The callback gets the whole event (`type`, `event`, `properties`, `traits`, `user_id`, `message_id`, `anonymous_id`, `session_id`, `context`). The SDK takes `event`, `properties`, `traits`, and `user_id` from the result. If the result changes or removes `type`, `message_id`, `anonymous_id`, `session_id`, or `context.app`, the SDK sends the original event. Errors pass the error limits first.

```gdscript
# Keep 10% of player_jump events (sampling).
Manalens.set_before_send(func(event: Dictionary):
    if event.get("event") == "player_jump" and randf() >= 0.1:
        return null  # drop
    return event)

# Remove personal data from every event (PII scrub).
Manalens.set_before_send(func(event: Dictionary):
    event.properties.erase("email")
    if event.has("traits"):
        event.traits.erase("email")
    if event.get("event") == "error" and String(event.properties.get("message", "")).contains("@"):
        return null  # drop the error
    return event)
```

## How it works

- **Identity:** a random UUID in `user://manalens.cfg` (in a web export: the browser's `localStorage`), kept across launches. `identify()` stores the player ID in the same file.
- **Sessions:** a session continues while the game has focus. After 30 minutes without focus or events, the next activity ends the old session (`session_end` with `duration_s`) and starts a new one. A session left open by a crash is ended at its last activity on the next launch.
- **Queue:** events are batched and sent every 10 seconds, at 20 queued events, on focus loss or pause, and on quit. The queue is saved in `user://manalens_queue.json`, so events survive a crash or an offline session. At most 1000 events are kept, and events older than 7 days are dropped (the collector refuses them). Each event has a `message_id`, so a retry never counts twice.
- **Retry:** a network error or a 5xx, 408 or 429 response keeps the batch and waits about 2, 4, 8 ... seconds with jitter (at most 5 minutes). A 413 (batch too large) keeps the events and sends again at once with half the batch, with no wait; a 413 for a batch of 1 event drops that event (`send_failed(413, 1)`). After a success, the batch size is `flush_at` again. Other 4xx responses drop the batch, because a retry fails again.
- **No network:** the SDK does not check the network before a send. A send without a network fails as a network error and waits as above, so after a long time offline the first send can come up to 5 minutes after the network is back. The Unity and Unreal SDKs skip the send while the engine reports no network (P-2853), but Godot 4 (checked on 4.7.2) has no OS reachability API. `IP.get_local_interfaces()` only lists addresses: virtual adapters (VPN, Hyper-V, Docker) keep an address with no network, and in a web export the browser hides the network interfaces, so the list says nothing about the network. A guess that is wrong in either direction is worse than the backoff, so the SDK keeps the backoff until Godot has such an API.
- **Quit:** with `handle_quit` (default), the SDK handles the window close request: it sends `session_end`, flushes for at most `quit_timeout_s`, then quits. If your game handles the close request itself (for example with a confirmation dialog), set `handle_quit` to false and call `await Manalens.shutdown()` before `get_tree().quit()`.
- **Consent:** with `consent_required: true`, no event is recorded and no ID is written until `set_consent(true)`. The choice is saved, so it applies on the next launch too. `identify()` before consent is sent after consent.
- **Errors:** on Godot 4.5+, `error_logger.gd` (an `OS.add_logger()` logger) collects engine and script errors under a Mutex, and the SDK sends them on the main thread, with `source` `auto` and `log_type` (`error`, `script`, or `warning`). A `track_error()` call has `source` `manual`. Limits: the same fingerprint once a second, 20 errors in 10 seconds, 5 engine errors in one frame and 50 `auto` errors in one session. Dropped errors are counted in `session_end` (`errors_dropped`).
- **Crashes:** when the last run did not exit normally while the game had focus, the next launch sends `app_crash` in the old session, with `previous_session_id`, `previous_build` and `previous_app_version`. Not on web: a closed or reloaded tab has no quit event.
- **Context:** `context.app.platform` comes from the `platform` option or else `OS.get_name()` (`other` for an unknown name, such as a console port), `engine` is `godot`, and `app_version`, `build` and `storefront` come from `init()`.

## Web export

A web export runs in a browser, so its requests carry an `Origin` header. The collector accepts it when the page is on:

- your project domain or a subdomain (for example `play.example.com` for `example.com`);
- a host in **Project settings > Allowed origins**.

itch.io serves HTML5 builds from `html.itch.zone` and `html-classic.itch.zone`. A new project lists `*.itch.zone`, so an itch.io build works with no change. If you removed it, add `*.itch.zone` again (or click **Restore default**). For another portal, add its host (for example `*.crazygames.com`). A page on any other host gets 403. See [Allowed origins](https://docs.manalens.dev/sdks/app-events#allowed-origins).

## Test

`test_project` in the [manalens-godot](https://github.com/manalens/manalens-godot) repo is a headless test project (the addon folder is a symlink). [CONTRIBUTING.md](https://github.com/manalens/manalens-godot/blob/main/CONTRIBUTING.md) says how to run the tests and make a release.

## Traits

`traits()` sets traits on this player. It needs no player ID: before `identify()`, the traits belong to this install's anonymous ID; after it, to the player. A `null` value clears a trait.

```gdscript
Manalens.traits({"level": 3, "difficulty": "hard", "discord_id": "123456789012345678"})
```

- Values are String, int, float, bool or null. At most 50 keys and 8 KB of JSON.
- The protected traits `email`, `itch_user_id`, `stripe_customer_id` and `paddle_customer_id` are not sent (one warning). Only a server with the secret key can set them.
- Like `identify()`, it waits for consent. Calls before consent are merged and sent then.

## Verify Steam ownership

`link_steam()` links the Steam account that runs the game to this install. Manalens checks a Steam ticket with Steam and reads which of your apps the account owns. The player does not sign in. See [Steam ownership](https://docs.manalens.dev/features/steam-ownership) and the [Link API](https://docs.manalens.dev/api/link).

With [GodotSteam](https://godotsteam.com), set `"steam_link": true` (or **Project Settings > Manalens > Steam Link** under Advanced Settings), or call `link_steam()` with no argument. After consent, once per launch, the SDK calls `Steam.getAuthTicketForWebApi("manalens")`, waits for the `get_ticket_for_web_api` signal, and posts the ticket to `<api_endpoint>/v0/link`. Without GodotSteam, or with Steam closed, it does nothing.

With your own Steam code, make a ticket with the identity `manalens` and pass its bytes:

```gdscript
Manalens.steam_linked.connect(func(linked: bool, status: int, code: String):
    if not linked:
        print("Steam link failed: ", status, " ", code))
Manalens.link_steam(ticket_bytes)
```

- The `steam_linked(linked, status, code)` signal gives the answer. `code` is the API error code (for example `STEAM_TICKET_INVALID` or `STEAM_NOT_CONNECTED`), or `STEAM_TICKET`, `NETWORK_ERROR`, `CONSENT_REQUIRED` or `IDENTITY_CHANGED`.
- A refused ticket is not sent again. After a `429` with `Retry-After` (60 s or less), the SDK tries once more, but not after `set_consent(false)` or `reset()` during the wait.
- Say in your privacy notice that your game sends a Steam ticket to Manalens to confirm ownership.

## Identify players by Steam ID (opt-in)

Set `"auto_identify": "steam"` (or **Project Settings > Manalens > Auto Identify** under Advanced Settings). After consent, once per launch, the SDK calls `identify("steam_<hash>", {"storefront": "steam"})` when the [GodotSteam](https://godotsteam.com) addon is present and Steam is running. The hash is the SHA-256 (hex) of `"<publishable_key>:<SteamID64>"`. The raw Steam ID is never sent.

- An `identify()` call from your game wins. After it, the SDK does not identify by Steam in that launch, and a later launch keeps the user ID your game set.
- Without GodotSteam, or with Steam closed, the SDK does nothing and logs no error. If your game starts Steam after the SDK, the SDK tries again for about one minute.
- This is pseudonymous, not anonymous. The publishable key ships in your game and Steam IDs are few, so someone can reverse the hash by brute force. The hash keeps the raw ID out of casual view and stops linking one player across projects. A new publishable key gives new user IDs.
- To store the raw Steam ID (for support), call `identify()` yourself.
