# Changelog

All notable changes to Shotcue are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- In-app updates from GitHub Releases: a check shortly after launch and then once a day (Ayarlar → Genel →
  Güncellemeler, also "Güncellemeleri denetle…" in the menu bar). A newer release opens a window with its notes and
  "Güncelle", "Sonra", "Bu sürümü atla". "Güncelle" downloads the DMG, verifies it against the release's `.sha256`
  asset, checks the bundle id and version, then quits (the usual confirmation for running tasks) and swaps the app in
  and reopens it; the old bundle is restored if the swap fails. Releases need both `Shotcue-<version>.dmg` and
  `Shotcue-<version>.dmg.sha256` (`make dmg` writes both).

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

[Unreleased]: https://github.com/egekibar/Shotcue/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/egekibar/Shotcue/releases/tag/v1.0.0
