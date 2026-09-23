# Shotcue — in-app updates from GitHub Releases

Approved in chat on 2026-09-23 ("Tek tıkla kur", "Açılışta + günde bir").

## Goal
When a newer release exists on `github.com/egekibar/Shotcue`, Shotcue shows a popup with the release notes and
installs it with one click (download → verify → replace the bundle → relaunch). No Sparkle (not an allowed
dependency); nothing new outside Foundation/AppKit.

## Behaviour
- Automatic check ~10 s after launch, then whenever 24 h have passed since the last check (a `DispatchSourceTimer`
  asks every hour). Ayarlar > Genel > "Güncellemeler": "Güncellemeleri otomatik denetle" (default on), the last
  check time and a "Şimdi denetle" button. The menu bar has "Güncellemeleri denetle…".
- Popup (own window): "Shotcue X.Y.Z hazır", current version, release notes, buttons "Güncelle", "Sonra",
  "Bu sürümü atla". A skipped version is never offered automatically again; a manual check still offers it.
- "Güncelle": download the release's `.dmg` with progress, check it against the release's `<dmg>.sha256` asset,
  mount it read-only, copy the `.app` next to the installed bundle (same volume), check its bundle id and version,
  detach. Then the app quits through `TerminationController` (the "Çalışan N görev durdurulacak" confirmation
  applies; "Vazgeç" cancels the update). After this process exits a detached `/bin/sh` swaps the bundles (keeping
  the old one until the new one is in place, restoring it on failure), strips quarantine and opens the app.
- Manual check with no update: "Shotcue güncel". Automatic check failures (offline, rate limit, a release without a
  DMG) are only logged; manual ones are shown.

## Modules
- ShotcueCore: `AppVersion` (semver compare, `v` prefix), `ReleaseInfo` + `GitHubReleaseParser`, checksum parsing,
  `UpdateCheckPolicy` (due / offer rules), `UpdateError` (Turkish text), protocols `ReleaseFeed`, `UpdateInstaller`.
- ShotcueUpdater (new target, Core only): `GitHubReleaseFeed` (URLSession, `releases/latest`), `DMGUpdateInstaller`
  (download, SHA-256, hdiutil, staging, validation), `BundleSwapper` (the post-exit helper).
- ShotcueUI: `UpdateStore` (@Observable phases), `UpdateView`, settings keys and the Settings section, the menu row.
- ShotcueApp: wiring, the popup window, the hourly timer, the quit-and-swap path.
- The repo comes from Info.plist `ShotcueUpdateRepo`.

## Known limits
- The release build is not signed with a stable identity, so macOS may ask for Screen Recording again after an
  update. A stable certificate (`make cert`) fixes that.
- Out of scope: delta updates, beta channel, notarization.
