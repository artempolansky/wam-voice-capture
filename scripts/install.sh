#!/usr/bin/env bash
# Build "WAM Voice Capture.app" and install to /Applications.
# Safe to re-run — replaces running instance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="WAM Voice Capture"
APP_BUNDLE="${APP_NAME}.app"
BIN_NAME="WAMVoiceCapture"

echo "==> Building ${APP_BUNDLE}..."
bash scripts/build-app.sh

APP="${ROOT}/${APP_BUNDLE}"
DEST="/Applications/${APP_BUNDLE}"

if [[ ! -d "${APP}" ]]; then
  echo "Build did not produce ${APP}" >&2
  exit 1
fi

# Stop any running instance — match new and legacy binary names.
for proc in "$BIN_NAME" "VoiceMax"; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    echo "==> Stopping running ${proc}..."
    killall "$proc" 2>/dev/null || true
    sleep 1
  fi
done

# If a legacy VoiceMax.app sits in /Applications/, leave it alone — uninstall
# is the user's call. We only manage our own bundle.
echo "==> Installing to ${DEST}..."
rm -rf "${DEST}"
cp -R "${APP}" "${DEST}"
xattr -cr "${DEST}" 2>/dev/null || true

echo "==> Launching..."
open "${DEST}"

echo "==> ${APP_NAME} installed and launched."
echo "    First run: grant Accessibility + Microphone in System Settings → Privacy."
echo "    For meeting recording: also grant Screen Recording."
echo "    For calendar features: also grant Calendar access."
