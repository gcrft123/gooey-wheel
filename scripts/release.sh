#!/bin/zsh
# Publishes a GitHub release that Gooey Wheel's updater offers. It builds the app signed with
# Developer ID, notarizes it, and uploads it to a new release with a Sparkle appcast listing it.
#
#   scripts/release.sh <version> <notes.md> [--dry-run]
#
# The notes file starts with the release's title as a heading, "# v1.2.0: What changed", and the
# rest is the release notes, shown on the GitHub release and in the app's update window.
# --dry-run stops before publishing, with everything it would upload in build/release/<version>.
#
# It needs the Developer ID Application certificate, the Sparkle signing key in the login
# keychain under the account dev.gooey.wheel, and gh signed in to GitHub. Notarization uses the
# notarytool keychain profile named by GOOEY_NOTARY_PROFILE, "notarytool" by default, made with
# `xcrun notarytool store-credentials notarytool`. GOOEY_SKIP_NOTARIZE=1 publishes without it.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=gcrft123/gooey-wheel
key_account=dev.gooey.wheel
app="build/Gooey Wheel.app"

fail() { echo "$1" >&2; exit 1 }
usage() { fail "usage: scripts/release.sh <version> <notes.md> [--dry-run]" }

(( $# == 2 || $# == 3 )) || usage
version=$1 notes=$2 dry_run=${3:-}
[[ -z $dry_run || $dry_run == --dry-run ]] || usage
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "The version must look like 1.2.0."
[[ -f $notes ]] || fail "There's no notes file at $notes."
tag=v$version
title=$(head -1 "$notes" | sed -E 's/^# +//')
[[ $title == "$tag: "* ]] || fail "The notes must start with a heading \"# $tag: <description>\"."

if [[ -z $dry_run ]]; then
  [[ -z $(git status --porcelain) ]] || fail "Commit or set aside the changes in the working tree first."
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main || fail "HEAD isn't on origin/main. Merge and push it first."
  if draft=$(gh release view $tag --repo $repo --json isDraft --jq .isDraft 2>/dev/null); then
    [[ $draft == true ]] && fail "$tag is a draft left by a run that didn't finish. Remove it with gh release delete $tag --repo $repo --cleanup-tag, then run this again."
    fail "$tag is already released."
  fi
fi

# The latest release, whose appcast the new one extends. Empty before the first release.
latest=$(gh release list --repo $repo --limit 1 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[].tagName') ||
  fail "Couldn't list the releases of $repo."

out=build/release/$version
feed=$out/feed
rm -rf $out
mkdir -p $feed

# Sparkle offers a version only when its build number, the commit count, is higher.
build=$(git rev-list --count HEAD)
if [[ -n $latest ]]; then
  gh release download $latest --repo $repo --pattern appcast.xml --dir $feed
  newest=$(grep -o '<sparkle:version>[0-9]*' $feed/appcast.xml | grep -o '[0-9]*$' | sort -n | tail -1) ||
    fail "The appcast of $latest lists no versions."
  (( build > newest )) || fail "Build $build isn't newer than build $newest in $latest."
fi

GOOEY_VERSION=$version GOOEY_SIGN_IDENTITY="Developer ID Application" ./scripts/build-app.sh

profile=${GOOEY_NOTARY_PROFILE:-notarytool}
if [[ ${GOOEY_SKIP_NOTARIZE:-} == 1 ]]; then
  echo "Skipping notarization. Gatekeeper will refuse to open a fresh download of this release."
elif xcrun notarytool history --keychain-profile $profile >/dev/null 2>&1; then
  echo "Notarizing, which takes a few minutes"
  ditto -c -k --keepParent "$app" $out/notarize.zip
  result=$(xcrun notarytool submit $out/notarize.zip --keychain-profile $profile --wait --output-format json)
  rm $out/notarize.zip
  verdict=$(plutil -extract status raw -o - - <<<"$result")
  if [[ $verdict != Accepted ]]; then
    id=$(plutil -extract id raw -o - - <<<"$result")
    fail "Notarization ended as $verdict. See xcrun notarytool log $id --keychain-profile $profile"
  fi
  xcrun stapler staple -q "$app"
else
  fail "There's no notarytool profile named $profile. Make one with xcrun notarytool store-credentials $profile, or set GOOEY_SKIP_NOTARIZE=1."
fi

archive=$feed/Gooey-Wheel-$version.zip
ditto -c -k --sequesterRsrc --keepParent "$app" $archive
# The same zip under a name that doesn't change, so releases/latest/download/Gooey-Wheel.zip
# always downloads the latest release. It stays out of the feed folder, or the appcast would
# list it.
download=$out/Gooey-Wheel.zip
cp $archive $download
# generate_appcast embeds the notes file named like the archive. The title stays out of it.
tail -n +2 "$notes" | sed '/./,$!d' > $feed/Gooey-Wheel-$version.md

sparkle=(.build/artifacts/*/Sparkle/bin(N))
(( $#sparkle )) || fail "Sparkle's tools aren't in .build/artifacts."
# generate_keys made the key, so the keychain gives it to generate_keys without asking. Any other
# tool waits on a permission prompt, so the key goes through a file that only exists meanwhile.
keydir=$(mktemp -d)
trap 'rm -rf $keydir' EXIT
$sparkle[1]/generate_keys --account $key_account -x $keydir/key >/dev/null
$sparkle[1]/generate_appcast \
  --ed-key-file $keydir/key \
  --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
  --link "https://github.com/$repo/releases" \
  --embed-release-notes \
  --maximum-deltas 0 \
  $feed
# generate_appcast leaves the signature out, and still succeeds, when the key doesn't match
# SUPublicEDKey in the app.
grep -q "Gooey-Wheel-$version.zip\".*sparkle:edSignature=" $feed/appcast.xml ||
  fail "The appcast has no EdDSA signature for $version. Check that the key under $key_account matches SUPublicEDKey."

if [[ -n $dry_run ]]; then
  echo "Dry run. Would publish $tag ($title) with:"
  ls -1 $archive $download $feed/appcast.xml
  exit 0
fi

# Published as a draft first, so the latest release always has its appcast.
gh release create $tag --repo $repo --target "$(git rev-parse HEAD)" --draft \
  --title "$title" --notes-file $feed/Gooey-Wheel-$version.md $archive $download $feed/appcast.xml
gh release edit $tag --repo $repo --draft=false --latest
gh release view $tag --repo $repo --json url --jq .url
