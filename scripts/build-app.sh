#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/WAM Voice Capture.app"
BIN_NAME="WAMVoiceCapture"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
# Min deployment target raised to 14.0 (required for AVAudioEngine voice processing AEC).
if [[ "$ARCH" == "arm64" ]]; then
  TARGET="arm64-apple-macosx14.0"
else
  TARGET="x86_64-apple-macosx14.0"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Bundle/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Optional TDLib detection. Build proceeds without Telegram if brew/tdlib missing.
# (TDLib is on the way out — Phase 7 replaces it with the simpler Telegram Bot API.
#  Until then this preserves the legacy auth/topic flow for existing users.)
TDLIB_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  TDLIB_PREFIX="$(brew --prefix tdlib 2>/dev/null || true)"
fi
TDLIB_DYLIB=""
if [[ -n "$TDLIB_PREFIX" && -d "$TDLIB_PREFIX/include/td" ]]; then
  if [[ -f "$TDLIB_PREFIX/lib/libtdjson.dylib" ]]; then
    TDLIB_DYLIB="$TDLIB_PREFIX/lib/libtdjson.dylib"
  fi
fi

SWIFTC_ARGS=(
  -target "$TARGET"
  -sdk "$SDK"
  "$ROOT/WAMVoiceCaptureMain.swift"
  "$ROOT/WAMVoiceCapture/AppDelegate.swift"
  "$ROOT/WAMVoiceCapture/ClientState.swift"
  "$ROOT/WAMVoiceCapture/FNKeyTap.swift"
  "$ROOT/WAMVoiceCapture/Migration.swift"
  "$ROOT/WAMVoiceCapture/StatusBarController.swift"
  "$ROOT/WAMVoiceCapture/TrayLog.swift"
  "$ROOT/WAMVoiceCapture/LoginItemSettings.swift"
  "$ROOT/WAMVoiceCapture/AudioCapture.swift"
  "$ROOT/WAMVoiceCapture/AudioDevices.swift"
  "$ROOT/WAMVoiceCapture/DeepgramClient.swift"
  "$ROOT/WAMVoiceCapture/KeychainHelper.swift"
  "$ROOT/WAMVoiceCapture/LocalCaptureSession.swift"
  "$ROOT/WAMVoiceCapture/MeetingSession.swift"
  "$ROOT/WAMVoiceCapture/SystemAudioCapture.swift"
  "$ROOT/WAMVoiceCapture/LightControl.swift"
  "$ROOT/WAMVoiceCapture/TelegramClient.swift"
)

if [[ -n "$TDLIB_DYLIB" ]]; then
  echo "==> Building with TDLib from $TDLIB_PREFIX"
  SWIFTC_ARGS+=(
    -D TELEGRAM_BUILD
    -import-objc-header "$ROOT/WAMVoiceCapture/TDLibBridge.h"
    -Xcc -I"$TDLIB_PREFIX/include"
    -L"$TDLIB_PREFIX/lib"
    -ltdjson
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks"
  )
else
  echo "==> Building without TDLib (Telegram features disabled)"
fi

SWIFTC_ARGS+=(
  -o "$APP/Contents/MacOS/$BIN_NAME"
  -framework AppKit
  -framework AVFoundation
  -framework CoreAudio
  -framework CoreMedia
  -framework ScreenCaptureKit
  -framework Security
  -framework UserNotifications
  -framework ServiceManagement
)

swiftc "${SWIFTC_ARGS[@]}"

# Make the bundle self-contained: copy libtdjson into Frameworks and rewrite paths
# so the installed .app doesn't depend on Homebrew at runtime.
if [[ -n "$TDLIB_DYLIB" ]]; then
  FRAMEWORKS_DIR="$APP/Contents/Frameworks"
  mkdir -p "$FRAMEWORKS_DIR"
  cp "$TDLIB_DYLIB" "$FRAMEWORKS_DIR/libtdjson.dylib"
  chmod u+w "$FRAMEWORKS_DIR/libtdjson.dylib"
  install_name_tool -id "@rpath/libtdjson.dylib" "$FRAMEWORKS_DIR/libtdjson.dylib"
  OLD_ID="$(otool -D "$TDLIB_DYLIB" | tail -1)"
  if [[ -n "$OLD_ID" && "$OLD_ID" != "@rpath/libtdjson.dylib" ]]; then
    install_name_tool -change "$OLD_ID" "@rpath/libtdjson.dylib" "$APP/Contents/MacOS/$BIN_NAME" 2>/dev/null || true
  fi
  install_name_tool -change "$TDLIB_PREFIX/lib/libtdjson.dylib" "@rpath/libtdjson.dylib" "$APP/Contents/MacOS/$BIN_NAME" 2>/dev/null || true
fi

chmod +x "$APP/Contents/MacOS/$BIN_NAME"

SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)"
if [[ -n "$SIGN_ID" ]] && command -v codesign >/dev/null 2>&1; then
  echo "Signing with: $SIGN_ID"
  codesign --force --deep -s "$SIGN_ID" "$APP" 2>/dev/null || codesign --force --deep -s - "$APP" 2>/dev/null || true
else
  codesign --force --deep -s - "$APP" 2>/dev/null || true
fi

echo "Built: $APP"
echo "If Finder says the app is damaged or won't open: run once: xattr -cr \"$APP\" && open \"$APP\""
