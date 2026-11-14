#!/bin/zsh
# Builds a release binary and wraps it in build/Gooey Wheel.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
products="$(swift build -c release --show-bin-path)"
bin="$products/GooeyWheel"

app="build/Gooey Wheel.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/GooeyWheel"
# Loaded by /usr/bin/perl to read what is playing (see NowPlaying.swift).
helper="$app/Contents/Frameworks/libGooeyNowPlaying.dylib"
cp "$products/libGooeyNowPlaying.dylib" "$helper"

# The welcome panel's video (scripts/render-welcome-video.sh makes it).
cp assets/welcome.mov "$app/Contents/Resources/welcome.mov"

# App icon, rendered by the app's own goo shader.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
"$bin" --render-icon assets/icon.png
for size in 16 32 128 256 512; do
  sips -z $size $size assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Gooey Wheel</string>
  <key>CFBundleDisplayName</key><string>Gooey Wheel</string>
  <key>CFBundleIdentifier</key><string>dev.gooey.wheel</string>
  <key>CFBundleExecutable</key><string>GooeyWheel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Gooey Wheel asks Finder to empty the Trash and to act on the files selected in it.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Gooey Wheel reads your mouse's battery level over Bluetooth, and on a Logitech mouse its buttons and haptics while Logi Options+ is running.</string>
</dict>
</plist>
PLIST

# Sign with a development certificate when there is one. macOS ties the Input Monitoring grant
# (needed to read the mouse) to the signature, and an ad-hoc signature changes on every build.
# The helper library is signed first, as code nested in the app.
identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
sign() {
  perl -e 'alarm 30; exec @ARGV' codesign --force --sign "$1" "$helper" >/dev/null 2>&1 &&
    perl -e 'alarm 30; exec @ARGV' codesign --force --sign "$1" "$app" >/dev/null 2>&1
}
if [[ -z "$identity" ]] || ! sign "$identity"; then
  sign -
fi
echo "$app"
