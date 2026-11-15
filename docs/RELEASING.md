# Releasing

Releases are GitHub releases on `gcrft123/gooey-wheel`. The app's updater, Sparkle, reads the feed from the latest release, so publishing a release is how users get an update.

```sh
./scripts/release.sh 1.2.0 notes.md
./scripts/release.sh 1.2.0 notes.md --dry-run
```

## What the script does

It checks that the working tree is clean, that `HEAD` is on `origin/main`, and that the version doesn't exist yet. It then builds the app signed with the Developer ID Application certificate and the hardened runtime, notarizes and staples it, and zips it as `Gooey-Wheel-1.2.0.zip`. It also copies the zip to `Gooey-Wheel.zip`, so `https://github.com/gcrft123/gooey-wheel/releases/latest/download/Gooey-Wheel.zip`, the README's Download link, always gets the latest release.

Next it downloads the previous release's `appcast.xml` and runs Sparkle's `generate_appcast` to make a new one that lists this version and the two before it. It refuses to continue if the new archive has no EdDSA signature in the appcast, which happens when the signing key doesn't match `SUPublicEDKey` in the app's Info.plist.

Finally it creates release `v1.2.0` as a draft with both zips and the appcast, then publishes it and marks it latest. Creating it as a draft first means the latest release always has an appcast. If a run fails after the draft exists, the next run stops and prints the `gh release delete` command that removes it.

`--dry-run` stops before publishing and leaves the files in `build/release/1.2.0`.

## Release notes

`notes.md` starts with the release's title as a level-one heading in the form `# v1.2.0: What changed`. Everything after the heading is the release notes. They appear on the GitHub release and, rendered as Markdown, in the app's update window.

## Versions

The version users see is the script's argument. The build number Sparkle compares is the number of commits on `HEAD`, which only increases on `main`, so releases have to be cut from `main`. The script refuses a build number that isn't higher than the latest release's.

`scripts/build-app.sh` takes the version from `GOOEY_VERSION`, or else the newest `v*` tag, and the signing certificate from `GOOEY_SIGN_IDENTITY`. Without `GOOEY_SIGN_IDENTITY` it signs with an Apple Development certificate. Releases are built for Apple silicon only.

## What you need

The release Mac needs these set up once.

The Sparkle EdDSA signing key has to be in the login keychain under the account `dev.gooey.wheel`. Sparkle's tools are in `.build/artifacts/*/Sparkle/bin` after a build. To move the key to another Mac, export it with `generate_keys --account dev.gooey.wheel -x <file>` and import it there with `generate_keys --account dev.gooey.wheel -f <file>`. A lost key can't be replaced without first shipping a build that has a new public key, so keep a backup.

A notarytool keychain profile is needed, made with `xcrun notarytool store-credentials notarytool`. `GOOEY_NOTARY_PROFILE` selects a profile with a different name. `GOOEY_SKIP_NOTARIZE=1` publishes without notarizing. Sparkle still installs a release like that, but Gatekeeper won't open a fresh download of it.

`gh` has to be signed in with write access to the repository.

## The feed

The feed URL is `https://github.com/gcrft123/gooey-wheel/releases/latest/download/appcast.xml`, set as `SUFeedURL` in the Info.plist that `scripts/build-app.sh` writes. GitHub serves release files only from a public repository, so updates stop working if the repository is made private.
