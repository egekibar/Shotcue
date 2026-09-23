# Changelog

All notable changes to Shotcue are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-09-23

First public release. macOS 26 or later on Apple Silicon; the UI is in Turkish.

### Added

- Region capture with a global hotkey through macOS's own selection tool (`screencapture`); the hotkey is chosen
  from a preset list in Settings.
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
  and time; at most one run per project at a time, with a global concurrency limit.
- Scheduling: send now, at a date and time, or with the project's daily queue. Schedules fire while Shotcue is
  running; one missed during sleep or while the app was closed runs once when the Mac wakes or Shotcue starts.
- Hand-off: continue a run's session in Terminal (`claude --resume`) or in Claude Desktop, or open the task in the
  Claude Desktop composer.
- Git safety nets per project (off by default): start each run in a new `shotcue/…` branch and stash local changes
  before the run. The in-app diff shows what a run changed.
- Menu bar extra with recent tasks, queue and pause controls; a permission onboarding window and a diagnostics
  report in Settings.
- `make dmg` builds the release DMG (`dist/Shotcue-<version>.dmg`) and its SHA-256 file.

[Unreleased]: https://github.com/egekibar/Shotcue/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/egekibar/Shotcue/releases/tag/v1.0.0
