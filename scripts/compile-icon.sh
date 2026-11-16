#!/bin/zsh
# Compiles the Icon Composer icon, assets/AppIcon.icon, into an app's Resources folder: Assets.car,
# which macOS 26 draws in Liquid Glass, and AppIcon.icns for macOS 14 and 15. The Info.plist names
# it with CFBundleIconName and CFBundleIconFile, both AppIcon.
#
#   scripts/compile-icon.sh <Resources folder>
set -euo pipefail
cd "$(dirname "$0")/.."
resources="$1"
work="$(mktemp -d)"

xcrun actool assets/AppIcon.icon --compile "$resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$work/partial.plist" >/dev/null

# actool's AppIcon.icns stops at 256 pixels. This one has every size up to 1024, from
# assets/icon.png, which scripts/render-icon-layers.sh renders from the same document.
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
rm -rf "$work"
