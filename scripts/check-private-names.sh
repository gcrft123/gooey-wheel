#!/bin/zsh
# Fails when a binary names a private or disallowed interface. App Review rejects private API
# (guideline 2.5.1) and finds it by the names in the binary. The App Store edition's APPSTORE
# condition compiles that code out; this catches anything that slips back in.
#
#   scripts/check-private-names.sh <binary>
set -euo pipefail
names='PrivateFrameworks|SkyLight|SLS[A-Z]|CGS[A-Z]|CoreDock|DisplayServices|CoreBrightness|PreferencePanesSupport|MediaRemote|SACLock|SACSwitch|_AXUIElementGetWindow|IOPMCopySystemPowerSettings|KeyboardBrightnessClient|_forceQuitPanel|_restartRequested|setSwipeScrollDirection|libGooeyNowPlaying|/usr/bin/perl|osascript|/usr/bin/shortcuts|PlistBuddy|lsregister|osacompile|pmset|screencapture|Sparkle|SUFeedURL'
found="$( { strings -a "$1"; nm -u "$1"; } | grep -E "$names" | sort -u || true)"
if [[ -n "$found" ]]; then
  echo "$1 names private or disallowed interfaces:" >&2
  echo "$found" >&2
  exit 1
fi
