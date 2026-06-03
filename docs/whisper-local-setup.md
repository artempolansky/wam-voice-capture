# Local Whisper setup

WAM Voice Capture supports on-device speech recognition via [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Useful when:

- Network is unreliable (VPN drops, hotel WiFi, planes)
- You need to keep audio fully off external servers
- You're hitting rate limits / cost ceilings on Deepgram

Apple Silicon (M-series) gets Metal acceleration for free. On M4 the **base** model transcribes a minute of speech in ~3–5 seconds on first invocation, faster after (shaders cached).

## One-time install

### 1. Install the CLI

```bash
brew install whisper-cpp
```

This puts `whisper-cli` at `/opt/homebrew/bin/whisper-cli` (Apple Silicon) or `/usr/local/bin/whisper-cli` (Intel).

If brew's bottle download fails (you're behind a VPN that blocks `ghcr.io`), use the build-from-source path:

```bash
brew install --build-from-source whisper-cpp
```

Sources come from `github.com` which is usually reachable when bottle mirrors aren't.

### 2. Download a model

Models live at `~/Library/Application Support/WAM Voice Capture/models/`.

Pick one based on your trade-off:

| Model | Size | Quality | Speed on M4 |
|---|---|---|---|
| `ggml-tiny.bin`     | ~75 MB  | poor for Russian | very fast |
| `ggml-base.bin`     | ~142 MB | acceptable       | fast      |
| `ggml-small.bin`    | ~466 MB | good             | medium    |
| `ggml-medium.bin`   | ~1.5 GB | very good        | slow      |
| `ggml-large-v3.bin` | ~3.1 GB | best             | slowest   |

Download from HuggingFace:

```bash
cd ~/Library/Application\ Support/WAM\ Voice\ Capture/models/
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

The app picks the largest model it finds in that directory. So if you drop both `ggml-base.bin` and `ggml-medium.bin`, it uses medium.

### 3. Switch the app to Local Whisper

Tray → **Settings** → **Speech recognition** → click **Local Whisper**.

If the menu item is greyed out, the readiness line at the bottom of the submenu tells you what's missing (binary or model file).

## How it differs from Deepgram

| | Deepgram | Local Whisper |
|---|---|---|
| Streaming partials | Yes (text appears while you speak) | No (text appears 1–3 s after you stop) |
| Diarization | Yes (Speaker 2 vs 3 in system audio) | No (all system audio lumped as Speaker 2) |
| Network | Required | None |
| Cost | Per-minute API | One-time model download |
| Latency on dictation | ~200 ms | ~1–3 s (Metal compile on first call) |

The meeting transcript file still labels channels: **Speaker 1** = your mic, **Speaker 2** = system audio (other party on the call). What's lost vs Deepgram is intra-channel diarization — when three people on a Zoom call all come through your speakers, they all show up as Speaker 2 in Local Whisper mode.

## Troubleshooting

**Menu says "whisper-cli missing":** rerun `brew install whisper-cpp`. Verify with `which whisper-cli`.

**Menu says "no model file":** check `~/Library/Application Support/WAM Voice Capture/models/` for a `ggml-*.bin` file. The download must complete; partial files mislead the app.

**Transcription is slow on first run:** Metal shaders are compiling. Second run is much faster.

**Transcription is empty / mojibake:** verify the model file is intact (`shasum -a 256 ggml-base.bin` should match the SHA on the HuggingFace page). VPN-truncated downloads are the usual cause.
