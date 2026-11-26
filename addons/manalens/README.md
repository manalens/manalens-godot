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
        "storefront": "steam",  # steam, itch, epic, gog, app_store, play, other
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
| `link_url(url)` | Adds the handoff parameter (`mana_hid`) to a website URL, so the website joins this player without `identify()`. Use it with `OS.shell_open()`. Unchanged before consent. |
| `reset()` | Ends the session, forgets the player ID, makes a new anonymous ID and starts a new session. |
| `set_consent(granted)` | Consent mode. `true` starts tracking; `false` deletes the ID, the session and the queue. |
| `track_error(message, options)` | Sends an `error` event. Options: `severity`, `error_type`, `handled`, `stack`, `file`, `line`, `function`, `fingerprint`, `properties`. |
| `set_before_send(callable)` | Changes each error's properties before it is queued; return null to drop the error. |
| `flush()` | Sends queued events now. |
| `await shutdown()` | Sends `session_end` and flushes, for at most `quit_timeout_s`. |

Options: `enabled` (true; editor runs send events like a live game, and dev and live data go to the same project: to tell test builds apart, set `build` (for example `"dev"`) and filter by it), `publishable_key` and `endpoint` (required), `app_version`, `build`, `storefront`, `consent_required` (false), `flush_interval_s` (10), `flush_at` (20, also the batch size), `max_queue` (1000), `handle_quit` (true), `quit_timeout_s` (2), `capture_engine_errors` (true, Godot 4.5+), `capture_warnings` (false), `max_auto_errors_per_session` (50), `debug` (false).

## How it works

- **Identity:** a random UUID in `user://manalens.cfg` (in a web export: the browser's `localStorage`), kept across launches. `identify()` stores the player ID in the same file.
- **Sessions:** a session continues while the game has focus. After 30 minutes without focus or events, the next activity ends the old session (`session_end` with `duration_s`) and starts a new one. A session left open by a crash is ended at its last activity on the next launch.
- **Queue:** events are batched and sent every 10 seconds, at 20 queued events, on focus loss or pause, and on quit. The queue is saved in `user://manalens_queue.json`, so events survive a crash or an offline session. At most 1000 events are kept, and events older than 7 days are dropped (the collector refuses them). Each event has a `message_id`, so a retry never counts twice.
- **Retry:** a network error or a 5xx, 408 or 429 response keeps the batch and waits about 2, 4, 8 ... seconds with jitter (at most 5 minutes). Other 4xx responses drop the batch, because a retry fails again.
- **Quit:** with `handle_quit` (default), the SDK handles the window close request: it sends `session_end`, flushes for at most `quit_timeout_s`, then quits. If your game handles the close request itself (for example with a confirmation dialog), set `handle_quit` to false and call `await Manalens.shutdown()` before `get_tree().quit()`.
- **Consent:** with `consent_required: true`, no event is recorded and no ID is written until `set_consent(true)`. The choice is saved, so it applies on the next launch too. `identify()` before consent is sent after consent.
- **Errors:** on Godot 4.5+, `error_logger.gd` (an `OS.add_logger()` logger) collects engine and script errors under a Mutex, and the SDK sends them on the main thread. Limits: the same fingerprint once a second, 20 errors in 10 seconds, 5 engine errors in one frame and 50 in one session. Dropped errors are counted in `session_end` (`errors_dropped`).
- **Crashes:** when the last run did not exit normally while the game had focus, the next launch sends `app_unclean_exit` in the old session, with `previous_session_id`, `previous_build` and `previous_app_version`. Not on web: a closed or reloaded tab has no quit event.
- **Context:** `context.app.platform` comes from `OS.get_name()`, `engine` is `godot`, and `app_version`, `build` and `storefront` come from `init()`.

## Web export

A web export runs in a browser, so its requests carry an `Origin` header. The collector accepts it when the page is on:

- your project domain or a subdomain (for example `play.example.com` for `example.com`);
- a host in **Project settings > Allowed origins**.

itch.io serves HTML5 builds from `html.itch.zone` and `html-classic.itch.zone`. A new project lists `*.itch.zone`, so an itch.io build works with no change. If you removed it, add `*.itch.zone` again (or click **Restore default**). For another portal, add its host (for example `*.crazygames.com`). A page on any other host gets 403. See [Allowed origins](https://docs.manalens.dev/sdks/app-events#allowed-origins).

## Test

`sdks/godot/test_project` is a headless test project (the addon folder is a symlink). From the repository root, with the local stack running:

```bash
pnpm test:godot:local
```
