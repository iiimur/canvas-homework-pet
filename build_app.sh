#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/课程作业桌宠.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/Resources/anon_head.png" "$CONTENTS/Resources/anon_head.png"
cp "$ROOT/Sources/Resources/anon_angry.webp" "$CONTENTS/Resources/anon_angry.webp"
cp "$ROOT/Sources/Resources/anon_tired.png" "$CONTENTS/Resources/anon_tired.png"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
swiftc -parse-as-library -swift-version 5 -O -target "${ARCH}-apple-macosx14.0" \
  "$ROOT/Sources/HomeworkPetApp.swift" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -o "$MACOS/HomeworkPetApp"
chmod +x "$MACOS/HomeworkPetApp"
# ad-hoc 签名，保证 UNUserNotificationCenter 在本机能正常投递通知
codesign --force --sign - "$APP"
echo "Built: $APP"
