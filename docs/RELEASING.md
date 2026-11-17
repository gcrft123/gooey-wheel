# Releasing

Releases are GitHub releases on `gcrft123/gooey-wheel`. The app's updater, Sparkle, reads the feed from the latest release, so publishing a release is how users get an update.

```sh
./scripts/release.sh 1.2.0 notes.md
./scripts/release.sh 1.2.0 notes.md --dry-run
```

## What the script does

It checks that the working tree is clean, that `HEAD` is on `origin/main`, and that the version doesn't exist yet. It then builds the app signed with the Developer ID Application certificate and the hardened runtime, notarizes and staples it, and zips it as `Gooey-Wheel-1.2.0.zip`.

Next it downloads the previous release's `appcast.xml` and runs Sparkle's `generate_appcast` to make a new one that lists this version and the two before it. It refuses to continue if the new archive has no EdDSA signature in the appcast, which happens when the signing key doesn't match `SUPublicEDKey` in the app's Info.plist.

Finally it creates release `v1.2.0` as a draft with the zip and the appcast, then publishes it and marks it latest. Creating it as a draft first means the latest release always has an appcast. If a run fails after the draft exists, the next run stops and prints the `gh release delete` command that removes it. The README's Download link points to `https://github.com/gcrft123/gooey-wheel/releases/latest`, which redirects to the newest release.

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

## The Mac App Store edition

The App Store edition is built from the same source with the `APPSTORE` condition (see [ARCHITECTURE.md](ARCHITECTURE.md)). It runs in the App Sandbox, has no Sparkle, and leaves out the actions the sandbox blocks or that need private interfaces. Its listing text is in [APP_STORE.md](APP_STORE.md).

```sh
./scripts/build-mas.sh            # build/App Store/Gooey-Wheel-1.2.0.pkg
./scripts/build-mas.sh --upload   # the same, then validates and uploads it
./scripts/build-mas.sh --local    # a sandboxed copy to run on this Mac
```

The script builds into `.build-mas`, so it doesn't replace the Developer ID build. It refuses to continue if the binary contains the name of a private framework or function, since App Review rejects those. It then signs the app with the Apple Distribution certificate, the Mac App Store provisioning profile, and the sandbox entitlements, and wraps it in an installer package signed with the Mac Installer Distribution certificate. `--upload` validates the package and uploads it with `xcrun altool`. The build then appears in App Store Connect after processing, usually within an hour, ready to add to a version and submit for review.

`--local` signs with the Apple Development certificate under the bundle id `dev.gooey.wheel.local` instead, with the same sandbox entitlements and no profile. A distribution-signed app only runs once the App Store installs it, so this copy is how to check the sandboxed app on this Mac. It has its own container and its own Accessibility and Input Monitoring grants.

The version and build number follow the same rules as the Developer ID build. App Store Connect refuses a build number it already has for that version, so set `GOOEY_BUILD` to upload again from the same commit.

### What you need

- The Apple Distribution and Mac Installer Distribution certificates, with their private keys, in the login keychain.
- The provisioning profile "Gooey Wheel Mac App Store" (type Mac App Store, App ID `dev.gooey.wheel`). The script reads it from `~/.appstoreconnect/Gooey_Wheel_Mac_App_Store.provisionprofile`, or `GOOEY_MAS_PROFILE`, and downloads it there when it's missing. It expires with the Apple Distribution certificate.
- An App Store Connect API key: a Team key with Admin access. `scripts/asc.rb` and `--upload` read `GOOEY_ASC_KEY_ID`, `GOOEY_ASC_ISSUER_ID`, and `GOOEY_ASC_KEY` (the `.p8` path) from the environment or from `~/.appstoreconnect/gooey.env`.

`scripts/asc.rb` calls the App Store Connect API with that key and prints the JSON response, for example `scripts/asc.rb GET /v1/certificates`. It created the certificates and the profile. When the certificates expire, make new ones the same way: create a key and a certificate signing request with `openssl`, send it to `POST /v1/certificates` with the type `DISTRIBUTION` or `MAC_INSTALLER_DISTRIBUTION`, import the certificate and key into the login keychain, then create a new profile with `POST /v1/profiles`.
