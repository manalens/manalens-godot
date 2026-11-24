# Changelog

## 0.1.0

First release.

- `init()`, `track()`, `identify()`, `reset()`, `flush()`, and `shutdown()`.
- `game_open` with `is_first_open` and `first_open_at`; `session_start` and `session_end` with `duration_s`.
- Offline queue on disk (1000 events, 7 days), batches of 20, and retries with backoff.
- Consent mode with `set_consent()`.
- `track_error()`, `set_before_send()`, and automatic engine and script errors on Godot 4.5 and later.
- `link_url()` for the website handoff.
- Event properties and traits: at most 50 keys and 8 KB.
