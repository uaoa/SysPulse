#!/bin/bash
# Збірка SysPulse.app.
#
# SwiftPM робить лише бінарник; macOS для menu bar-додатка потрібен бандл
# з Info.plist (без нього немає ні LSUIElement, ні автозапуску).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/SysPulse.app"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SysPulse "$APP/Contents/MacOS/SysPulse"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SysPulse</string>
  <key>CFBundleDisplayName</key><string>SysPulse</string>
  <key>CFBundleIdentifier</key><string>com.zakharii.syspulse</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>SysPulse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Лише menu bar: без іконки в Dock і без пункту в перемикачі вікон. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Підпис локальним сертифікатом: без нього macOS щоразу питатиме дозвіл,
# а SMAppService (автозапуск) взагалі не працює для непідписаного бандла.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "УВАГА: не вдалось підписати"
echo "Готово: $APP"
