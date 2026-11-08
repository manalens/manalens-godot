# Untitled Analytics for Godot 4

Game analytics for Godot 4 in plain GDScript (no native code). It works on every export target that has `HTTPRequest`: Windows, macOS, Linux, Android, iOS and Web.

It sends events to the Untitled Analytics collector (`POST /v0/events`) with your project's public **write key**, in the same envelope as the web SDK, with `context.app` in place of `context.page`. See the docs page `docs/sdks/godot.mdx` and `docs/sdks/app-events.mdx` in the Untitled Analytics repository.

## Install

1. Copy `addons/untitled_analytics` into your project's `addons/` folder.
2. Open **Project > Project Settings > Plugins** and enable **Untitled Analytics**. This adds the `UntitledAnalytics` autoload.

## Use

```gdscript
func _ready() -> void:
    UntitledAnalytics.init({
        "write_key": "ua_your_write_key",
        "endpoint": "https://your-collector.example.com",
        "app_version": "1.4.0",
        "build": "571",
        "storefront": "steam",  # steam, itch, epic, gog, app_store, play, other
    })

func _on_level_completed(level: int, score: int) -> void:
    UntitledAnalytics.track("level_complete", {"level": level, "score": score})

func _on_signed_in(player_id: String) -> void:
    UntitledAnalytics.identify(player_id, {"plan": "supporter"})
```

| Function | What it does |
| --- | --- |
| `init(options)` | Starts the SDK. Sends `session_start` and `game_open` (`is_first_open`, `first_open_at`). |
| `track(event, properties)` | Records an event. Property values are String, int, float, bool or null; other values are dropped. |
| `identify(user_id, traits)` | Attaches a player ID (kept on disk) and traits. |
| `reset()` | Ends the session, forgets the player ID, makes a new anonymous ID and starts a new session. |
| `set_consent(granted)` | Consent mode. `true` starts tracking; `false` deletes the ID, the session and the queue. |
| `flush()` | Sends queued events now. |
| `await shutdown()` | Sends `session_end` and flushes, for at most `quit_timeout_s`. |

Options: `write_key` and `endpoint` (required), `app_version`, `build`, `storefront`, `consent_required` (false), `flush_interval_s` (10), `flush_at` (20, also the batch size), `max_queue` (1000), `handle_quit` (true), `quit_timeout_s` (2), `debug` (false).

## How it works

- **Identity:** a random UUID in `user://untitled_analytics.cfg`, kept across launches. `identify()` stores the player ID in the same file.
- **Sessions:** a session continues while the game has focus. After 30 minutes without focus or events, the next activity ends the old session (`session_end` with `duration_s`) and starts a new one. A session left open by a crash is ended at its last activity on the next launch.
- **Queue:** events are batched and sent every 10 seconds, at 20 queued events, on focus loss or pause, and on quit. The queue is saved in `user://untitled_analytics_queue.json`, so events survive a crash or an offline session. At most 1000 events are kept, and events older than 7 days are dropped (the collector refuses them). Each event has a `message_id`, so a retry never counts twice.
- **Retry:** a network error or a 5xx, 408 or 429 response keeps the batch and waits about 2, 4, 8 ... seconds with jitter (at most 5 minutes). Other 4xx responses drop the batch, because a retry fails again.
- **Quit:** with `handle_quit` (default), the SDK handles the window close request: it sends `session_end`, flushes for at most `quit_timeout_s`, then quits. If your game handles the close request itself (for example with a confirmation dialog), set `handle_quit` to false and call `await UntitledAnalytics.shutdown()` before `get_tree().quit()`.
- **Consent:** with `consent_required: true`, no event is recorded and no ID is written until `set_consent(true)`. The choice is saved, so it applies on the next launch too. `identify()` before consent is sent after consent.
- **Context:** `context.app.platform` comes from `OS.get_name()`, `engine` is `godot`, and `app_version`, `build` and `storefront` come from `init()`.

## Web export

A web export runs in a browser, so its requests carry an `Origin` header. The collector accepts it only when the page is on your project domain or a subdomain (for example `play.example.com` for `example.com`). A build hosted on another site (for example itch.io's `html.itch.zone`) is refused with 403. Host the web build on your domain.

## Test

`sdks/godot/test_project` is a headless test project (the addon folder is a symlink). From the repository root, with the local stack running:

```bash
pnpm test:godot:local
```
