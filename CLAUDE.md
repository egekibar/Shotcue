# Shotcue — rules for coding agents

Native macOS app (Swift 6.4, SwiftUI, macOS 26+), built WITHOUT Xcode: only Command Line Tools + SwiftPM.
Spec: docs/superpowers/specs/2026-09-22-shotcue-design.md · Plans: docs/superpowers/plans/

## Build & test (the only loop)
- `make test` / `make test FILTER='<SuiteName>'` — Swift Testing, run before every commit. Core tests take ~6 s; keep logic in ShotcueCore.
- Always go through `make test`, never bare `swift test`: the CLT build system intermittently fails with
  `plugin for module 'TestingMacros' not found`; the Makefile loads the macro plugin explicitly. If you still see it, run again.
- `make build` / `make run` (bundle → ~/Applications → open) / `make shot` (screenshot app windows to /tmp/shotcue-shots).
- Never use `xcodebuild`, `actool`, `.xcassets`, Xcode projects, or `#Preview` (CLT has no PreviewsMacros; it breaks the build).
- Same failure class: FoundationModels `@Generable` / `@Guide` macros (CLT has no FoundationModelsMacros). Non-macro FoundationModels APIs compile.
- Same failure class: SwiftUI `@State` (macOS 27 SDK declares it as a macro; CLT has no SwiftUIMacros). Use `@UIState`
  (`public typealias UIState<Value> = SwiftUI.State<Value>` in ShotcueUI). `@FocusState`, `@Binding`, `@Environment`,
  `@Bindable`, `@AppStorage`, `@Observable` are fine.
- `swift-format` is not on PATH; always call it as `xcrun swift-format` (the Makefile does).
- Never add a dependency without first compiling it in a scratch package with `swift build`; deps that use `#Preview` cannot be used.
- Only allowed dependencies: GRDB.swift 7.11.x, argmax-oss-swift 1.1.x (WhisperKit).

## Module boundaries
- ShotcueCore: Foundation only. Models, protocols, pure rules. Every service is a protocol here; tests use fakes.
- ShotcuePersistence (GRDB), ShotcueCapture (screencapture/hotkey/permissions), ShotcueNotes (audio/WhisperKit),
  ShotcueClaudeBridge (Process runner/scheduler/git), ShotcueUI (SwiftUI + @Observable stores), ShotcueApp (composition root).
- UI never imports service modules; it depends on Core protocols only. App wires everything in AppEnvironment.
- Do not edit Package.swift unless the task says so. Do not touch files owned by another plan/task.

## Forbidden APIs / patterns
- CGWindowListCreateImage, CGDisplayCreateImage (obsoleted) — use ScreenCaptureKit or /usr/sbin/screencapture.
- SFSpeechRecognizer; SpeechTranscriber.supportedLocale(equivalentTo:) (lies about Turkish); AVAudioSession (iOS only).
- NSApp.activate(ignoringOtherApps:) inside the quick panel (kills non-activating behavior).
- Foundation Timer for scheduling (use DispatchSourceTimer); `claude --bare` (drops subscription auth); ad-hoc codesign (`--sign -`).
- Naming: the task model is `ShotTask` (never `Task`). Code, identifiers, commits in English; UI strings in Turkish.

## Workflow
- TDD: failing test → minimal code → green → commit. Swift Testing (`#expect`, `#require`), no XCTest.
- `swift-format` config in `.swift-format`; run `make format` before committing.
- No Claude attribution anywhere: no `Co-Authored-By: Claude …` trailer in commits, no "Generated with Claude Code" line in PRs.
  Claude must never show up as a GitHub contributor (`.claude/settings.json` sets `attribution` to empty).
