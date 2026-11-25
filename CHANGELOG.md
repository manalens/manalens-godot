# Changelog

## Unreleased

- Fixed: a web export sent `app_unclean_exit` after every reload or closed tab. A browser tab has no quit event, so the SDK does no crash detection on web. The old session still ends at its last activity. Found in the Unity WebGL test (P-2534).
- Fixed: `identify()` did not send the traits. The traits were kept next to the event in the queue, not in the event. Found by the shared request fixtures (`sdks/SPEC.md`).
- Refused events of an accepted batch (`202` with `rejected` above 0, P-2787) are dropped, logged with their reason codes, and reported by `send_failed(202, count)`. `flushed` counts only the stored events.

## 0.1.0

First release.

- `init()`, `track()`, `identify()`, `reset()`, `flush()`, and `shutdown()`.
- `game_open` with `is_first_open` and `first_open_at`; `session_start` and `session_end` with `duration_s`.
- Offline queue on disk (1000 events, 7 days), batches of 20, and retries with backoff.
- Consent mode with `set_consent()`.
- `track_error()`, `set_before_send()`, and automatic engine and script errors on Godot 4.5 and later.
- `link_url()` for the website handoff.
- Event properties and traits: at most 50 keys and 8 KB.
