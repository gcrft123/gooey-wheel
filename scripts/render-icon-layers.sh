#!/bin/zsh
# Renders the app icon's two layers, assets/AppIcon.icon/Assets/bubbles.png and droplet.png, with
# the wheel's goo shader (see IconRenderer.swift), then assets/icon.png: Icon Composer's rendering
# of the document on the macOS icon grid (an 824-pixel shape centered in 1024) with its shadow.
# scripts/compile-icon.sh builds the app's AppIcon.icns from that PNG. Open assets/AppIcon.icon in
# Icon Composer to change the glass or the colors, then run this again. Needs ImageMagick.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --disable-keychain
"$(swift build -c release --disable-keychain --show-bin-path)/GooeyWheel" --render-icon-layers assets/AppIcon.icon/Assets

work="$(mktemp -d)"
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" assets/AppIcon.icon --export-image --output-file "$work/shape.png" --platform macOS \
  --rendition Default --width 824 --height 824 --scale 1 >/dev/null
magick "$work/shape.png" \( +clone -background black -shadow 30x12+0+10 \) +swap \
  -background none -layers merge +repage -gravity center -extent 1024x1024 assets/icon.png
rm -rf "$work"
