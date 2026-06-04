# Privacy

This is a plain-English description of what WAM Voice Capture does with your data. It is not legal text — it's the truthful description of how the code works. If you find a discrepancy between this document and what the code does, that's a bug; please [report it](https://github.com/artempolansky/wam-voice-capture/issues).

**Last updated:** 2026-06-04 (corresponds to v1.0.0).

---

## What runs on your machine, locally

- **Audio capture** — mic input (via `AVAudioEngine`) and optionally system audio (via `ScreenCaptureKit`). Captured PCM is processed in memory on your Mac.
- **Local Whisper** — if you choose this provider, audio is transcribed by `whisper-cli` from `whisper.cpp`, a subprocess running entirely on your Mac. No data leaves your machine for transcription.
- **Calendar reads** — if you grant Calendar access, the app reads today's events via `EventKit` to auto-name meeting transcripts and populate the Today menu. Event data stays in memory + is written to the YAML frontmatter of the local transcript file.
- **Tray logs** — written to `~/Library/Application Support/WAM Voice Capture/wam-voice-capture-tray.txt`. Only on your disk.
- **Transcripts** — written to `~/Documents/WAM Voice Capture Recordings/` (or wherever you configured). Only on your disk.

---

## What leaves your machine

### Deepgram (cloud STT) — only if you chose this provider

If you configure a Deepgram API key, your captured audio is **streamed in real time to `wss://api.deepgram.com/v1/listen`**. Deepgram is a third-party service — see [their privacy policy](https://deepgram.com/privacy).

Specifically transmitted: audio bytes, your API key (as an HTTP header), the language code (`ru` by default), and stream metadata (sample rate, channel count). Returned: transcribed text.

**The app sends no audio to Deepgram if you've chosen Local Whisper as your provider.** Switch in tray → Settings → Speech recognition.

### Forward-to-server targets — only if you configured them

If you configure a "Forward transcripts to…" target, **transcript files** (the Markdown text — not raw audio) are `rsync`'d to the host you specified, into the directory you specified, using the SSH key you specified.

The app does not know or care what server you point to. It does not send your transcripts anywhere by default. You add a target explicitly.

### Update notifier — once per 24 hours, when enabled

When the auto-update check is on (default), the app makes one HTTPS `GET` per 24 h to `https://api.github.com/repos/artempolansky/wam-voice-capture/releases/latest`. The request contains:

- User-Agent string: `WAM-Voice-Capture/<your-version>`
- No identifying information beyond that

It does not send any audio, transcript content, or personal data to GitHub. GitHub may log the request IP per their normal infrastructure. Disable in tray → Settings → Check for updates automatically.

### Matter Lamp — only if you configured it

If you turn on the optional Matter Lamp integration, the app makes HTTP `GET` requests to the host you configured (e.g. `http://192.168.1.50:7420/mode/red`) when recording state changes. The lamp daemon is **your server on your local network**. No data leaves your LAN.

---

## What the app does NOT do

- ❌ No telemetry — no analytics, no crash reporters, no usage stats sent anywhere by the app.
- ❌ No background server we (the developer) control. There is no "WAM" backend.
- ❌ No advertising IDs, no fingerprinting, no third-party SDKs beyond what's listed above.
- ❌ No audio is uploaded if your STT provider is Local Whisper and no rsync target is configured.
- ❌ The app does not read or transmit any files outside the directories it explicitly works with.

---

## Permissions and what they're for

When the app first does something that needs a system permission, macOS will prompt you. Each is requested only when actually needed:

| Permission | What the app uses it for |
|---|---|
| Microphone | Capturing your voice for dictation and meetings |
| Accessibility | Listening for the global right-Option hotkey |
| Input Monitoring | Same global hotkey (macOS requires both Accessibility and Input Monitoring for `CGEventTap`) |
| Calendar | Reading today's events to auto-name meetings and populate the Today menu |
| Screen Recording | Capturing system audio (other party's voice) during meetings, via `ScreenCaptureKit` |
| Notifications | Showing "new version available" alerts from the Update notifier |

You can deny any of these and the rest of the app still works in reduced capacity. For example, denying Calendar means meeting files use generic names; denying Screen Recording means meetings only capture your mic.

---

## Storage locations

| What | Where |
|---|---|
| API keys (Deepgram) | macOS Keychain, under service `wam-voice-capture.deepgram.api_key` |
| Settings (mic device, recordings folder path, STT provider choice, light host, sync targets) | `UserDefaults` (`~/Library/Preferences/com.artempolansky.wam-voice-capture.plist`) |
| Sync target SSH key passphrases | None — the app uses your existing `~/.ssh/` keys; no passphrases are stored |
| Personal sync target configs (developer only) | `~/Library/Application Support/WAM Voice Capture/personal_targets.json` — gitignored, never shipped |
| Tray log | `~/Library/Application Support/WAM Voice Capture/wam-voice-capture-tray.txt` |
| Transcripts | `~/Documents/WAM Voice Capture Recordings/` (or your configured custom folder) |
| Whisper models | `~/Library/Application Support/WAM Voice Capture/models/` |

To completely uninstall and remove all data:

```bash
rm -rf "/Applications/WAM Voice Capture.app"
rm -rf "$HOME/Library/Application Support/WAM Voice Capture"
rm -rf "$HOME/Documents/WAM Voice Capture Recordings"
# Optional: remove keychain entry
security delete-generic-password -s wam-voice-capture.deepgram.api_key
```

---

## License and audit

The app is open source under the MIT License. Anyone can audit the code at [github.com/artempolansky/wam-voice-capture](https://github.com/artempolansky/wam-voice-capture). If you find a discrepancy between this document and what the code does, that's a bug; please file an issue or DM in [@weamclub](https://t.me/weamclub).
