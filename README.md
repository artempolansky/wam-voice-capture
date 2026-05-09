# VoiceMax

Voice capture for macOS, with two modes:

- **Push-to-talk dictation** — hold/tap **fn**, speak, release; transcript pastes into the active window
- **Meeting recording** — start from the tray, mic + system audio go through Deepgram with multichannel diarization, transcript appended live to a Markdown file in `~/Documents/VoiceMax-Recordings/`

Audio never touches a server we control — only Deepgram (STT) and, optionally, your own Matter Lamp daemon.

## Requirements

- macOS 13+ (ScreenCaptureKit needs 13 for system-audio capture)
- Apple Silicon or Intel Mac
- Deepgram API key — get one at [deepgram.com](https://deepgram.com)
- (Optional, for Telegram topic delivery, not yet wired) Homebrew + `brew install tdlib` and a Telegram `api_id`/`api_hash` from [my.telegram.org](https://my.telegram.org)

## First run

1. Build & install:
   ```bash
   bash scripts/install.sh
   ```
   The script downloads tdlib via Homebrew if missing, builds `VoiceMax.app`, copies it to `/Applications/`, and launches.

2. Grant permissions when macOS asks:
   - **Microphone** — required for any capture
   - **Accessibility** — required for the global fn-key tap
   - **Screen Recording** — required only for the **Meeting recording** mode (system audio capture)

3. Open the tray menu (top-right of the menu bar) and click **Deepgram API key…** to save your key. It's stored in your login Keychain.

That's the full first-run setup.

## Usage

**Dictation:** tap **fn**, speak, tap **fn** again. Transcript pastes into the focused window. The post-roll buffer keeps the last words; the pre-roll buffer captures up to 1.5 s of speech *before* you press fn.

**Meeting recording:** open the tray menu and click **Start meeting**. The transcript file appears at `~/Documents/VoiceMax-Recordings/YYYY-MM-DD-HHMM-meeting.md`. Live-tail it:

```bash
tail -f "$(ls -t ~/Documents/VoiceMax-Recordings/*.md | head -1)"
```

By default only **system audio** is recorded into `[Others]`. To inject your own words into `[Me]`, **hold fn while talking**. Release to close the gate. Click **Stop meeting** when done.

## Optional: Matter Lamp integration

If you run a [Matter Lamp HTTP daemon](https://github.com/lisacorp/matter-lamp-daemon) (or compatible — `GET /mode/<color>`), VoiceMax can drive it as a recording indicator: red while recording, breathing-blue while idle, breathing-warm-white while the mic is offline.

Enable in tray → **Light → Configure host…**, then toggle **Enabled**. Disabled by default.

## Updating

```bash
cd ~/voicemax && git pull && bash scripts/install.sh
```

## Logs

Plain-text log of every session boundary, error, and diagnostic:

```bash
tail -f ~/Library/Application\ Support/VoiceMax/voicemax-tray.txt
```

Or via the system log stream:

```bash
log stream --predicate 'subsystem == "com.voicemax.app"' --level debug
```

## Architecture

- `AudioCapture` — always-on AVAudioEngine input tap, 16 kHz Int16 mono, 1.5 s pre-roll ring, 50 Hz fanout to subscribers
- `SystemAudioCapture` — ScreenCaptureKit `SCStream` capturing system audio output, same 16 kHz format
- `DeepgramClient` — WebSocket to `wss://api.deepgram.com/v1/listen`, state machine with pending-queue buffering during handshake, single- and multi-channel modes
- `LocalCaptureSession` — fn-press dictation lifecycle, watchdog, paste delivery
- `MeetingSession` — long-running stereo merge (mic = L, system = R) → Deepgram with `multichannel=true`, live-append transcript with channel labels
- `LightControl` — fire-and-forget HTTP to the lamp daemon, circuit breaker on failures
- `TelegramClient` — TDLib auth flow (phone/code/2FA + session storage); topic-mode delivery is not yet wired into the dictation flow

No server. Audio leaves the machine only when bound for Deepgram (STT) or, optionally, the lamp daemon on your local network.

## License

MIT.
