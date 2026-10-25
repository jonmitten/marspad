#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/MarsPad.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MarsPad" "$APP/Contents/MacOS/MarsPad"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MarsPad</string>
<key>CFBundleIdentifier</key><string>org.marspad.app</string>
<key>CFBundleName</key><string>MarsPad</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s/dist/MarsPad.app\n' "$PWD"
