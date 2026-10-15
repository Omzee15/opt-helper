#!/bin/zsh
# Builds OptHelper.app (menu bar only, no Dock icon) next to this script.
# Universal (Apple Silicon + Intel), hardened runtime, so the same build can be notarized.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-0.1}
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
swift build -c release --arch arm64 --arch x86_64
APP=OptHelper.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/OptHelper" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>OptHelper</string>
<key>CFBundleDisplayName</key><string>OptHelper</string>
<key>CFBundleExecutable</key><string>OptHelper</string>
<key>CFBundleIdentifier</key><string>dev.buildc3.opthelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>OptHelper opens links in a Safari profile, runs your terminal shortcuts in Terminal, and shows and controls the Spotify app, or YouTube Music and the Spotify web player in your browser.</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PL
# Hardened runtime blocks Apple Events unless this entitlement is present.
ENT=$(mktemp -t opthelper-ent).plist
cat > "$ENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PL
# Sign with a stable identity when available so macOS privacy approvals (Accessibility,
# Automation) survive rebuilds; ad-hoc signatures change on every build and lose them.
# A "Developer ID Application" identity is preferred: it's the one that can be notarized.
IDS=$(security find-identity -v -p codesigning)
ID=$(print -r -- "$IDS" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -z "$ID" ]] && ID=$(print -r -- "$IDS" | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --timestamp=none --entitlements "$ENT" --sign "${ID:--}" "$APP"
rm -f "$ENT"
echo "Built $APP (signed: ${ID:-ad-hoc}) — run: open $APP"
