# WAM Voice Capture — Specification

*Source of truth for product, architecture, and acceptance. Approved 2026-05-07.*

---

## 0. Decisions log

| Decision | Value | Date |
|---|---|---|
| App display name | `WAM Voice Capture` | 2026-05-07 |
| Bundle identifier | `com.artempolansky.wam-voice-capture` | 2026-05-07 |
| Repository | `artempolansky/wam-voice-capture` (private; will flip public at v1.0.0-public) | 2026-05-07 |
| License | MIT | 2026-05-07 |
| Apple Developer Program | Deferred — release unsigned (ad-hoc) until ADP membership taken | 2026-05-07 |
| Distribution | GitHub Releases (DMG + zip), no Homebrew Cask until signed | 2026-05-07 |
| Auto-updates | Self-rolled GitHub Releases poll + tray notification (no Sparkle until signed) | 2026-05-07 |
| Min macOS | 14.0 (required for Apple AEC `voiceProcessingEnabled`) | 2026-05-07 |
| Monetization | Free, open source, optional donations | 2026-05-07 |
| Support | GitHub Issues + Discussions | 2026-05-07 |
| STT providers (v1) | Deepgram + OpenAI-compatible Whisper + Apple Speech | 2026-05-07 |
| Delivery targets | Generic webhook + Telegram Bot API (HTTP, no TDLib) | 2026-05-07 |
| Personal Angelina preset | Local-only `personal_targets.json`, gitignored | 2026-05-07 |
| Hotkey default | F5 (configurable via picker) | 2026-05-07 |
| Mic engine | On-demand by default (no green menubar in idle); always-on as opt-in | 2026-05-07 |
| Speaker labels | Mic = `Speaker 1`; system audio diarized into `Speaker 2, 3, ...`; user-renamable | 2026-05-07 |

---

## 1. Vision

Menu-bar macOS app that:
- gives push-to-talk dictation into any window via configurable hotkey
- records meetings with both sides (mic + system audio), differentiates speakers, writes Markdown transcripts
- syncs with system Calendar (EventKit) for auto-naming and context
- delivers transcripts via webhook (or Telegram Bot) to any agent / pipeline
- supports Deepgram (cloud), OpenAI-compatible Whisper, and Apple Speech (offline)

**Privacy:** audio leaves the machine only to the STT provider the user configured, and optionally to the configured webhook(s). No telemetry. No vendor backend.

---

## 2. Functional requirements

### 2.1. Dictation (push-to-talk)

- **FR-D1.** Pressing the configured hotkey (default **F5**, keycode 96) starts mic recording.
- **FR-D2.** Pressing again stops, finalizes the transcript, and pastes it into the focused window.
- **FR-D3.** The hotkey event is **swallowed** (not propagated to the focused app — no Chrome refresh).
- **FR-D4.** Hotkey is configurable via tray menu picker ("Press any key…"). Stored in `UserDefaults`.
- **FR-D5.** Pre-roll buffer is opt-in via "Always listen for better pre-roll" setting. Default OFF — no green menubar indicator in idle.

### 2.2. Meeting recording

- **FR-M1.** "Start meeting" (manual or auto-from-calendar) records two channels:
  - L = microphone → labelled `Speaker 1` (always you)
  - R = system audio (ScreenCaptureKit) → diarized into `Speaker 2`, `Speaker 3`, ...
- **FR-M2.** No hold-to-talk gate during meeting; both channels capture from start to stop.
- **FR-M3.** Apple AEC (`AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`) is enabled to suppress speaker echo on mic input. No-op on headphones.
- **FR-M4.** Transcript is appended live to a `.md` file on every `is_final=true` event from STT.
- **FR-M5.** Format: `HH:MM Speaker N: text` or `HH:MM <name>: text` after rename.
- **FR-M6.** Tray during recording exposes "Stop meeting" and "Rename Speaker N → …" for each active speaker. Rename rewrites all past and future occurrences in the file.
- **FR-M7.** Speaker IDs are session-local (Speaker 2 in one meeting ≠ Speaker 2 in another).
- **FR-M8.** STT providers without diarization (Whisper, Apple Speech) collapse all system-audio voices into `Speaker 2`. Documented in tray.

