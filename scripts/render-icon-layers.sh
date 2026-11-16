#!/bin/zsh
# Renders the app icon's two layers, assets/AppIcon.icon/Assets/wheel.png and accent.png, with the
# wheel's goo shader (see IconRenderer.swift), and the flat preview assets/icon.png. Icon Composer
# adds the glass, colors, and shadows; open assets/AppIcon.icon in it to change those.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --disable-keychain
"$(swift build -c release --disable-keychain --show-bin-path)/GooeyWheel" --render-icon-layers assets/AppIcon.icon/Assets
resources="$(mktemp -d)"
scripts/compile-icon.sh "$resources" assets/icon.png
rm -rf "$resources"
