# Architecture

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

API key stored in Keychain (`voicemax.deepgram.api_key`, account `deepgram`). Migrates transparently from the legacy `openclaw.deepgram.api_key` on first read.

### Telegram (`Sources/Telegram/`)

`TDLibClient.swift` — Swift wrapper around TDLib (Telegram's official C++ library). Handles:

- **Login flow** — phone number, SMS code, 2FA password
- **Forum topics** — `getForumTopics` for the configured group, filters closed topics
- **Delivery** — `sendMessage` with `message_thread_id` set to topic ID

TDLib database (encrypted SQLite) lives at `~/Library/Application Support/VoiceMax/tdlib/`. Database encryption key is generated on first login, stored in Keychain sealed to hardware UUID.

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

### UI (`Sources/UI/`)

Ported from VoiceMax Mini:

- `StatusBarController.swift` — tray icon, FN-key capture trigger, capture state management
- `RadialPickerPanel.swift` — middle-mouse radial route picker
- `RouteFavoritesPanel.swift` — per-user route favorites config
- `LoginView.swift` (new) — phone/code/password prompts on first run
- `SettingsPanel.swift` (new) — Deepgram key, group ID, mic device selection

## Data flow (recording → delivery)

```
FN press
  → StatusBarController.doStart()
  → AudioCapture.start(device: selectedMic)
      emits 20ms PCM chunks
  → DeepgramClient.send(audioData: chunk)
      receives partial transcripts (shown in tray tooltip)
FN press again
  → AudioCapture.stop()
  → DeepgramClient.disconnect()
      returns final transcript
  → TDLibClient.sendMessage(
        chatId: personalGroupID,
        threadId: selectedTopicID,
        text: finalTranscript
    )
  → Tray returns to idle
```

No HTTP server, no intermediate storage, no external state. Failure at any step leaves the tray in a recoverable state (recording flag resets, transcript buffer discarded on error).

## Configuration

Persisted in `UserDefaults.standard`:

- `VoiceMaxSelectedRoute` — last selected topic ID
- `VoiceMaxFavoriteRoutes` — pinned topics for radial picker
- `VoiceMaxRouteTitles` — custom display labels
- `VoiceMaxMicDevice` — preferred input device name
- `VoiceMaxGroupID` — Telegram group ID (default: owner's personal forum group)

Keychain:

- `voicemax.deepgram.api_key` — Deepgram API key
- `voicemax.tdlib_db_key` — TDLib DB encryption key (sealed to HW UUID)

## Future: iOS

All layers except FN-key/radial-picker are platform-agnostic:

- `Audio/` — `AVAudioEngine` works identically on iOS (with `AVAudioSession` setup)
- `STT/` — `URLSessionWebSocketTask` is cross-platform
- `Telegram/` — TDLib is mobile-first
- `Crypto/` — iOS has its own secure enclave; adapter pattern swaps IOKit for `DeviceCheck`
- `UI/` — replaced with UIKit/SwiftUI screens; capture trigger becomes a hold-to-record button

Estimated iOS port: 2–3 days once macOS version is stable.
