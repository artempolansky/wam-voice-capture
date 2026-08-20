# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.1] — 2026-08-19

First field test of v1.2.0's dictation resilience (same day) caught three gaps — the retry/replay machinery worked, but lost races it should have won. Log forensics from the failed session:

1. A retry connection completed its WS handshake ~1 s **after** the fixed 5 s drain deadline in `stop()` expired. Its finals — the full dictation, re-transcribed from the replay buffer — arrived just after 0 chars had already been pasted.
2. The retry loop wiped `finalSegments` at retry **start**, so when a retry never opened, 3 perfectly good finals from the previous connection were discarded (log: `transcripts=3`, `finals=0`).
3. The REST fallback was single-shot; the same VPN blip that killed the WS ate the one POST too.

### Fixed
- **Drain deadline extends when a connection opens mid-drain.** On seeing the open, `finish()` is re-sent (the CloseStream issued pre-open can be swallowed by the handshake) and the wait extends 4 s so the late connection's finals land in the paste instead of the void.
- **Retry now parks collected finals instead of wiping them.** The stash is discarded only when the fresh connection actually opens (its replay re-covers everything). At paste time the stash is the second-to-last resort: live finals → interim → REST fallback → parked finals.
- **REST fallback tries 3 times, 1 s apart.**

### Notes
- When the VPN is fully down for the whole dictation (not a blip), Deepgram still can't produce anything — no code fixes that. The tray strobes red (watchdog) during such sessions; switching to Local Whisper (Settings → Speech recognition) is the offline escape hatch.

## [1.2.0] — 2026-08-19

**Dictation now survives VPN blips on Deepgram.** Field data made the asymmetry obvious: meetings on Deepgram logged 2203 reconnects (one stretch reached attempt 244) and still produced full transcripts, while dictation pasted **0 chars 168 times** — because meetings retry until the socket comes back and dictation gave up after a single failed handshake. The user experienced this as "the tray icon blinks and nothing pastes" roughly every other dictation.

### Added
- **Full-session audio buffer** (`DictationAudioTap`): every dictation's PCM (pre-roll included) accumulates in memory for the whole session — a few hundred KB for typical dictations, hard-capped at 20 MB. The tap also routes live chunks to the current provider, which is what makes mid-session provider swaps possible.
- **Reconnect-with-replay**: if the Deepgram WebSocket errors or closes while you're still dictating, a retry loop rebuilds the connection every 0.6 s. Each fresh connection receives the **entire buffered audio from the start of the dictation** (finals collected by the dead connection are discarded so nothing duplicates). You keep talking; a mid-dictation blip costs nothing.
- **REST fallback** (`DeepgramRESTClient`): if by the time you tap ⌥ to stop the streaming path has produced zero text, the whole buffer is POSTed to Deepgram's one-shot `/v1/listen` REST endpoint (same nova-3 model, same params → identical quality). A single short HTTPS request survives VPN conditions that kill long-lived sockets. Costs +1–2 s over a healthy stream; returns text where the old code returned nothing.

### Not changed
- Meetings — already resilient via v1.0.3 reconnect + v1.1.0 chunked Whisper. REST is wrong for hour-long audio anyway.
- Whisper dictation — local, can't fail transiently, never enters the retry loop.

## [1.1.0] — 2026-08-19

**Chunked Whisper inference during the meeting.** The architectural fix that was foreshadowed in every 1.0.x release note since v1.0.1. Two field outages made it non-optional:

- **2026-06-26:** a 54-minute Whisper meeting hung `whisper-cli` for 7+ minutes on a 207 MB WAV in `read_audio_data: trying to decode with miniaudio` (process `S` state, near-zero CPU). Recovered offline via a chunked replay script; transcript was 696 segments across ~65 min.
- **2026-08-19:** repeat of the exact same failure at 16:05. Two-hour meeting, 104 MB mic WAV, another 6-min hang. Recovered by the same replay script; 787 real lines of dialog.

