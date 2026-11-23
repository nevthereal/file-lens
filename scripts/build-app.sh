#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make-icon.swift Assets/FileLens.iconset
iconutil -c icns Assets/FileLens.iconset -o Assets/FileLens.icns
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/File Lens.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FileLens" "$APP/Contents/MacOS/FileLens"
cp Assets/FileLens.icns "$APP/Contents/Resources/FileLens.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FileLens</string>
<key>CFBundleIdentifier</key><string>local.filelens.app</string>
<key>CFBundleName</key><string>File Lens</string>
<key>CFBundleDisplayName</key><string>File Lens</string>
<key>CFBundleIconFile</key><string>FileLens</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP"
