#!/bin/sh
set -eu
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    COMMIT="$COMMIT-dirty"
fi
if [ "$#" -gt 0 ]; then
    BINARY="$1"
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
    BINARY="$BIN_DIR/MarsPad"
fi
APP="dist/MarsPad $VERSION.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/MarsPad"
cp Sources/MarsPad/Resources/BlankProject.json.gz "$APP/Contents/Resources/BlankProject.json.gz"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MarsPad</string>
<key>CFBundleIdentifier</key><string>org.marspad.app</string>
<key>CFBundleName</key><string>MarsPad</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>BuildGitCommit</key><string>$COMMIT</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s/%s (%s)\n' "$PWD" "$APP" "$COMMIT"
