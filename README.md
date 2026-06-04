# WAM Voice Capture

<p align="center">
  <img src="assets/Icon.iconset/icon_256x256.png" width="128" alt="WAM Voice Capture icon">
</p>

Menu-bar voice capture for macOS. Two modes, one tray icon:

- **Push-to-talk dictation** — tap right `⌥` (Option), speak, tap again; transcript pastes into the active window.
- **Meeting recording** — Start meeting from the tray; mic + system audio go through your chosen speech-to-text provider; transcript appended live to a Markdown file with YAML frontmatter (auto-populated from your Calendar event if any).

Your speech can stay **fully on-device** via local whisper.cpp, or use Deepgram if you prefer streaming + diarization. Optional file-sync to your own server lets a downstream agent process transcripts (see [docs/AGENT_PROTOCOL.md](docs/AGENT_PROTOCOL.md)).

> **Status:** v1.0.0 — friends-beta. Expect rough edges; please report them in the [community chat](https://t.me/weamclub) or [GitHub issues](https://github.com/artempolansky/wam-voice-capture/issues).

---

## Requirements

- macOS **14.0 (Sonoma) or later** — required for `AVAudioEngine` voice processing
- **Apple Silicon** Mac (M1 and newer). Intel builds are not produced by CI; you can build from source on Intel but performance with whisper.cpp will be slower.
- One of:
  - **Deepgram API key** — fast streaming + diarization, requires network. Free tier covers hours of meetings; sign up at [deepgram.com](https://deepgram.com).
  - **Local whisper.cpp** — fully offline, runs on Apple Silicon GPU via Metal. Slightly slower (1–3 s after Stop), no diarization within a channel, but no network and no API key.

---

## <a name="setup"></a>Setup (step by step)

### 1. Download

Grab the latest **`WAM Voice Capture.app.zip`** from [Releases](https://github.com/artempolansky/wam-voice-capture/releases/latest).

Unzip, drag `WAM Voice Capture.app` into `/Applications/`.

### 2. First launch — Gatekeeper

The app is ad-hoc signed (no Apple Developer Program yet — coming in a future release). macOS will refuse to open it from a normal double-click on first run. Workaround:

1. **Right-click** (or Ctrl-click) `WAM Voice Capture.app` in Finder
2. Choose **Open**
3. macOS shows a warning dialog — click **Open** again
4. The app is now permanently trusted on this Mac

You'll see a small icon appear in your menu bar (top-right). That's the tray.

### 3. Grant permissions

Click the tray icon. macOS will ask for permission as you use each feature, but you can pre-grant in **System Settings → Privacy & Security**:

| Permission | Required for | Where |
|---|---|---|
| **Microphone** | Any recording at all | Privacy & Security → Microphone |
| **Accessibility** | Right-Option global hotkey | Privacy & Security → Accessibility |
| **Input Monitoring** | Right-Option global hotkey | Privacy & Security → Input Monitoring |
| **Calendar** *(optional)* | Auto-naming + Today menu | Privacy & Security → Calendar |
| **Screen Recording** *(optional)* | System audio in meetings | Privacy & Security → Screen Recording |

For each, click `+` and choose `/Applications/WAM Voice Capture.app` if it's not already listed. Toggle ON.

### 4. Pick a speech recognition provider

If you launch the app with no provider configured, the tray menu shows **⚠ Setup needed — choose a Speech recognition provider**. Click it for a guided dialog.

**Option A — Deepgram (recommended for first-time users):**
1. Sign up at [console.deepgram.com](https://console.deepgram.com) (free tier, no credit card needed for ~1000 hours)
2. Create an API key
3. Tray → **Settings → Speech recognition → Deepgram API key…**
4. Paste the key, hit Save

**Option B — Local whisper.cpp (fully offline):**
1. Install the binary:
   ```bash
   brew install whisper-cpp
   ```
2. Download a model into `~/Library/Application Support/WAM Voice Capture/models/`:
   ```bash
   mkdir -p ~/Library/Application\ Support/WAM\ Voice\ Capture/models
   cd ~/Library/Application\ Support/WAM\ Voice\ Capture/models
   # base = 142 MB, fast on M-series, OK quality:
   curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
   # OR small = 466 MB, noticeably better Russian/English:
   curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
   ```
3. Tray → **Settings → Speech recognition → Local Whisper**

The bottom of the Speech recognition submenu shows readiness — `Local Whisper: ready (ggml-small.bin)` once both binary and model are in place.

### 5. Use it

**Dictation** — tap **right Option** (⌥), speak, tap again. Text pastes into whatever app has focus.

**Meeting** — tray → **Start meeting**. Speak. **Stop meeting** when done. Transcript lands in `~/Documents/WAM Voice Capture Recordings/`. Live-tail it:

```bash
tail -f "$(ls -t ~/Documents/WAM\ Voice\ Capture\ Recordings/*.md | head -1)"
```

---

## Optional: forward transcripts to an agent

WAM Voice Capture can rsync each meeting transcript to a folder on your own server, where any agent (your own scripts, [Angelina](https://github.com/artempolansky/angelina-ops), etc.) can process it. See [docs/AGENT_PROTOCOL.md](docs/AGENT_PROTOCOL.md) for the file layout and lifecycle contract.

Tray → **Settings → Forward transcripts to → Add target…**

---

## Optional: Matter Lamp indicator

If you run a Matter Lamp HTTP daemon (or compatible — `GET /mode/<color>`), the app can drive it as a recording indicator: red while recording, breathing-blue while idle, breathing-warm-white while the mic is offline.

Tray → **Settings → Lamp indicator → Configure host…** (only appears once you set a host once).

---

## Updates

The app checks GitHub Releases once a day and posts a system notification if a newer version is available. Clicking the notification opens the release page in your browser — download the new `.zip` and replace the app in `/Applications/`. No auto-install (would require Developer ID signing).

Toggle via tray → **Settings → Check for updates automatically**.

---

## Troubleshooting

**Tray menu says "⚠ Setup needed"** — no speech provider configured. Follow [step 4](#4-pick-a-speech-recognition-provider) above.

**Right Option doesn't trigger dictation** — the global hotkey needs Accessibility + Input Monitoring permissions. The log will say `Hotkey: CGEvent.tapCreate failed`. See step 3.

**App can't be opened, says "damaged"** — quarantine attribute. From Terminal:
```bash
xattr -cr "/Applications/WAM Voice Capture.app"
```
Then right-click → Open as in step 2.

**Local Whisper transcribes Russian as French gibberish** — make sure you're not running the `tiny` model; download `base` or `small` (see step 4 option B).

**Meeting transcript empty / "Whisper" header only** — STT close timeout. Check the log:
```bash
tail -50 ~/Library/Application\ Support/WAM\ Voice\ Capture/wam-voice-capture-tray.txt
```

**Where are my logs?**
```bash
tail -f ~/Library/Application\ Support/WAM\ Voice\ Capture/wam-voice-capture-tray.txt
```
Or via Console.app filtered by subsystem `com.artempolansky.wam-voice-capture`.

---

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the original sketch and [docs/SPEC.md](docs/SPEC.md) for the current spec + phased plan.

Key components:

- `AudioCapture` — on-demand AVAudioEngine input tap; 16 kHz Int16 mono; ring-buffer pre-roll
- `SystemAudioCapture` — ScreenCaptureKit `SCStream`, 16 kHz format
- `STTProvider` protocol with two implementations:
  - `DeepgramClient` — WebSocket streaming + diarization
  - `WhisperLocalClient` — whisper.cpp CLI subprocess, batch inference
- `CalendarBridge` — EventKit wrapper for Today menu + auto-naming
- `AgentSyncRegistry` / `AgentSyncTarget` — rsync-over-SSH delivery to a remote inbox
- `MeetingSession` / `LocalCaptureSession` — orchestrate audio → STT → file/paste
- `UpdateNotifier` — GitHub Releases poll, system notification on new tag

No server we control. Audio leaves the machine only to your chosen STT provider (Deepgram or none if Whisper-local) and optionally to your own configured rsync targets.

---

## Privacy

See [PRIVACY.md](PRIVACY.md). Short version: no telemetry, no analytics, no remote control.

---

## Community

- **Feedback / questions / ideas** — [t.me/weamclub](https://t.me/weamclub)
- **Bug reports** — [GitHub Issues](https://github.com/artempolansky/wam-voice-capture/issues)

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Full plan in [docs/SPEC.md](docs/SPEC.md).

## License

MIT.
