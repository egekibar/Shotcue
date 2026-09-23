# Distribution

Shotcue ships as a DMG on [GitHub Releases](https://github.com/egekibar/Shotcue/releases) and as a Homebrew cask in
the [egekibar/tap](https://github.com/egekibar/homebrew-tap) tap (`brew install --cask egekibar/tap/shotcue`). The
in-app updater reads the same releases, so every release needs both `Shotcue-<version>.dmg` and its `.dmg.sha256`.

## Cutting a release

1. Set `CFBundleShortVersionString` (and bump `CFBundleVersion`) in `Resources/Info.plist`, update `CHANGELOG.md`
   and write `docs/releases/v<version>.md`.
2. Build the DMG:
   - with a Developer ID (see below): `make notarize SIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)'`
   - without one: `make dmg` (ad-hoc signed, not notarized)
3. Tag and publish:
   `gh release create v<version> dist/Shotcue-<version>.dmg dist/Shotcue-<version>.dmg.sha256 --notes-file docs/releases/v<version>.md`
4. `make cask` points the tap's cask at the new release (version + the release's SHA-256) and pushes it.

## Developer ID and notarization (one-time setup)

Needed to drop the Gatekeeper prompt, to keep Screen Recording / Microphone permissions across updates, and for the
official Homebrew repository. These steps need your Apple account, so they are yours to do:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/) as an individual ($99/year).
2. Create the certificate without Xcode: Keychain Access → Certificate Assistant → *Request a Certificate From a
   Certificate Authority…* (your email, "Saved to disk"), then at
   [Certificates](https://developer.apple.com/account/resources/certificates/add) choose **Developer ID Application**,
   upload the request, download the `.cer` and double-click it. Check it with
   `security find-identity -v -p codesigning`; the quoted name is the `SIGN_IDENTITY` to use.
3. Create an app-specific password at [account.apple.com](https://account.apple.com) → Sign-In and Security, then
   store the notarization credentials in the keychain (it asks for that password):
   `xcrun notarytool store-credentials shotcue-notary --apple-id <email> --team-id <TEAMID>`

After that, `make notarize SIGN_IDENTITY='…'` builds a Developer ID-signed app with a secure timestamp (the hardened
runtime and `Resources/Shotcue.entitlements` are already used), signs the DMG, submits it to Apple, staples the ticket
and rewrites the `.sha256`. `NOTARY_PROFILE` overrides the profile name.

The first Developer ID release changes the app's signature, so users grant Screen Recording and Microphone once more;
later updates keep them. The updater does not pin the signature, so it installs that release like any other.

## Official Homebrew cask (`brew install --cask shotcue`)

`homebrew/cask` accepts Shotcue once both hold (checked by `brew audit --new`):

- **Signed and notarized**: `brew audit --signing` runs `codesign --check-notarization` on the app.
- **Notable**: a cask submitted by the project's own author needs at least one of 225 stars, 90 forks or
  90 watchers (a third party needs 75 / 30 / 30), and the repository must be at least 30 days old
  (2026-10-23 for egekibar/Shotcue).

Then:

1. Fork [Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask) and add `Casks/s/shotcue.rb`: the tap's
   cask **without** the `postflight_steps` block (a notarized app needs no quarantine removal, and the official repo
   does not allow it).
2. `brew tap --force homebrew/cask`, copy the file there and run
   `brew audit --cask --new --online --signing shotcue`, `brew style --cask shotcue` and
   `brew install --cask shotcue`.
3. Open the pull request and fill in its checklist.

Once it is merged, point the README at `brew install --cask shotcue` and leave a note in the tap (or delete its cask)
so the two do not diverge.