Both incidents share one root cause: we accumulated the entire meeting into one giant WAV and fed it to `whisper-cli` at `finish()` time. Beyond ~30 minutes the file crossed some miniaudio / memory-pressure threshold and inference stalled.

### Fixed
- `WhisperLocalClient` now runs a **flush timer** at 30-second intervals. On each tick it swaps the accumulated audio out of the buffer atomically and dispatches a `whisper-cli` invocation for that chunk on a serial inference queue. Each chunk is a manageable ~1–2 MB WAV that transcribes in a few seconds. Segments arrive live on `onTranscript`; MeetingSession appends them to the transcript file as they come.
- `finish()` invalidates the timer, enqueues the last partial chunk, and then enqueues a synthetic-close task on the same serial queue. Because the queue is serial, close fires only after every prior chunk has completed — the file always closes with the full transcript, never truncated.
- 30-second chunk size chosen to match whisper's native context window; larger risked the original hang, smaller wastes model-load overhead per invocation.

### Side effects (deliberate)
- The transcript **file grows live during the meeting** now, not just at Stop. Agent watchers that already rsync on `appendLine` (the default) will see it fill in near-real-time (~30-second lag). This matches Deepgram's behavior for the first time.
- On very short dictations (< 200 ms of audio) the flush is skipped — model-load overhead alone is bigger than the value of transcribing a fragment that short. Dictations rarely trip this because `finish()` fires long before the 30-second tick and pushes whatever was recorded, however small.
- Hallucination filter picked up new variants observed during recovery: "Редактор субтитров Н.Закомолдина", "Редактор субтитров А.Кулакова", "Корректор А.Егорова", "Субтитры создавал/делал dimatorzok". Small-model padding of silent tail regions.

### Not changed
- Deepgram (streaming) path is untouched — no chunking, no timer. The v1.0.3 reconnect-on-error fix continues to handle its VPN-related failure mode.
- `LocalCaptureSession` (push-to-talk dictation) uses the same WhisperLocalClient, but dictations are so short that `finish()` fires before the 30 s timer ever ticks — behavior is effectively identical to before.
- MeetingSession is untouched. The 10-minute finalize ceiling remains as a defense in depth; with chunking it should almost never be hit because the final partial chunk is always < 30 s of audio.

## [1.0.5] — 2026-07-09

Cosmetic-but-annoying fix. User on Local Whisper reported "tray icon blinks red during every dictation" — they interpreted it as "the app is broken and my speech is lost." It wasn't. The dictation was working (Whisper batched the audio and pasted the transcript on release), but the tray icon strobed 4 seconds into every session because the watchdog fired `STALLED`.

### Root cause
`LocalCaptureSession.checkHealth()` runs a stall watchdog that flips true when no transcript arrives within `stallGracePeriod`. That's correct for Deepgram (streaming — no partials means the socket is silently swallowing audio). It's wrong for Local Whisper, which is **batch by design** (as it was on v1.0.4 — v1.1.0 changes this): no mid-session transcripts, all segments arrived together on `finish()` after the user released the hotkey. Every Whisper dictation therefore hit STALLED at ~4s, `onStallChange(true)` fired, and the tray icon strobed red at 2Hz until the user released.

### Fixed
- `checkHealth()` now bails early when the active STT provider is `.whisperLocal`. No stall check, no red strobe on Whisper. Deepgram behavior unchanged.

## [1.0.4] — 2026-07-09

Every meeting since v1.0.0 shipped with only `Speaker 1` in the transcript — even in call recordings where 2-3 people clearly took turns talking. Confirmed against the last 40 meeting files: `Speaker 2` never appeared once.

