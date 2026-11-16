#!/bin/zsh
# Renders the App Store screenshots into build/App Store/screenshots: 2880 × 1800 opaque PNGs of the
# App Store edition's demos, captured off screen on a clear stage, scaled up and placed under a
# caption on a warm gradient with film grain.
#
# Needs ImageMagick (`magick`), Python 3 with NumPy and Pillow, and SF Pro Display in
# ~/Library/Fonts or /Library/Fonts (from developer.apple.com/fonts).
set -euo pipefail
cd "$(dirname "$0")/.."

export GOOEY_APPSTORE=1
swift build -c release --disable-keychain --build-path .build-mas
bin="$(swift build -c release --disable-keychain --build-path .build-mas --show-bin-path)/GooeyWheel"

font() {
  local file
  for file in ~/Library/Fonts/SF-Pro-Display-$1.otf /Library/Fonts/SF-Pro-Display-$1.otf; do
    [[ -f "$file" ]] && { echo "$file"; return; }
  done
  echo "SF Pro Display $1 isn't installed." >&2
  exit 1
}
bold="$(font Bold)"
regular="$(font Regular)"

out="build/App Store/screenshots"
work="$(mktemp -d)"
rm -rf "$out"
mkdir -p "$out"

python3 - "$work/background.png" <<'PY'
import sys
import numpy as np
from PIL import Image

# Computed in floating point with grain, so the glow doesn't band.
width, height = 2880, 1800
y, x = np.mgrid[0:height, 0:width].astype(np.float32)
image = np.tile(np.array([20, 18, 16], np.float32), (height, width, 1))
for cx, cy, radius, color, strength in [
    (500, 200, 1400, (200, 150, 20), 0.75),
    (2500, 1600, 1300, (120, 80, 40), 0.55),
    (2300, 300, 900, (90, 60, 20), 0.25),
]:
    distance = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / radius
    image += (np.exp(-distance * distance * 2.2) * strength)[..., None] * np.array(color, np.float32)
image += np.random.default_rng(7).normal(0, 3.0, (height, width, 1)).astype(np.float32)
Image.fromarray(np.clip(image, 0, 255).astype(np.uint8)).save(sys.argv[1])
PY

# name | demo script | moment | title | subtitle
shots=(
  "1-wheel|wheel|hover|A ring of actions under your cursor|Click a mouse button, then click or release over an action"
  "2-controls|controls|bar-open|Sliders, toggles, and pickers|Volume turns into a bar you drag or scroll"
  "3-folders|tour|folder|Folders hold more|Rest the cursor on a folder and its actions fan out"
  "4-actions|configure|accordion-open|Dozens of actions|Media, windows, apps, editing, shortcuts, and more"
  "5-customize|configure|icon-open|Make each bubble yours|Pick its action, icon, color, and name"
)
for shot in "${shots[@]}"; do
  IFS='|' read -r name script moment title subtitle <<< "$shot"
  frames="$work/$name"
  "$bin" --demo-script "$script" --stage clear --appearance dark --no-mouse \
    --demo-capture "$frames" --demo-capture-filter "^$moment\$" >/dev/null
  capture="$frames/$moment.png"
  [[ -f "$capture" ]] || { echo "No capture of $script/$moment." >&2; exit 1; }
  # Captures are at the display's 2x scale. Doubling them again keeps the goo's soft edges
  # clean, and panels larger than the space under the caption are shrunk back to fit.
  magick "$work/background.png" \
    \( "$capture" -trim +repage -filter Lanczos -resize 200% -resize '2400x1240>' \) \
    -gravity center -geometry +0+170 -composite \
    -font "$bold" -pointsize 112 -fill white -gravity north -annotate +0+150 "$title" \
    -font "$regular" -pointsize 52 -fill '#ffffffb0' -annotate +0+300 "$subtitle" \
    -alpha off "$out/$name.png"
done
rm -rf "$work"
ls "$out"
