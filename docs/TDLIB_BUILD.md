# Building TDLib for macOS

TDLib is the Telegram Database Library — official C++ client used by Telegram's own desktop apps. We use it for userbot login, forum topic enumeration, and message delivery.

## Prerequisites

```bash
brew install gperf cmake openssl
```

## Clone and build

```bash
cd ~/src
git clone https://github.com/tdlib/td.git
cd td
mkdir build && cd build

cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX:PATH=../tdlib \
      -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl \
      ..
cmake --build . --target install --parallel
```

Result: `~/src/td/tdlib/` contains `include/`, `lib/libtdjson.dylib`.

## Integration in VoiceMax

Link flags in `scripts/build-app.sh`:

```bash
-I/Users/<user>/src/td/tdlib/include
-L/Users/<user>/src/td/tdlib/lib
-ltdjson
```

Copy `libtdjson.dylib` into `VoiceMax.app/Contents/Frameworks/` at build time.

## Swift bridging

TDLib exposes a single C function `td_json_client_send` / `td_json_client_receive`. Wrap it with a Swift actor that:

1. Maintains a background thread polling `td_json_client_receive`
2. Dispatches updates to subscribers (login, updates, responses)
3. Correlates requests by `@extra` IDs for request/response patterns

See `Sources/Telegram/TDLibClient.swift` (to be written).

## API credentials

Register a Telegram API app at https://my.telegram.org/apps. Get `api_id` and `api_hash`. These are not secrets per se (Telegram treats them as client identifiers), but we keep them in config:

```swift
enum TelegramAPI {
    static let apiID = <int>
    static let apiHash = "<hash>"
    static let appVersion = "VoiceMax 1.0"
}
```

## Database location

```
~/Library/Application Support/VoiceMax/tdlib/
├── db.sqlite
├── td.binlog
└── files/
```

Encrypted with the key derived from hardware UUID + Keychain entry (see `Sources/Crypto/DeviceBinding.swift`).
