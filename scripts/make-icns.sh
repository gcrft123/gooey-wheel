#!/bin/zsh
# Renders the app icon with the app's own goo shader and writes it as an .icns.
#
#   scripts/make-icns.sh <GooeyWheel binary> <out.icns>
set -euo pipefail
cd "$(dirname "$0")/.."
bin="$1" out="$2"
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
"$bin" --render-icon assets/icon.png
for size in 16 32 128 256 512; do
  sips -z $size $size assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$out"
