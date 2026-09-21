#!/bin/bash
# Малює SysPulse.icns з icon.swift.
#
# Окремо від build.sh: іконка змінюється рідко, а генерація тягне AppKit.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)/SysPulse.iconset"
mkdir -p "$WORK"
swift icon.swift "$WORK"
iconutil --convert icns "$WORK" --output SysPulse.icns
echo "Готово: SysPulse.icns"