### Root cause
`SpeakerLabels.internalID(channel:dgSpeaker:)` special-cased the mic channel (channel 0) to always return `speaker-1`, discarding Deepgram's per-word `speaker` field for that channel. On a typical single-Mac setup — laptop speakers or headphones playing a Zoom/Meet call, mic picking up both the user and the remote party's voice via acoustic bleed — Deepgram's diarize=true was correctly labelling the two voices as speaker 0 and speaker 1 inside that one channel, but the code was collapsing them into a single label. (System-audio diarization also never surfaced Speaker 2/3 in practice because Screen Recording permission was rarely granted; the fix here still helps that case, but the actual user-visible failure was in the mic path.)

### Fixed
- `SpeakerLabels` now uses a unified `(channel, dgSpeaker)` ordering across all channels. Speaker N = the N-th distinct `(channel, dgSpeaker)` pair heard in the meeting, in order of first appearance. In practice: the first voice on the mic (you) → Speaker 1, next distinct voice heard (the other party bleeding into the mic, or the same person on system audio if Screen Recording is granted) → Speaker 2, and so on.
- `activeSpeakers()` / rename API unchanged for the tray menu — the speaker numbering just now reflects reality instead of hard-coding "mic = Speaker 1 forever".

### Not fixed in this release
- Whisper hang on long meetings (>30 min) — same as v1.0.2 and v1.0.3 KNOWN section. Real fix is chunked Whisper inference (v1.1.0). Recovery script exists for meetings that hit the hang; see the 2026-06-26 recovery flow in the tray log.
- Local Whisper still doesn't diarize within a channel — it labels everything on the mic side as one speaker regardless. The v1.0.4 fix only affects Deepgram, which does per-word diarization.

## [1.0.3] — 2026-06-26

Hotfix for a long-running Deepgram failure mode confirmed by two field outages: meetings on 2026-06-25 at 16:00 and again on 2026-06-26 produced transcripts that **stop emitting at the N-th minute** (range 11–25 min) while the meeting itself appears to be running normally. User notices the silence only when reviewing the file later.

### Root cause
`MeetingSession.scheduleReconnect()` was wired only to `provider.onClose`. But Deepgram's URLSession-backed WebSocket frequently emits `onError` without a subsequent `onClose` on VPN/TLS blips — typical error texts: `Connection reset by peer`, `Operation canceled`, `Broken pipe`, `Socket is not connected`, `bad MAC` (OSStatus −9846). When that happens, the meeting keeps capturing audio + the mixer keeps pushing it into a closed socket → the provider keeps emitting `onError` per failed send (50+ identical lines/second), but `scheduleReconnect` never fires. Result: silent transcript stop, log spam, the rest of the meeting unrecoverable.

### Fixed
- **`MeetingSession.handleError(_)` now also schedules a reconnect** if the meeting is still running and the user hasn't pressed Stop. The existing `scheduleReconnect()` already cancels any in-flight reconnect task before queueing a new one, so a 50-error storm collapses into a single pending reconnect with the exponential backoff (2s → 4s → 6s → … capped at 30s) that was already in place.
- **`provider.onOpen` now also resets `sttClosed = false`** so a successful reconnect lets a subsequent Stop wait for the new provider's actual `onClose` instead of exiting the wait loop on the stale error-driven flag from the dead socket that preceded the reconnect.
- **Error log debounce.** Identical error messages within a 10-second window are collapsed into "first occurrence + N more times". The 16:00 outage produced 1000+ identical log lines; the new debounce caps that to roughly one line per actual event.

### Known (unchanged from v1.0.2)
- **Whisper hangs on long meetings** (≈ 30+ min). `whisper-cli` gets stuck somewhere between "trying to decode with miniaudio" and the first inference chunk on the 200+ MB single WAV we hand it at meeting-stop. CPU stays near zero, process state is `S` (sleeping). The 10-minute hard ceiling from v1.0.2 still kicks in and unhangs `MeetingSession`, but the transcript is empty. The proper fix — chunked Whisper inference during the meeting instead of one batch invocation at the end — is planned for v1.1.0 and is a real refactor; deliberately not in this hotfix.

## [1.0.2] — 2026-06-16

Hotfix for a v1.0.1 regression. A real outage on 2026-06-16 at 11:03 confirmed:

- A meeting with Deepgram hit a `TLS error caused the secure connection to fail` mid-stream. The user stopped the meeting normally.
- v1.0.1's stop() removed the previous 30 s wait deadline (good for legitimate batch-Whisper inference) but assumed every provider that emits `onError` will also eventually emit `onClose`. Deepgram does **not** on TLS / connection-reset — the URLSession-level error fires, the WebSocket protocol close never arrives.
- Result: `sttClosed` stayed false, the stop() wait loop heartbeat'd `still transcribing (Ns elapsed)…` indefinitely (logged 200+ seconds before user gave up), `isFinalizing` never cleared, every subsequent `start()` was refused with "Previous meeting is still being transcribed". User had to fully quit and relaunch the app to recover. The 11:03 transcript was lost entirely.

### Fixed
- **Meeting no longer hangs in `isFinalizing` after a Deepgram TLS/connection error.** `MeetingSession.handleError(_)` now flips `sttClosed = true` — a provider that errors out won't produce more `onTranscript` events anyway, so the wait loop has nothing left to wait for. Safe for Whisper too, where the deferred `onClose` would set it again (idempotent).
- **10-minute hard ceiling on the finalize wait** as a belt-and-suspenders safety net. Covers cases where neither `onClose` nor the new error-driven flip fires (process hang, kernel panic, network-stack failure not surfaced through delegate). Generous enough that legitimate Whisper inference on long meetings (up to ~30-min recordings on the base model) completes well within it. On timeout: a clear log line, then the transcript file is closed with whatever segments arrived and `isFinalizing` clears — no more app-restart-to-recover.

### Known (unchanged from v1.0.1)
- Whisper still runs as a **single batch invocation** on the full meeting audio at stop time. For very long meetings on `base`, inference can take several minutes — that's normal. The 10-minute ceiling above does **not** cover all pathological cases (e.g. recording a 4-hour meeting on `base` is likely to truncate).
- LocalCaptureSession (push-to-talk dictation) is unaffected — it had a 5 s deadline from before, which already exits cleanly on TLS errors.
- Chunked Whisper inference (real architectural fix) still planned for a future release.

## [1.0.1] — 2026-06-04

Hotfix for v1.0.0 friends-beta — meetings with Local Whisper longer than ~30 seconds came back **empty** because the meeting finalization waited only 30 s for whisper-cli's batch inference, then closed the transcript file (and sent `.done`) before whisper had a chance to emit any segments. v1.0.0 has been re-marked as pre-release; everyone should upgrade.

### Fixed
- **Whisper meetings no longer produce empty transcripts** — `MeetingSession.stop()` now waits indefinitely for the STT provider to flush, instead of the previous hard 30 s deadline. Whisper batch inference time scales with recording length (≈1 s of audio per 0.1–0.3 s of inference on Apple Silicon, model-dependent); the old deadline was just long enough to look correct on dictation-length tests and silently truncated every real meeting.
- The mic indicator and tray UI now go idle the **moment** the user clicks Stop, rather than waiting on inference — the meeting is over from the user's perspective immediately. A new `isFinalizing` state blocks the next `start()` until the previous session's transcript actually lands on disk; clicking Start during that window now shows a clear "Previous meeting is still being transcribed, please wait a few seconds." dialog instead of racing the old session's callbacks.
- Tray log writes a `still transcribing (Ns elapsed)…` heartbeat every 10 s during long inference, so it's obvious whisper is alive (vs. hung).

### Changed
- Stale strings: hotkey-failure log now says "right Option (⌥) tap-for-dictation" instead of "F5"; meeting-blocked dialog says "release the ⌥ key (right Option)" instead of "release FN".

