# WAM Voice Capture

Menu-bar voice capture for macOS, with two modes:

- **Push-to-talk dictation** — tap the configured hotkey (default `fn`, configurable to F5 or any other key in [Phase 2](https://github.com/artempolansky/wam-voice-capture/issues/3)), speak, tap again; transcript pastes into the active window.
- **Meeting recording** — start from the tray, mic + system audio go through Deepgram with multichannel diarization, transcript appended live to a Markdown file in `~/Documents/WAM Voice Capture Recordings/`.

Audio never touches a server we control — only Deepgram (STT) and, optionally, your own Matter Lamp daemon. See [docs/SPEC.md](docs/SPEC.md) for the full product spec, decisions log, and phased plan.

## Requirements

- macOS 14+ (Sonoma) — required for Apple AEC (`voiceProcessingEnabled`)
- Apple Silicon or Intel Mac
- Deepgram API key — get one at [deepgram.com](https://deepgram.com)
- (Optional, for legacy Telegram delivery) Homebrew + `brew install tdlib` and a Telegram `api_id`/`api_hash` from [my.telegram.org](https://my.telegram.org). Being replaced with the simpler Bot API in [Phase 7](https://github.com/artempolansky/wam-voice-capture/issues/8).

## First run

1. Build & install:
   ```bash
   bash scripts/install.sh
   ```
   The script downloads tdlib via Homebrew if missing, builds `WAM Voice Capture.app`, copies it to `/Applications/`, and launches.

2. Grant permissions when macOS asks:
   - **Microphone** — required for any capture
   - **Accessibility** — required for the global hotkey
   - **Screen Recording** — required only for the **Meeting recording** mode (system audio capture)
   - **Calendar** — for auto-naming meeting transcripts and Today's events in the menu (Phase 5)

3. Open the tray menu (top-right of the menu bar) and click **Deepgram API key…** to save your key. It's stored in your login Keychain.

That's the full first-run setup.

## Upgrading from VoiceMax 1.0.0

If you previously ran VoiceMax 1.0.0 on this Mac, the new build migrates your state automatically on first launch:

- **Deepgram API key** — copied forward from `voicemax.deepgram.api_key` in Keychain (no re-entry)
- **Application Support data** (TDLib session, logs) — moved from `~/Library/Application Support/VoiceMax/` to `~/Library/Application Support/WAM Voice Capture/`
- **UserDefaults settings** (mic device, Matter Lamp config) — copied forward

**Old transcripts** in `~/Documents/VoiceMax-Recordings/` are **not** moved — keep them where they are or move them yourself. New recordings land in `~/Documents/WAM Voice Capture Recordings/`.

You can uninstall the old VoiceMax 1.0.0 at any time after the new build runs once:

```bash
rm -rf /Applications/VoiceMax.app
```

## Usage

**Dictation:** tap the hotkey, speak, tap again. Transcript pastes into the focused window. The post-roll buffer keeps the last words; the pre-roll buffer captures up to 1.5 s of speech *before* you press the hotkey.

**Meeting recording:** open the tray menu and click **Start meeting**. The transcript file appears at `~/Documents/WAM Voice Capture Recordings/YYYY-MM-DD-HHMM-meeting.md`. Live-tail it:

```bash
tail -f "$(ls -t ~/Documents/WAM\ Voice\ Capture\ Recordings/*.md | head -1)"
```

By default only **system audio** is recorded into `[Others]`. To inject your own words into `[Me]`, **hold the hotkey while talking**. Release to close the gate. Click **Stop meeting** when done.

> **Note:** [Phase 4](https://github.com/artempolansky/wam-voice-capture/issues/5) replaces this hold-to-talk gate with always-on dual-channel recording, diarized speakers (`Speaker 1` for mic, `Speaker 2/3/...` for system audio), and Apple AEC for echo suppression on speakers.

## Optional: Matter Lamp integration

If you run a Matter Lamp HTTP daemon (or compatible — `GET /mode/<color>`), WAM Voice Capture can drive it as a recording indicator: red while recording, breathing-blue while idle, breathing-warm-white while the mic is offline.

Enable in tray → **Light → Configure host…**, then toggle **Enabled**. Disabled by default.

## Updating

```bash
cd ~/wam-voice-capture && git pull && bash scripts/install.sh
```

(Auto-update notifier with GitHub Releases poll arrives in [Phase 10](https://github.com/artempolansky/wam-voice-capture/issues/11).)

## Logs

Plain-text log of every session boundary, error, and diagnostic:

```bash
tail -f ~/Library/Application\ Support/WAM\ Voice\ Capture/wam-voice-capture-tray.txt
```

Or via the system log stream:

```bash
log stream --predicate 'subsystem == "com.artempolansky.wam-voice-capture"' --level debug
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the legacy view and [docs/SPEC.md](docs/SPEC.md) for the target architecture.

Key components:

- `AudioCapture` — always-on AVAudioEngine input tap, 16 kHz Int16 mono, 1.5 s pre-roll ring, 50 Hz fanout to subscribers
- `SystemAudioCapture` — ScreenCaptureKit `SCStream` capturing system audio output, same 16 kHz format
- `DeepgramClient` — WebSocket to `wss://api.deepgram.com/v1/listen`, state machine with pending-queue buffering during handshake, single- and multi-channel modes
- `LocalCaptureSession` — hotkey-press dictation lifecycle, watchdog, paste delivery
- `MeetingSession` — long-running stereo merge (mic = L, system = R) → Deepgram with `multichannel=true`, live-append transcript with channel labels
- `LightControl` — fire-and-forget HTTP to the lamp daemon, circuit breaker on failures
- `Migration` — one-shot legacy-layout migration from VoiceMax 1.0.0
- `TelegramClient` — TDLib auth flow (phone/code/2FA + session storage); topic-mode delivery is not yet wired into the dictation flow. Replaced with Telegram Bot API in [Phase 7](https://github.com/artempolansky/wam-voice-capture/issues/8).

No server. Audio leaves the machine only when bound for Deepgram (STT) or, optionally, the lamp daemon on your local network.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The full plan is in [docs/SPEC.md](docs/SPEC.md), and each phase has its own [GitHub issue](https://github.com/artempolansky/wam-voice-capture/issues).

## License

MIT.
