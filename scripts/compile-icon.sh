#!/bin/zsh
# Compiles the Icon Composer icon, assets/AppIcon.icon, into an app's Resources folder: Assets.car,
# which macOS 26 draws in Liquid Glass, and AppIcon.icns for macOS 14 and 15. The Info.plist names
# it with CFBundleIconName and CFBundleIconFile, both AppIcon.
#
#   scripts/compile-icon.sh <Resources folder> [<1024-pixel PNG to write>]
set -euo pipefail
cd "$(dirname "$0")/.."
resources="$1" png="${2:-}"
work="$(mktemp -d)"

xcrun actool assets/AppIcon.icon --compile "$resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$work/partial.plist" >/dev/null

# actool's AppIcon.icns stops at 256 pixels. This one has every size up to 1024: Icon Composer's
# own rendering, on the macOS icon grid (an 824-pixel shape centered in 1024) with its shadow.
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" assets/AppIcon.icon --export-image --output-file "$work/shape.png" --platform macOS \
  --rendition Default --width 824 --height 824 --scale 1 >/dev/null
magick "$work/shape.png" \( +clone -background black -shadow 30x12+0+10 \) +swap \
  -background none -layers merge +repage -gravity center -extent 1024x1024 "$work/icon.png"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
[[ -n "$png" ]] && cp "$work/icon.png" "$png"
rm -rf "$work"