### Known limitation (planned for v1.0.2)
- Whisper still runs as a **single batch invocation** on the full meeting audio at stop time. For a one-hour meeting on a base model, that's ≈3–10 min of inference between Stop and the transcript landing on the agent. A future release will switch to **chunked inference during the meeting** so most of the audio is already transcribed by stop time.
- Local dictation (push-to-talk) still has a 5 s flush deadline; on Whisper this can truncate long single dictations. Same fix as above but unfixed in v1.0.1 to keep the patch tight.

## [1.0.0] — 2026-06-04

First public release (friends-beta). Everything below is the cumulative state of the app since the v1.0.0 baseline; see the closed PRs and earlier `[Unreleased]` entries for the per-phase breakdown.

### Added
- **App icon** — custom blue gradient with "wm" mark. `assets/Icon.icns` generated from a 1024×1024 source via `iconutil`, embedded as `CFBundleIconFile`.
- **First-run UX** — when no speech recognition provider is configured, the tray menu shows a prominent **⚠ Setup needed** banner with a guided dialog that walks the user to either Deepgram setup or `brew install whisper-cpp` + model download.
- **macOS 14+ startup check** — if the binary is somehow launched on an older OS, a clear alert appears (instead of silently crashing on EventKit APIs) and the app quits.
- **Feedback shortcuts in tray** — "Send feedback (Telegram)" opens `t.me/weamclub`, "Report a bug (GitHub)" opens the Issues page. Also added as a third button in the About dialog.
- **Update notifier (Phase 10)** — polls `api.github.com/repos/.../releases/latest` once per 24 h, posts a system notification when a newer tag is available. Click → release page in browser. Toggle in Settings; manual "Check for updates now" item.
- **`docs/AGENT_PROTOCOL.md`** (closes #19) — full open protocol for third-party transcript watchers: inbox layout, file format, `.done` semantics, retry behavior, live-streaming option, 30-line example agent in Python.
- **`PRIVACY.md`** — plain-English data flow: what stays local, what goes where (Deepgram, configured rsync targets, GitHub for update checks), what doesn't go anywhere.
- **README.md** rewrite — step-by-step onboarding with Gatekeeper, all permissions, STT setup (Deepgram OR local whisper.cpp), troubleshooting, community links.
- **GitHub Actions release pipeline** (`.github/workflows/release.yml`) — fires on `v*.*.*` tag push, builds .app, packs via `ditto` (preserves ad-hoc signature + extended attrs), creates GitHub Release with auto-generated install instructions and CHANGELOG section.

### Changed
- Whisper hallucination filter expanded: now suppresses common YouTube-subtitle reflexes ("Продолжение следует...", "Спасибо за просмотр", "Подписывайтесь на канал", "Thanks for watching", "Subtitles by Amara.org", `(piano music)`, `[applause]`, etc.) — these never enter the transcript even when whisper produces them on silence/pauses.
- Dictation log now includes Deepgram's close `reason` (was: only the numeric code). Parity with the meeting log; helpful when diagnosing socket-not-connected flapping.
- `CFBundleShortVersionString` → `1.0.0`, `CFBundleVersion` → `3`.

### Added (earlier — recapping previous `[Unreleased]` entries from this cycle)
- Phase 5: Calendar integration via EventKit (closes #6).
  - Tray menu **Today ▸** lists today's events (start–end + title), with `●` marking events live right now. Click an event to start a meeting tied to it.
  - On Start meeting, if a calendar event is active in the now ± 5 min window, the transcript file is auto-named with the event slug (`2026-05-18-143012-standup-with-anya.md` instead of `…-meeting.md`) and gets a YAML frontmatter header with title, date, start/end, attendees, conferencing URL (Zoom/Meet/Teams parsed from notes/url/location), calendar source, and `calendar_event_id`.
  - No event in window → fallback to the existing `…-meeting.md` filename with the legacy `# Meeting <stem>` header. Backwards-compatible with existing agent watchers.
  - First-time calendar access requested via `EventKit.requestFullAccessToEvents()` (macOS 14+). Permission denied → Today submenu shows a link to System Settings; meetings still work without it.
  - `NSCalendarsUsageDescription` already present in Info.plist from Phase 1.
- New file `CalendarBridge.swift` — wraps `EKEventStore` with read-only API: `requestAccess()`, `todaysEvents()`, `currentEvent()`. Parses conference URLs from event notes/url/location using `NSDataDetector` + a list of known hosts.

### Removed
- TDLib (Telegram client) — retired in favor of file-sync (Phase 7a / AgentSyncTarget). Drops ~10 MB from the bundle (11 MB → 1 MB), removes the Homebrew dependency from `install.sh`, deletes `TelegramClient.swift`, `TDLibBridge.h`, `docs/TDLIB_BUILD.md`, all `TELEGRAM_BUILD` conditionals, and the Telegram menu items from the tray. `Migration.runOnce()` now also wipes the leftover `tdlib/`, `tdlib-files/` directories and the legacy Telegram/TDLib Keychain entries on first run after this upgrade.

### Changed
- Default Deepgram `language` switched from `multi` to `ru`. The `multi` mode misrecognized Russian dictation as French in real-world testing (\"Voulais juste\" for \"Раз два три\"). Phase 8 will add a language picker; until then `ru` is the empirically-correct default for this owner's workload.
- Meeting transcript filenames now include seconds: `YYYY-MM-DD-HHMMSS-meeting.md` (was `YYYY-MM-DD-HHMM-meeting.md`). Fixes a real bug where two meetings started in the same minute overwrote each other.

### Added
- Phase 3: recordings folder picker. Tray menu **Recordings folder ▸** now exposes the current path, **Open in Finder**, **Change…** (NSOpenPanel), and **Reset to default**. Configurable destination persists in `UserDefaults` (key `WAMRecordingsFolder`). iCloud Drive / Dropbox / external volumes all work — no security-scoped bookmarks needed because the app is not sandboxed.
- New file `RecordingsFolder.swift` — small helper centralizing the current-target resolution + fallback to default if the configured path is gone (e.g. external volume unmounted).

### Added
- Phase 7a: `AgentSyncTarget` + `AgentSyncRegistry` — generic rsync-over-SSH delivery of meeting transcripts to a configurable remote `inbox/`. ([#18](https://github.com/artempolansky/wam-voice-capture/issues/18))
  - One or more sync targets per machine, each independently togglable
  - Persistence: user-managed targets in `UserDefaults`; developer's private targets in gitignored `personal_targets.json` (loaded but never committed)
  - Tray menu **Send to ▸** lists targets with last-sync status, per-target submenu (Enabled / Include dictations / Test / Edit / Remove), and **Add target…** with a 5-field dialog
  - Lifecycle: on meeting start → initial rsync (header arrives); during meeting → debounced 2 s rsync on every `appendLine`; on stop → final rsync + `<basename>.done` empty marker file via SSH `touch`
  - Speaker rename also triggers a sync so the agent sees the rewritten labels promptly
  - `rsync -az --partial --inplace -e ssh` — `--inplace` is important so a remote watcher sees the file grow rather than racing an atomic rename
  - **Test** button uploads a probe file + cleans up on remote — verifies reachability and write-permission

### Changed
- Phase 7 redesigned: delivery is now file-sync (rsync over SSH) to a configurable remote `inbox/`, instead of HTTP webhook + Telegram Bot. Agent-agnostic — open protocol documented separately. Driving issue: [epic #17](https://github.com/artempolansky/wam-voice-capture/issues/17). Old [#8](https://github.com/artempolansky/wam-voice-capture/issues/8) closed.
- `docs/SPEC.md` §0 decisions log + §2.5 + §4 architecture + §6 phases updated accordingly.

### Added
- Phase 4: meetings always record both channels with per-speaker diarization (#5).
  - mic → `Speaker 1` (always you), system audio → `Speaker 2`, `Speaker 3`, ... numbered in order of first appearance via Deepgram `diarize=true` + per-word speaker IDs.
  - Tray menu during a meeting: **Rename speaker** submenu — renames apply retroactively to the whole transcript file (find/replace anchored on `HH:MM <label>: ` prefix) and to all subsequent lines.
  - File format changed: `[HH:MM:SS] [Label] text` → `HH:MM Speaker N: text` (per spec FR-M5).
  - `MeetingSession.setMeCapture` removed; FN no longer push-to-record-me during a meeting (FN now no-op while a meeting is running, since both channels are continuous).
  - `DeepgramClient`: new `diarize` init param + `Word` struct in `Transcript` carrying per-word `speaker`, `start`, `end`.
  - `SpeakerLabels`: new per-session registry mapping `(channel, dgSpeaker)` → stable internal ID, with rename API.
- Phase 0: repo bootstrap — `.gitignore`, GitHub Actions CI (build), `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/SPEC.md`.

### Deferred
- Apple AEC (`voiceProcessingEnabled`) — enabling it on this Mac left every mic candidate reporting `sampleRate=0.0/channels=0`. Needs per-device-type gating (built-in mic OK; aggregate / VPAU devices fail). Tracked separately. On laptop speakers without AEC, expect Speaker N's voice to bleed faintly into Speaker 1's channel; Deepgram's diarization usually still attributes the bulk correctly.
- Phase 1: rename `VoiceMax` → `WAM Voice Capture` (#2).
  - Bundle id `com.artempolansky.wam-voice-capture`, display name `WAM Voice Capture`, executable `WAMVoiceCapture`.
  - Source dir `VoiceMax/` → `WAMVoiceCapture/`; main entry `WAMVoiceCaptureMain.swift`.
  - One-shot `Migration.swift` runs at app launch:
    - copies `VoiceMax*` UserDefaults → `WAM*`
    - moves `~/Library/Application Support/VoiceMax/` → `WAM Voice Capture/` (preserves TDLib session, logs)
    - renames `voicemax-tray.txt` → `wam-voice-capture-tray.txt`
  - `KeychainHelper` reads new `wam-voice-capture.*` services with chained fallback to `voicemax.*` (VoiceMax 1.0.0) and `openclaw.*` (older fork); migrates forward + deletes legacy on first read.
  - Recordings folder default: `~/Documents/WAM Voice Capture Recordings/` (old `VoiceMax-Recordings/` left in place — not migrated by design).
  - Log subsystem: `com.artempolansky.wam-voice-capture`.
  - `LSMinimumSystemVersion` raised to 14.0 (required for Apple AEC `voiceProcessingEnabled`, used by Phase 4).
  - `CFBundleShortVersionString` `1.0.0` → `1.1.0-dev`.

### Changed
- Build target raised from macOS 13 to 14 (see Phase 4 / SPEC §0).

### Notes for upgraders
- Deepgram API key, Telegram TDLib session, and UI settings are migrated automatically on first launch — no re-entry needed.
- Old `~/Documents/VoiceMax-Recordings/` is intentionally left in place; new recordings go to the new folder.
- The legacy `/Applications/VoiceMax.app` can be removed manually after the new build runs once.

## [1.0.0] — 2026-05-04

Imported as baseline from VoiceMax 1.0.0.

### Features (inherited)
- Push-to-talk dictation via `fn` key with paste-on-release
- Meeting recording: mic + system audio (ScreenCaptureKit) → Deepgram with multichannel diarization
- Live-append Markdown transcripts at `~/Documents/VoiceMax-Recordings/`
- Optional Matter Lamp HTTP integration as recording indicator
- Telegram TDLib auth flow (delivery to topics not wired)
- Keychain-stored Deepgram API key

### Known limitations
- `fn` hotkey conflicts with macOS Dictation and language switcher
- Microphone always-on (green menubar indicator) for pre-roll buffer
- Meeting recording: mic gated by `fn` hold; user voice missing by default
- Hardcoded recording folder
- No calendar integration
- Telegram delivery not implemented
- Single STT provider (Deepgram only)
