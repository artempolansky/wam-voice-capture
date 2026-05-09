#!/usr/bin/env bash
# Build VoiceMax.app and install to /Applications.
# Safe to re-run — replaces running instance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# TDLib via Homebrew. Optional — if missing, build proceeds without Telegram
# support and the tray menu shows "TDLib not installed".
if command -v brew >/dev/null 2>&1; then
  if brew list --versions tdlib >/dev/null 2>&1; then
    echo "==> tdlib already installed ($(brew --prefix tdlib))"
  else
    echo "==> Installing tdlib via Homebrew (first time — may take several minutes)..."
    brew install tdlib
  fi
else
  echo "==> brew not found — skipping tdlib install. Telegram features will be disabled."
  echo "    Install Homebrew from https://brew.sh, then re-run this script."
fi

echo "==> Building VoiceMax.app..."
bash scripts/build-app.sh

APP="${ROOT}/VoiceMax.app"
DEST="/Applications/VoiceMax.app"

if [[ ! -d "${APP}" ]]; then
  echo "Build did not produce ${APP}" >&2
  exit 1
fi

if pgrep -x VoiceMax >/dev/null 2>&1; then
  echo "==> Stopping running VoiceMax..."
  killall VoiceMax 2>/dev/null || true
  sleep 1
fi

echo "==> Installing to ${DEST}..."
rm -rf "${DEST}"
cp -R "${APP}" "${DEST}"
xattr -cr "${DEST}" 2>/dev/null || true

echo "==> Launching..."
open "${DEST}"

echo "==> VoiceMax installed and launched."
echo "    First run: grant Accessibility + Microphone in System Settings -> Privacy."
