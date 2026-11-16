#!/bin/zsh
# Builds a release binary and wraps it in build/Gooey Wheel.app.
#
# GOOEY_VERSION sets the version shown to users. It defaults to the newest v* tag, without the v.
# The build number Sparkle compares is the number of commits, which only grows on main.
# GOOEY_SIGN_IDENTITY picks the signing certificate by name, such as "Developer ID Application".
# A Developer ID signature also turns on the hardened runtime and a secure timestamp, which
# notarization needs. It defaults to an Apple Development certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${GOOEY_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
version="${version:-0.1.0}"
build="$(git rev-list --count HEAD)"

# SwiftPM reads github.com credentials from the keychain before downloading Sparkle, and waits
# on the keychain's permission prompt. None are needed.
swift build -c release --disable-keychain
products="$(swift build -c release --disable-keychain --show-bin-path)"
bin="$products/GooeyWheel"

app="build/Gooey Wheel.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/GooeyWheel"
# Loaded by /usr/bin/perl to read what is playing (see NowPlaying.swift).
helper="$app/Contents/Frameworks/libGooeyNowPlaying.dylib"
cp "$products/libGooeyNowPlaying.dylib" "$helper"
# Sparkle, which the binary finds through its @executable_path/../Frameworks rpath. Its XPC
# services are only for sandboxed apps.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$products/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
# Sparkle's MIT license asks for its notice in every copy, so the app carries it. It comes in the
# same zip as the framework.
sparkle_license=(.build/artifacts/*/Sparkle/LICENSE(N))
if (( ${#sparkle_license} != 1 )); then
  echo "Expected one Sparkle LICENSE in .build/artifacts, found ${#sparkle_license}." >&2
  exit 1
fi
cp "$sparkle_license[1]" "$app/Contents/Resources/Sparkle LICENSE.txt"

# The welcome panel's video (scripts/render-welcome-video.sh makes it).
cp assets/welcome.mov "$app/Contents/Resources/welcome.mov"

scripts/compile-icon.sh "$app/Contents/Resources"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Gooey Wheel</string>
  <key>CFBundleDisplayName</key><string>Gooey Wheel</string>
  <key>CFBundleIdentifier</key><string>dev.gooey.wheel</string>
  <key>CFBundleExecutable</key><string>GooeyWheel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Gooey Wheel asks Finder to empty the Trash and to act on the files selected in it.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Gooey Wheel reads your mouse's battery level over Bluetooth, and on a Logitech mouse its buttons and haptics while Logi Options+ is running.</string>
  <key>SUFeedURL</key><string>https://github.com/gcrft123/gooey-wheel/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>coIkzO/RJ5yiBrMcI0lwCVvuURYcycZTIVTQc6euO10=</string>
</dict>
</plist>
PLIST

# Sign with a certificate when there is one. macOS ties the Input Monitoring grant (needed to read
# the mouse) to the signature, and an ad-hoc signature changes on every build. Nested code is
# signed before the code it's nested in: Sparkle's helpers, then Sparkle and the helper library,
# then the app.
wanted="${GOOEY_SIGN_IDENTITY:-Apple Development}"
identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -v want="$wanted" 'index($0, "\"" want) {print $2; exit}')"
if [[ -n "${GOOEY_SIGN_IDENTITY:-}" && -z "$identity" ]]; then
  echo "No signing certificate named \"$GOOEY_SIGN_IDENTITY\"." >&2
  exit 1
fi
flags=()
if [[ "$wanted" == "Developer ID Application"* ]]; then
  flags=(--options runtime --timestamp)
fi
sign() {
  local id="$1"
  # A keychain prompt for the certificate would otherwise wait forever.
  run() { perl -e 'alarm 60; exec @ARGV' codesign --force --sign "$id" "$@" >/dev/null 2>&1 }
  run "${flags[@]}" "$sparkle/Versions/B/Autoupdate" &&
    run "${flags[@]}" "$sparkle/Versions/B/Updater.app" &&
    run "${flags[@]}" "$sparkle" &&
    run "${flags[@]}" "$helper" &&
    run "${flags[@]}" --entitlements scripts/entitlements.plist "$app"
}
if [[ -z "$identity" ]] || ! sign "$identity"; then
  if [[ -n "${GOOEY_SIGN_IDENTITY:-}" ]]; then
    echo "Signing with \"$GOOEY_SIGN_IDENTITY\" failed." >&2
    exit 1
  fi
  flags=()
  sign -
fi
echo "$app"
