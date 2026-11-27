# Changelog

## 0.5.2 (2026-11-27)

- Fix: a crash stack longer than 1024 characters made the collector refuse the whole `app_crash` (`INVALID_EVENT`), so the crash was lost. The stack now keeps the top frames, at most 1024 characters, the collector limit for a property value. Found in a production test of 0.5.1.

## 0.5.1 (2026-11-27)

- Crash stacks: long frame names are no longer masked as `[redacted]`. Frames are cleaned of home folders, URLs, and emails only; a C++ symbol such as `SDL_GetPerformanceFrequency` is code, not a token. The fingerprint now uses the real names. Engine error messages are cleaned as before.

## 0.5.0 (2026-11-27)

- Crash stacks (P-2831): on Windows, macOS, and Linux, `app_crash` now says where the game crashed. At the next launch, the SDK reads the backtrace that Godot's crash handler wrote to the log of the crashed run (the rotated file in `user://logs/`) and adds `stack` (GDScript frames first, then C++ frames), `error_type` (for example `SIGSEGV`), `message`, `fingerprint`, `crash_source` (`godot_log`), and `symbolicated`. The SDK installs no crash handler, never sends the same log twice, reads nothing before consent, and cleans the text as engine errors. Without crash data (a force quit, a power loss, or file logging off), `app_crash` is sent as before. New option `capture_crash_stacks` (default `true`).
- Tests: a new `crash_stack` step crashes the test project for real with `OS.crash()` and checks the next launch.

## 0.4.1 (2026-11-27)

- A `413` response (batch too large) no longer drops the batch (P-2853). The SDK keeps the events in the queue, in the same order, and sends again at once with half the batch (at least 1 event). This is not a failure: no backoff wait, and the failure counter does not change. A `413` for a batch of 1 event drops that event and emits `send_failed(413, 1)`. After a success, the batch size is `flush_at` again. Other status codes keep their handling.
- Docs: the README says why the SDK does not skip sends while the device has no network (P-2853). Godot 4 has no OS reachability API, so the backoff after network errors does not change. No change in behavior.

## 0.4.0 (2026-11-27)

- Breaking: standard names for error and crash events (the same in the Unity, Godot, and Unreal SDKs).
  - The crash event `app_unclean_exit` is now `app_crash`. Its properties (`previous_session_id`, `previous_build`, `previous_app_version`) and the rule that sends it do not change.
  - The `source` property of an `error` event is now `manual` (a `track_error()` call) or `auto` (any automatic capture). The old value `godot_logger` is now `auto`. The engine is in `context.app.engine`.
  - The engine log level of an automatic capture is now `log_type` (`error`, `script`, or `warning`). It was `engine_error_type`.
  - The per-session cap (`max_auto_errors_per_session`) applies to `auto` errors only, as before.

## 0.3.0 (2026-11-27)

- New `traits(traits)` (P-2814): set traits on this player, with or without a player ID. Before `identify()` the traits belong to the anonymous ID of this install. The protected traits `email`, `itch_user_id`, `stripe_customer_id`, and `paddle_customer_id` are not sent (one warning). Calls before consent are merged and sent after consent.
- New `link_steam(ticket)` and the option `steam_link` (P-2815), off by default. With GodotSteam, the SDK asks for a Web API ticket with the identity `manalens` once per launch after consent and posts it to `/v0/link` on the API host (new option `api_endpoint`; default: the `endpoint` with `events.` changed to `api.`). A game can also pass its own ticket bytes. The new `steam_linked(linked, status, code)` signal gives the answer. A refusal is not sent again; a `429` with `Retry-After` of 60 s or less is tried once more, but not after `set_consent(false)` or `reset()` during the wait. Without GodotSteam, the SDK does nothing. Also in **Project Settings > Manalens** under Advanced Settings.
- The shared fixture scenario has a `traits` event.

## 0.2.0 (2026-11-26)

- New option `auto_identify` (P-2513), off by default. With `"steam"`, after consent, the SDK identifies the player once per launch as `steam_<hash>` with the trait `storefront` = `steam`, when the GodotSteam addon is present and Steam is running. The hash is the SHA-256 (hex) of `"<publishable_key>:<SteamID64>"`, so the raw Steam ID is never sent. An `identify()` call from the game wins, and a user ID that the game set is never replaced. Without GodotSteam or Steam, the SDK does nothing. Also in **Project Settings > Manalens** under Advanced Settings.
- Console values (P-2776). New option `platform`: empty (default) detects the platform as before; a console port sets `ps5`, `xbox_series`, `xbox_one`, `switch`, or `switch2`. `storefront` also accepts `psn`, `xbox`, and `nintendo`.

## 0.1.5 (2026-11-26)

- Dedicated server builds (G-2533): a build with the `dedicated_server` feature tag, or a run with the `headless` display server (`--headless`), sends no `game_open`, `session_start`, `session_end`, or `app_unclean_exit`, and does not count as an install. The SDK prints one line that says why. `track()` and `identify()` still work. The new option `track_server_builds` (default `false`, also in **Project Settings > Manalens** under Advanced Settings) sends the automatic events from a server build. New `Manalens.is_server_build()`. Behavior change: a `--headless` run that used to send `game_open` and sessions now sends them only with `track_server_builds`. See the new docs page "Multiplayer and dedicated servers".

## 0.1.4 (2026-11-26)

