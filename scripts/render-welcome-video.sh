#!/bin/zsh
# Renders the welcome panel's video, assets/welcome.mov: the tour demo on a clear stage,
# captured frame by frame off screen and encoded as HEVC with alpha, so the wheel and its
# shadow lie over the panel's yellow. Needs ffmpeg. Takes a few minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --disable-keychain
bin="$(swift build -c release --disable-keychain --show-bin-path)/GooeyWheel"
frames="$(mktemp -d)/frames"

# The script's last moment matches its first, so that frame is left out and the loop is seamless.
end="$("$bin" --demo-script tour --demo-marks | awk '$1 == "end" {print $2}')"
rate=30
"$bin" --demo-script tour --stage clear --appearance dark --accent "#FFFFFF" --no-mouse \
  --demo-capture "$frames" --demo-capture-frames "0,$end,$rate"
rm "$(ls -d "$frames"/*.png | tail -1)"

# The tour stays inside this square of the 1520 × 1280 capture, with room for shadows. The
# Media Controls picker reaches its top edge and the Controls folder its bottom edge.
ffmpeg -loglevel error -y -framerate $rate -i "$frames/%04d.png" \
  -vf "crop=960:960:264:170,scale=860:860" \
  -c:v hevc_videotoolbox -alpha_quality 0.8 -b:v 2500k -tag:v hvc1 -pix_fmt bgra \
  assets/welcome.mov
rm -rf "$(dirname "$frames")"
ls -l assets/welcome.mov
