#!/bin/zsh
# Builds the Mac App Store edition of Gooey Wheel. See docs/RELEASING.md.
#
#   scripts/build-mas.sh            build/App Store/Gooey Wheel.app and Gooey-Wheel-<version>.pkg,
#                                   signed for App Store Connect
#   scripts/build-mas.sh --upload   the same, then validates the package and uploads it
#   scripts/build-mas.sh --local    build/App Store/local/Gooey Wheel.app, sandboxed and signed with
#                                   Apple Development under dev.gooey.wheel.local, to run on this Mac
#
# GOOEY_VERSION and GOOEY_BUILD set the version and build number. They default to the newest v*
# tag and the number of commits, as in build-app.sh. App Store Connect refuses a build number it
# has already received for the same version.
# GOOEY_MAS_PROFILE is the Mac App Store provisioning profile. It defaults to
# ~/.appstoreconnect/Gooey_Wheel_Mac_App_Store.provisionprofile, and is downloaded through
# scripts/asc.rb when that file is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=store
for arg in "$@"; do
  case "$arg" in
    --local) mode=local ;;
    --upload) mode=upload ;;
    *) echo "usage: build-mas.sh [--local | --upload]" >&2; exit 2 ;;
  esac
done

version="${GOOEY_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
version="${version:-0.1.0}"
build="${GOOEY_BUILD:-$(git rev-list --count HEAD)}"
bundle_id=dev.gooey.wheel
out="build/App Store"
[[ $mode == local ]] && { bundle_id=dev.gooey.wheel.local; out="build/App Store/local"; }

# The App Store edition builds in its own folder, so it doesn't replace the Developer ID build.
export GOOEY_APPSTORE=1
swift build -c release --disable-keychain --build-path .build-mas
bin="$(swift build -c release --disable-keychain --build-path .build-mas --show-bin-path)/GooeyWheel"

scripts/check-private-names.sh "$bin"

app="$out/Gooey Wheel.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/GooeyWheel"
# The welcome video shows the App Store edition's default wheel (scripts/render-welcome-video.sh).
cp assets/welcome-appstore.mov "$app/Contents/Resources/welcome.mov"
scripts/make-icns.sh "$bin" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Gooey Wheel</string>
  <key>CFBundleDisplayName</key><string>Gooey Wheel</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>GooeyWheel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Gooey Wheel reads your mouse's battery level over Bluetooth, and on a Logitech mouse its buttons and haptics while Logi Options+ is running.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# The sandbox entitlements. The mouse is read over USB (a Logi Bolt receiver) and Bluetooth, and
# files and folders the user picks for Open File and Open Folder are kept as app-scoped bookmarks.
entitlements="$(mktemp -d)/GooeyWheel.entitlements"
cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.device.usb</key><true/>
  <key>com.apple.security.device.bluetooth</key><true/>
  <key>com.apple.security.files.user-selected.read-only</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict>
</plist>
PLIST

# A keychain prompt for a certificate would otherwise wait forever.
timed() { perl -e 'alarm 120; exec @ARGV' "$@" }

if [[ $mode == local ]]; then
  timed codesign --force --sign "Apple Development" --entitlements "$entitlements" "$app" >/dev/null 2>&1
  echo "$app"
  exit 0
fi

profile="${GOOEY_MAS_PROFILE:-$HOME/.appstoreconnect/Gooey_Wheel_Mac_App_Store.provisionprofile}"
if [[ ! -f "$profile" ]]; then
  echo "Downloading the provisioning profile to $profile"
  mkdir -p "$(dirname "$profile")"
  scripts/asc.rb GET '/v1/profiles?filter[name]=Gooey%20Wheel%20Mac%20App%20Store&filter[profileState]=ACTIVE' |
    /usr/bin/python3 -c 'import base64, json, sys; open(sys.argv[1], "wb").write(base64.b64decode(json.load(sys.stdin)["data"][0]["attributes"]["profileContent"]))' "$profile"
fi
profile_plist="$(mktemp -d)/profile.plist"
security cms -D -i "$profile" > "$profile_plist"
app_id="$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw "$profile_plist")"
team="$(plutil -extract Entitlements.com\\.apple\\.developer\\.team-identifier raw "$profile_plist")"
if [[ "$app_id" != "$team.$bundle_id" ]]; then
  echo "The profile is for $app_id, not $team.$bundle_id." >&2
  exit 1
fi
cp "$profile" "$app/Contents/embedded.provisionprofile"
plutil -insert com\\.apple\\.application-identifier -string "$app_id" "$entitlements"
plutil -insert com\\.apple\\.developer\\.team-identifier -string "$team" "$entitlements"

timed codesign --force --sign "Apple Distribution" --entitlements "$entitlements" "$app"
codesign --verify --strict --verbose=2 "$app"

installer="$(security find-identity -v -p basic | grep -oE '"(3rd Party Mac Developer Installer|Mac Installer Distribution): [^"]+"' | head -1 | tr -d '"' || true)"
if [[ -z "$installer" ]]; then
  echo "No Mac Installer Distribution certificate in the keychain." >&2
  exit 1
fi
pkg="$out/Gooey-Wheel-$version.pkg"
rm -f "$pkg"
timed productbuild --component "$app" /Applications --sign "$installer" "$pkg" >/dev/null
echo "$pkg"

if [[ $mode == upload ]]; then
  # altool finds the key by its id, as AuthKey_<id>.p8 in API_PRIVATE_KEYS_DIR, so the file has to
  # keep the name App Store Connect gave it.
  if [[ -z "${GOOEY_ASC_KEY_ID:-}" && -f ~/.appstoreconnect/gooey.env ]]; then
    source ~/.appstoreconnect/gooey.env
  fi
  export API_PRIVATE_KEYS_DIR="$(dirname "$GOOEY_ASC_KEY")"
  auth=(--api-key "$GOOEY_ASC_KEY_ID" --api-issuer "$GOOEY_ASC_ISSUER_ID")
  xcrun altool --validate-app -f "$pkg" -t macos "${auth[@]}"
  xcrun altool --upload-app -f "$pkg" -t macos "${auth[@]}"
fi
