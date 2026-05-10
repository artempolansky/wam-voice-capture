# Architecture

> **Note:** this document describes the **inherited VoiceMax 1.0.0 architecture**.
> For the target architecture and phased plan toward WAM Voice Capture v1.x,
> see [SPEC.md](SPEC.md). Patterns marked *(legacy)* are being replaced.

## Goals

1. Use from any macOS device the owner logs into
2. Zero server infrastructure — nothing to deploy, nothing to maintain
3. Secure against session theft — encrypted, device-bound
4. Same codebase ready for iOS next

## Components

### Audio capture (`Sources/Audio/`)

`AudioCapture.swift` — AVAudioEngine input tap, converts native format to 16kHz mono Int16 PCM in 20ms chunks. No DJI MIC requirement — any available input device works. Device selection exposed in Settings.

### STT (`Sources/STT/`)

`DeepgramClient.swift` — WebSocket client to `wss://api.deepgram.com/v1/listen`. Parameters: `model=nova-3`, `language=ru`, `encoding=linear16`, `sample_rate=16000`, `interim_results=true`. Streams PCM chunks, emits partial and final transcripts via callbacks.

API key stored in Keychain (`wam-voice-capture.deepgram.api_key`, account `deepgram`). Migrates transparently from VoiceMax 1.0.0 (`voicemax.deepgram.api_key`) and the older OpenClaw fork (`openclaw.deepgram.api_key`) on first read.

### Telegram (`Sources/Telegram/`) *(legacy — being replaced in Phase 7)*

`TelegramClient.swift` — Swift wrapper around TDLib (Telegram's official C++ library). Handles:

- **Login flow** — phone number, SMS code, 2FA password
- **Forum topics** — `getForumTopics` for the configured group, filters closed topics
- **Delivery** — `sendMessage` with `message_thread_id` set to topic ID

TDLib database (encrypted SQLite) lives at `~/Library/Application Support/WAM Voice Capture/tdlib/`. Database encryption key is generated on first login and stored in Keychain (`wam-voice-capture.tdlib_db_key`, account `tdlib`).

[Phase 7](https://github.com/artempolansky/wam-voice-capture/issues/8) replaces TDLib with the simpler Telegram Bot API (HTTP, no native library, no user OAuth — bot token from `@BotFather`).

### Crypto (`Sources/Crypto/`)

`DeviceBinding.swift` — derives a stable key from the device's hardware UUID via IOKit:

```swift
let platformExpert = IOServiceGetMatchingService(
    kIOMainPortDefault,
    IOServiceMatching("IOPlatformExpertDevice")
)
let uuid = IORegistryEntryCreateCFProperty(
    platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
)
```

The UUID is fed through HKDF with a static salt to produce the TDLib database key. Key itself is stored in Keychain (`com.voicemax.tdlib.dbkey`, access `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). If the keychain entry is copied to another Mac, the UUID-derived seed differs, and key derivation yields a different result — TDLib database fails to decrypt, user must re-authenticate.

### UI

- `StatusBarController.swift` — tray icon, hotkey capture trigger, capture state management
- `Migration.swift` — one-shot legacy-layout migration from VoiceMax 1.0.0 (UserDefaults + Application Support directory)

## Data flow (recording → delivery)

```
Hotkey press
  → StatusBarController.doStart()
  → AudioCapture.start(device: selectedMic)
      emits 20ms PCM chunks
  → DeepgramClient.send(audioData: chunk)
      receives partial transcripts (shown in tray tooltip)
Hotkey press again
  → AudioCapture.stop()
  → DeepgramClient.disconnect()
      returns final transcript
  → [target delivery, e.g. paste into focused window]
  → Tray returns to idle
```

No HTTP server, no intermediate storage, no external state. Failure at any step leaves the tray in a recoverable state (recording flag resets, transcript buffer discarded on error).

## Configuration

Persisted in `UserDefaults.standard` (post-rename keys; `Migration.swift` copies from legacy `VoiceMax*` keys on first launch):

- `WAMSelectedRoute` — last selected topic ID
- `WAMFavoriteRoutes` — pinned topics
- `WAMRouteTitles` — custom display labels
- `WAMMicDeviceUID` — preferred input device UID (CoreAudio)
- `WAMGroupID` — Telegram group ID
- `WAMLightHost` / `WAMLightPort` / `WAMLightEnabled` — Matter Lamp config

Keychain (post-rename services; legacy `voicemax.*` and `openclaw.*` migrated on first read):

- `wam-voice-capture.deepgram.api_key` — Deepgram API key
- `wam-voice-capture.tdlib_db_key` — TDLib DB encryption key
- `wam-voice-capture.telegram.api_id` / `api_hash` — Telegram app credentials

## Future: iOS

All layers except hotkey/radial-picker are platform-agnostic:

- `Audio/` — `AVAudioEngine` works identically on iOS (with `AVAudioSession` setup)
- `STT/` — `URLSessionWebSocketTask` is cross-platform
- `Telegram/` — TDLib is mobile-first; Bot API (Phase 7) is plain HTTP, even simpler
- `Crypto/` — iOS has its own secure enclave; adapter pattern swaps IOKit for `DeviceCheck`
- `UI/` — replaced with UIKit/SwiftUI screens; capture trigger becomes a hold-to-record button

Out of scope for v1 per [SPEC.md](SPEC.md#5-out-of-scope-v1).