### 2.3. Calendar (EventKit)

- **FR-C1.** Calendar permission requested on first relevant action.
- **FR-C2.** Tray menu **Today ▸** lists today's events; click starts a meeting tied to that event.
- **FR-C3.** Starting a meeting during an active event (±5 min from now) auto-fills:
  - File name: `YYYY-MM-DD-HHMM-<slug-of-title>.md`
  - File header: title, time range, attendees, parsed Zoom/Meet/Teams URL, calendar source.
- **FR-C4.** No active event → fallback `YYYY-MM-DD-HHMM-meeting.md` with no header.
- **FR-C5.** Optional notification 1 min before event with "Start recording" button. Default OFF.

### 2.4. Recordings folder

- **FR-S1.** Tray menu **Recordings folder ▸** shows current path + Change… (NSOpenPanel).
- **FR-S2.** Default: `~/Documents/WAM Voice Capture Recordings/`.
- **FR-S3.** Any folder valid (iCloud Drive, Dropbox, etc.).
- **FR-S4.** Reset to default option.

### 2.5. Delivery (webhook / Telegram Bot)

- **FR-W1.** Tray menu **Send to ▸** lists configured delivery targets with on/off toggles. Multiple targets supported (e.g., webhook + Telegram bot fired in parallel).
- **FR-W2.** Each target is one of:
  - **Webhook** — URL + Bearer token (in Keychain)
  - **Telegram Bot** — bot token (from @BotFather) + chat_id or @username + optional `message_thread_id`
- **FR-W3.** Webhook payload (`POST <URL>`):
  ```json
  {
    "title": "Event title or 'Dictation'",
    "body": "<full markdown content>",
    "timestamp": "2026-05-05T14:30:00Z",
    "source": "WAM Voice Capture v1.x.x",
    "type": "meeting" | "dictation",
    "metadata": {
      "duration_seconds": 1800,
      "speakers": ["Speaker 1", "Anya", "Speaker 3"],
      "calendar_event_id": "..."
    }
  }
  ```
- **FR-W4.** Telegram Bot delivery: `POST https://api.telegram.org/bot<TOKEN>/sendMessage` (or `sendDocument` for transcripts >4096 chars).
- **FR-W5.** On network error: transcript stays local, tray shows "Last send failed: <error>" with Retry.
- **FR-W6.** Per-target Test button sends a synthetic message.
- **FR-W7.** Personal Angelina preset is local-only (`personal_targets.json`, gitignored). Public build ships zero presets.

### 2.6. STT providers

- **FR-T1.** Tray menu **STT Provider ▸**:
  - **Deepgram** (default) — API key, model (default nova-3), language (default ru)
  - **Whisper (OpenAI-compatible)** — API key, base URL (default `https://api.openai.com/v1`), model
  - **Apple Speech** — language, on-device toggle
- **FR-T2.** All providers implement a common `STTProvider` protocol. Switching restarts the active session if any.
- **FR-T3.** Capability matrix:

  | | Streaming | Diarization | Multichannel | Offline |
  |---|---|---|---|---|
  | Deepgram | ✓ | ✓ | ✓ | ✗ |
  | Whisper API | ✗ (file) | ✗ | ✗ | ✗ (✓ with self-hosted) |
  | Apple Speech | ✓ | ✗ | ✗ | ✓ (on-device) |

- **FR-T4.** Capability gaps fall back gracefully and are noted in the tray.

### 2.7. Auto-updates (public build only)

- **FR-U1.** App polls `https://api.github.com/repos/artempolansky/wam-voice-capture/releases/latest` every 24h.
- **FR-U2.** New version (semver `>` current) → tray notification "WAM Voice Capture vX.Y.Z available" with **Download** (opens release page in browser).
- **FR-U3.** No silent install — user downloads new DMG/zip and replaces manually.
- **FR-U4.** "Check for updates automatically" toggle in tray (default ON).

