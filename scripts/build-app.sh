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

# TDLib was retired in favor of file-sync (Phase 7a / AgentSyncTarget). The
# ~30 MB libtdjson.dylib, the Bridging header, and the Homebrew dependency
# are all gone. Pure-Swift build now.

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
  "$ROOT/WAMVoiceCapture/SpeakerLabels.swift"
  "$ROOT/WAMVoiceCapture/RecordingsFolder.swift"
  "$ROOT/WAMVoiceCapture/AgentSyncTarget.swift"
  "$ROOT/WAMVoiceCapture/AgentSyncRegistry.swift"
  "$ROOT/WAMVoiceCapture/SystemAudioCapture.swift"
  "$ROOT/WAMVoiceCapture/LightControl.swift"
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
