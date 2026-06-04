# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
