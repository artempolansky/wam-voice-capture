# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Phase 0: repo bootstrap — `.gitignore`, GitHub Actions CI (build), `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/SPEC.md`.
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