### 2.8. Inherited / unchanged

- Tray icon with idle / recording / error states
- Matter Lamp HTTP integration (optional, configurable)
- Logs in `~/Library/Application Support/WAM Voice Capture/wam-voice-capture-tray.txt` and via `log stream --predicate 'subsystem == "com.artempolansky.wam-voice-capture"'`

---

## 3. Non-functional requirements

- **NFR-1.** macOS 14.0+
- **NFR-2.** Apple Silicon + Intel, fat binary (current build supports both)
- **NFR-3.** Ad-hoc `codesign -s -` (no Developer ID until ADP)
- **NFR-4.** No telemetry. Audio sent only to user-configured STT and webhooks.
- **NFR-5.** MIT licensed; source on GitHub.
- **NFR-6.** UI in English (Russian copy to follow).
- **NFR-7.** `.app` size < 50 MB (without TDLib: estimated ~10 MB).

---

## 4. Architecture

```
┌────────────────────────────────────────┐
│  StatusBarController (UI)              │
├────────────────────────────────────────┤
│  Sessions: LocalCapture, Meeting       │
├──────────────────┬─────────────────────┤
│  Audio:          │  STT:               │
│  - AudioCapture  │  - STTProvider      │
│    + AEC         │    protocol         │
│  - SystemAudio   │  - DeepgramSTT      │
│    Capture       │  - WhisperSTT       │
│                  │  - AppleSpeechSTT   │
├──────────────────┴─────────────────────┤
│  Bridges:                              │
│  - HotkeyTap (CGEventTap, configurable)│
│  - CalendarBridge (EventKit)           │
│  - WebhookTarget (URLSession)          │
│  - TelegramBotTarget (URLSession)      │
│  - LightControl (Matter Lamp)          │
│  - UpdateNotifier (GitHub Releases)    │
├────────────────────────────────────────┤
│  Storage: Keychain, UserDefaults, FS   │
└────────────────────────────────────────┘
```

### New files (over baseline)

- `HotkeyTap.swift` (replaces `FNKeyTap.swift`)
- `HotkeyPicker.swift`
- `CalendarBridge.swift`
- `STTProvider.swift` (protocol)
- `WhisperClient.swift`
- `AppleSpeechClient.swift`
- `WebhookTarget.swift`
- `TelegramBotTarget.swift` (replaces TDLib-based `TelegramClient.swift`)
- `SpeakerLabels.swift`
- `UpdateNotifier.swift`

### Removed

- `FNKeyTap.swift` (replaced)
- `TDLibBridge.h` and TDLib build path in `scripts/build-app.sh`

---

## 5. Out of scope (v1)

- iOS port
- LLM-based summarization of transcripts
- Local Whisper.cpp / NVIDIA Parakeet (post-v1)
- Mac App Store
- Custom domain, paid tiers
- Multi-user / shared meetings
- In-app transcript editor

---

## 6. Phased plan

Each phase = one issue + branch + PR. Phases are sequential; Milestones group them.

### Milestone 1 — Personal use ready

- **Phase 0** — Repo bootstrap (this commit)
- **Phase 1** — Rename: `VoiceMax` → `WAM Voice Capture` everywhere; Keychain + path migration
- **Phase 2** — Hotkey: F5 default + picker; key-event suppression
- **Phase 3** — Recordings folder picker
- **Phase 4** — Always-on dual-channel + diarization (`multichannel=true` + `diarize=true`) + AEC + speaker rename
- **Phase 5** — Calendar (EventKit): Today list, auto-name, header, optional notification
- **Phase 6** — On-demand mic engine (no idle green indicator); pre-roll opt-in

### Milestone 2 — Delivery

- **Phase 7** — Generic delivery: `DeliveryTarget` protocol, `WebhookTarget`, `TelegramBotTarget`. TDLib removed.

