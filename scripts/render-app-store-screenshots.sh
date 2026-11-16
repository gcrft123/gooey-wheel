#!/bin/zsh
# Renders the App Store screenshots into build/App Store/screenshots: 2880 × 1800 opaque PNGs of the
# App Store edition's demos, captured off screen on a clear stage, scaled up and placed under a
# caption on assets/app-store-background.png.
#
# Needs ImageMagick (`magick`) and SF Pro Display in
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

# The background, assets/app-store-background.png, is scaled to cover the screenshot and cropped
# to its center.
magick assets/app-store-background.png -alpha off -filter Lanczos -resize '2880x1800^' \
  -gravity center -extent 2880x1800 "$work/background.png"

# name | demo script | moments, side by side | title | subtitle
shots=(
  "1-wheel|wheel|hover|A ring of actions under your cursor|Click a mouse button, then click or release over an action"
  "2-controls|controls|bar-open|Sliders, toggles, and pickers|Control values like volume right from the wheel"
  "3-folders|tour|folder|Folders hold more|Rest the cursor on a folder and its actions fan out"
  "4-actions|configure|accordion-open|Dozens of actions|Media, windows, apps, editing, shortcuts, and more"
  "5-customize|configure|icon-open color-open|Make each bubble yours|Pick its action, icon, color, and name"
)
for shot in "${shots[@]}"; do
  IFS='|' read -r name script moments title subtitle <<< "$shot"
  frames="$work/$name"
  pieces=()
  for moment in ${=moments}; do
    # White highlights, as in the welcome video, since the accent yellow would vanish into the
    # background.
    "$bin" --demo-script "$script" --stage clear --appearance dark --accent "#FFFFFF" --no-mouse \
      --demo-capture "$frames" --demo-capture-filter "^$moment\$" >/dev/null
    capture="$frames/$moment.png"
    [[ -f "$capture" ]] || { echo "No capture of $script/$moment." >&2; exit 1; }
    pieces+=("$capture")
  done
  # Captures are at the display's 2x scale. Doubling them again keeps the goo's soft edges
  # clean, and content larger than the space under the caption is shrunk back to fit. Several
  # moments sit side by side, 120 pixels apart before scaling.
  magick "$work/background.png" \
    \( -background none "${pieces[@]}" -trim +repage -bordercolor none -border 60x0 \
       -gravity center +append -trim +repage -filter Lanczos -resize 200% -resize '2400x1240>' \) \
    -gravity center -geometry +0+170 -composite \
    -font "$bold" -pointsize 112 -fill '#2b1d04' -gravity north -annotate +0+150 "$title" \
    -font "$regular" -pointsize 52 -fill '#2b1d04c8' -annotate +0+300 "$subtitle" \
    -alpha off "$out/$name.png"
done
rm -rf "$work"
ls "$out"
