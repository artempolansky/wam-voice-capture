# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