### Milestone 3 — STT abstraction

- **Phase 8** — `STTProvider` protocol; refactor Deepgram; add Whisper API client; add Apple Speech client.

### Milestone 4 — Public release

- **Phase 9** — README first-launch instructions ("right-click → Open")
- **Phase 10** — `UpdateNotifier`: GitHub Releases poll + tray notification
- **Phase 11** — GH Pages landing + privacy policy
- **Phase 12** *(deferred)* — Apple Developer Program: Developer ID signing, notarization, Sparkle 2, Homebrew Cask. When user takes ADP membership.

---

## 7. Acceptance per phase

See per-phase issue templates. Common gates for any merge:

1. CI green (build on `macos-14`)
2. Manual smoke: F5 → "test" → F5 → text pasted (verifies regression-free)
3. CHANGELOG updated under `[Unreleased]`
4. README updated if user-visible behavior changed

Common gates for any release tag:

1. All phases in milestone merged
2. Full QA checklist run (see §8)
3. `CFBundleShortVersionString` bumped in Info.plist
4. CHANGELOG section moved from `[Unreleased]` to versioned section

---

## 8. Manual QA checklist

### Smoke (every PR, ~5 min)

- [ ] App launches; tray icon appears
- [ ] Configured hotkey → "test dictation" → hotkey → text pastes into focused window
- [ ] Tray menu opens; all items render

### Full QA (per release, ~30 min)

**Dictation:**
- [ ] Hotkey works in Chrome (no refresh), Slack, Notion
- [ ] Picker change to another key works without app restart
- [ ] Mic indicator absent in idle (with on-demand mode); appears during recording

**Meetings:**
- [ ] 2-person Zoom: transcript shows Speaker 1 + Speaker 2 distinct
- [ ] 3+ persons: Deepgram differentiates Speaker 2 vs 3
- [ ] Rename Speaker 2 → name: applies retroactively to whole file
- [ ] Speakers mode (no headphones): no Speaker 1/Speaker 2 cross-contamination (AEC working)

**Calendar:**
- [ ] Today list reflects system Calendar
- [ ] Recording during event: file name has slug + header populated
- [ ] No event: fallback name, no header
- [ ] Permission revoked → app continues without crash

**Recordings folder:**
- [ ] Change → iCloud Drive path → next recording lands there
- [ ] Reset → default

**Delivery (post Phase 7):**
- [ ] Webhook target → end of dictation → POST received
- [ ] Telegram Bot target → message in chat
- [ ] Multiple targets fire in parallel
- [ ] Network failure → "Last send failed" + Retry

**STT (post Phase 8):**
- [ ] Switching providers in tray works mid-session (with restart)
- [ ] Whisper: file-based finalize after Stop
- [ ] Apple Speech: on-device mode produces partials

**Updates (post Phase 10):**
- [ ] Stub-bumped release on GitHub → notification within poll interval

---

## 9. Versioning & releases

Semantic Versioning. Tags `v<major>.<minor>.<patch>`.

Release cycle:

```
git tag v1.x.x → git push --tags
  → CI builds → ad-hoc signs → DMG → GitHub Release
  → UpdateNotifier picks up within 24h
```

CHANGELOG follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## 10. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Apple AEC artifacts on some hardware | Medium | Medium | "Disable AEC" toggle, fallback to raw mic |
| Unsigned app: user friction on first launch | High | Medium | README "right-click → Open" walk-through |
| Deepgram pricing/API change | Low | Medium | STT abstraction lets users switch to Whisper |
| User EventKit permission revoked | Medium | Low | Code already falls back; no crash |
| `voiceProcessingEnabled` edge cases | Low | Medium | Toggle to disable; logged for debugging |
| F-key conflicts with user's setup | Medium | Low | Picker allows any key |
| Telegram bot token leak (user-shared screenshot) | Medium | Low (user pain) | Token never displayed in tray once saved |