- Each request sends `sent_at`, the device clock at the time of the send. The collector uses it to correct the event times, so a device clock that is fast or slow no longer gives wrong times or refused events (P-2799).
- The SDK follows `Retry-After` (P-2794). After a retried response (network error, `408`, `429`, `5xx`), it waits at least the `Retry-After` value (seconds or an HTTP date), at most 1 hour. Without the header, the backoff stays as before (2, 4, 8 ... seconds with jitter, at most 5 minutes). The collector sends `Retry-After` with a rate limit `429` and with a `503`, so the SDK no longer retries before the collector is ready.
- Changed: `set_before_send()` now runs on every event (track, identify, error, and the automatic events), not only on errors. The callback gets a copy of the whole event (`type`, `event`, `properties`, `traits`, `user_id`, ...) instead of the error properties; return it (changed or not), or null to drop it. The SDK takes `event`, `properties`, `traits`, and `user_id` from the result. If the result changes or removes `type`, `message_id`, `anonymous_id`, `session_id`, or `context.app`, the original event is sent. Errors pass the error limits first. Update a callback that read `props.message` to read `event.properties.message` (G-2527).
- Privacy: `set_consent(false)` and `reset()` now clear the breadcrumbs (the last event names), the error limits, and the dropped-error count. Event names from before a withdrawal or a sign-out no longer reach a later `error` event. `reset()` sends the old `errors_dropped` in the old `session_end` first (P-2783).
- Privacy: engine and script errors captured on Godot 4.5+ are cleaned before they are queued, with the rules of the Unreal plugin. The home folder and `/Users/<name>`, `/home/<name>`, `X:\Users\<name>` become `~`. URLs lose their user, query, and fragment. Emails become `[email]`. The values after `key`, `token`, `secret`, `password`, and `authorization` with `=` or `:` (also JSON, and quoted values up to the closing quote) and after `bearer`, JWTs, base64 runs of 24 or more characters with `+` or a trailing `=`, and runs of 24 or more letters, digits, `_`, and `-` become `[redacted]`. The fingerprint is computed from the cleaned text. `track_error()` text is not changed (P-2783).

## 0.1.3 (2026-11-26)

- Setup without code (G-2532): **Project > Project Settings > Manalens > General** (publishable_key, endpoint, auto_init, consent_required; app_version, build and storefront under Advanced Settings). With a key and auto_init on, the autoload starts the SDK at the end of the first frame. `init()` called earlier wins, and its options override the settings.
- A **Manalens** dock: the key check (`mana_pk_`, never a secret or API key), **Send test event** (one `manalens_test_event` with build `editor`, straight to the collector, no install and no session) with the result and the collector's reason, and a link to the app.
- `init()` takes no argument to use only the Project Settings values.

## 0.1.2 (2026-11-26)

- Fixed: a focus event after `shutdown()` started a new, empty session. Now a focus event keeps only an open session alive; the next event starts a new one. Same rule as the flush timer in 0.1.1. Found in the `with-unity` example with 0.1.1.

## 0.1.1 (2026-11-26)

- Fixed: a quit added an empty session. While `shutdown()` waited for the last send, the flush timer could fire and start a new session after `session_end`. So each quit counted one extra session with no events. Found in the `with-unity` example run (P-2676).
- Fixed: an install could be lost. `game_open` (with `is_first_open`) and `app_unclean_exit` stayed only in memory until the next save of the queue (a full batch, the flush timer, focus loss, or quit). A first launch with no network that was killed before then lost the install, and the next launch sent `is_first_open` false. Now the queue is written to disk as soon as these events are queued, before any send (P-2773).
- Fixed: the queue file is written to a temporary file and then renamed, as the state file. A crash during a write no longer leaves a cut-off queue.
- Fixed: in a web export, a reload right after a save lost the state. `user://` reaches IndexedDB only a moment after a write, so the next load made a new anonymous ID (10 of 10 tries), and an opt-out followed by an immediate reload started tracking again. Now the state, the queue and the opt-out marker are in the browser's `localStorage`, written at once, under a key with the project's user data folder. A file of 0.1.0 moves to `localStorage` on the first read. Without `localStorage`, `user://` as before (P-2791).
- Fixed: a web export sent `app_unclean_exit` after every reload or closed tab. A browser tab has no quit event, so the SDK does no crash detection on web. The old session still ends at its last activity. Found in the Unity WebGL test (P-2534).
- Fixed: `identify()` did not send the traits. The traits were kept next to the event in the queue, not in the event. Found by the shared request fixtures (`sdks/SPEC.md`).
- Refused events of an accepted batch (`202` with `rejected` above 0, P-2787) are dropped, logged with their reason codes, and reported by `send_failed(202, count)`. `flushed` counts only the stored events.

## 0.1.0 (2026-11-24)

First release.

- `init()`, `track()`, `identify()`, `reset()`, `flush()`, and `shutdown()`.
- `game_open` with `is_first_open` and `first_open_at`; `session_start` and `session_end` with `duration_s`.
- Offline queue on disk (1000 events, 7 days), batches of 20, and retries with backoff.
- Consent mode with `set_consent()`.
- `track_error()`, `set_before_send()`, and automatic engine and script errors on Godot 4.5 and later.
- `link_url()` for the website handoff.
- Event properties and traits: at most 50 keys and 8 KB.
