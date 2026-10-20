# Changelog

All notable changes to Shotcue are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] — 2026-10-20

### Added

- **English and Turkish.** The interface follows the system language (English for any other language); Settings →
  General → Language picks *System language*, *English* or *Türkçe* and applies it after *Restart now*, as does macOS's
  per-app language setting. Dates and times follow the locale (day-month order, 12- or 24-hour clock).
- Voice notes in any language Whisper transcribes, or *Detect automatically*; a new install transcribes in the
  interface's language, and an existing one keeps Turkish unless another language was picked.
- Agents write their summary in the interface's language.
- A status filter in the library toolbar narrows a project or the inbox to one or more statuses, in the grid and the
  list; the subtitle then reads "3 / 12 items".
- The transcription model download can be paused and resumed (Settings → Audio → *Pause*, *Resume*), also after a
  restart, from the partial files. The model or a partial download can be deleted there, and Settings shows how much
  disk it takes.
- A click on the open run in the inspector closes its log; a chevron shows which log is open.

### Changed

- The inspector's hand-off buttons say what they do: *Continue in Terminal*, *Continue in Claude* (was *Desktop'ta
  aç*), *Start Over in Claude* (was *Desktop composer'da aç*) and *Show Changes* (was *Diff'i göster*), with
  tooltips; *Continue in Claude* is hidden for Codex and Antigravity sessions, and the buttons line up in one or two
  columns as the inspector is resized.
- *Schedule…* has quick picks (*In 1 hour*, *This evening at 18:00*, *Tomorrow at 9:00*), a calendar, a typed time and
  a summary line; a time in the past cannot be scheduled.
- The diagnostics report is written in English.

### Fixed

- *Continue in Claude* opens the run's session in Claude Desktop again: Desktop 2.42304 moved the import link to
  `claude://resume?session=…` and ignored the old one.
- The schedule picker no longer breaks its label into one letter per line or shows an analog clock.
- The library's sort button shows the current order again; it was blank.
- Clicking the library grid no longer draws a focus ring around the whole pane; a click on empty space, or Esc,
  clears the selection.
- A selected card's ring no longer covers its thumbnail.

## [1.2.2] — 2026-10-06

### Fixed

- Library cards no longer stay on their placeholder instead of the screenshot. The thumbnail cache dropped images
  under memory pressure, so cards reloaded them in a loop that also kept the CPU busy; thumbnails now stay in memory
  until newer ones replace them (up to 256).

## [1.2.1] — 2026-10-06

### Fixed

- Creating a project ("Oluştur" in the project editor) no longer crashes the app as the sheet closes.

## [1.2.0] — 2026-09-24

### Added

- Codex and Antigravity next to Claude Code. Ayarlar → Ajanlar (the former Claude tab) picks the default agent and
  shows each CLI's version, path, default model and effort; a project can pick its own agent in *Proje ayarları*.
  Codex runs as `codex exec --json` with the screenshots attached, Antigravity as `agy -p --output-format
  stream-json`; both logs replay like Claude Code's, and *Terminalde devam et* resumes with `codex resume` /
  `agy --conversation`. Turn and budget limits apply to Claude Code only; the timeout and concurrency apply to all.
- A run row shows which agent ran it.
- `make notarize` builds a Developer ID-signed, notarized and stapled DMG; `make cask` points the egekibar/tap cask
  at a published release (docs/distribution.md).

## [1.1.0] — 2026-09-23

### Added

- In-app updates from GitHub Releases: a check shortly after launch and then once a day (Ayarlar → Genel →
  Güncellemeler, also "Güncellemeleri denetle…" in the menu bar). A newer release opens a window with its notes and
  "Güncelle", "Sonra", "Bu sürümü atla". "Güncelle" downloads the DMG, verifies it against the release's `.sha256`
  asset, checks the bundle id and version, then quits (the usual confirmation for running tasks) and swaps the app in
  and reopens it; the old bundle is restored if the swap fails. Releases need both `Shotcue-<version>.dmg` and
  `Shotcue-<version>.dmg.sha256` (`make dmg` writes both).
- Homebrew: `brew install --cask egekibar/tap/shotcue` (the cask clears the quarantine flag after installing).

### Changed

- The estimated run cost is no longer shown (notification, run row, log). On a subscription it is only an API-price
  estimate; it is still recorded with the run.

## [1.0.0] — 2026-09-23

First public release. macOS 26 or later on Apple Silicon; the UI is in Turkish.

### Added

- Region capture with a global hotkey through macOS's own selection tool (`screencapture`). The default is `⌃⇧2`;
  Settings records any other combination with ⌘, ⌃ or ⌥ (a function key also works alone).
- Quick panel after each capture: a typed note, voice notes, project and mode (Analyze / Implement) pickers,
  Save (`⌘↩`), Save and send (`⌘⇧↩`) and Schedule.
- On-device transcription of voice notes with WhisperKit (Turkish by default, English selectable). The model
  (~1.6 GB) is downloaded only after you confirm; until then recordings are kept and wait for it.
- Library window: one project per folder in the sidebar, an inbox for unassigned captures and status filters;
  grid and list views, sorting and search across titles, notes and transcripts; multi-select to send as one task
  or separately, move, schedule or delete; an inspector with the captures, note, transcript and audio, run history
  and the live run log.
- Headless Claude Code runs (`claude -p`) in the project folder with your Claude subscription (no API key): live
  log, result summary, turns, estimated cost and a notification when a run ends. Limits per run for turns, budget
  and time. Runs go side by side up to a global concurrency limit (2 by default, up to 20), tasks of one project
  included; a project with a git safety net runs one task at a time.
- Model pickers in Settings, the project editor and the inspector: `fable`, `opus`, `sonnet` or `haiku`, or none to
  inherit (task → project → Settings → Claude Code's default).
- Scheduling: send now, at a date and time, or with the project's daily queue. Schedules fire while Shotcue is
  running; one missed during sleep or while the app was closed runs once when the Mac wakes or Shotcue starts.
- Hand-off: continue a run's session in Terminal (`claude --resume`) or in Claude Desktop, or open the task in the
  Claude Desktop composer. Runs carry their own entrypoint tag (`shotcue`), so Claude Desktop lists them with its
  Claude Code sessions.
- Git safety nets per project (off by default): start each run in a new `shotcue/…` branch and stash local changes
  before the run.
- Code comparison screen for what a run changed: the changed files with status badges and +/− counts beside the
  selected file's diff with old and new line numbers. Untracked files show as added, with their contents; copy one
  file's patch or the whole patch.
- Menu bar extra with recent tasks, queue and pause controls; a permission onboarding window and a diagnostics
  report in Settings.
- `make dmg` builds the release DMG (`dist/Shotcue-<version>.dmg`) and its SHA-256 file.

[Unreleased]: https://github.com/egekibar/Shotcue/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/egekibar/Shotcue/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/egekibar/Shotcue/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/egekibar/Shotcue/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/egekibar/Shotcue/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/egekibar/Shotcue/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/egekibar/Shotcue/releases/tag/v1.0.0
