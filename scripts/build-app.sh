#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/WeChat Codex.app"
mkdir -p "$DIST"
STAGING="$(mktemp -d "$DIST/.wechat-codex-app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

cd "$ROOT"
swift build -c release -Xswiftc -warnings-as-errors

mkdir -p "$STAGING/WeChat Codex.app/Contents/MacOS"
mkdir -p "$STAGING/WeChat Codex.app/Contents/Resources"
cp "$ROOT/.build/release/WeChatCodexMenuBar" \
  "$STAGING/WeChat Codex.app/Contents/MacOS/WeChatCodexMenuBar"
cp "$ROOT/Resources/Info.plist" \
  "$STAGING/WeChat Codex.app/Contents/Info.plist"
codesign --force --deep --sign - "$STAGING/WeChat Codex.app" >/dev/null

if [[ -e "$APP" ]]; then
  [[ "$APP" == "$ROOT/dist/WeChat Codex.app" ]] || exit 1
  rm -rf "$APP"
fi
mv "$STAGING/WeChat Codex.app" "$APP"
echo "$APP"
