#!/bin/bash
# Assembles build/Expenses.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Expenses.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ExpensesApp "$APP/Contents/MacOS/ExpensesApp"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Expenses</string>
    <key>CFBundleDisplayName</key><string>Expenses</string>
    <key>CFBundleIdentifier</key><string>com.local.expenses</string>
    <key>CFBundleExecutable</key><string>ExpensesApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key><string>Wallet listens only after you tap the mic, to turn your voice into a question or command. Audio is transcribed on this Mac by a local Whisper model and never leaves it.</string>
</dict>
</plist>
PLIST
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
