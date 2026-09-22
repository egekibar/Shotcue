# Shotcue v1 — Spike results (Plan 00 Task 11)

- Date: 2026-09-22
- Machine: macOS 26.6.2 (25G83), Apple Silicon (arm64); Swift 6.4 (Command Line Tools 27.0); Claude Code 2.1.278
- Signing at measurement time: no "Shotcue Dev" identity yet (Task 11 Step 1 `make cert` is a user step), so
  `scripts/bundle.sh` fell back to ad-hoc signing (`codesign -dvv` → `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`).
- Run by the Plan 00 agent: Step 2 (SpikeRunner) and Step 3 (S1). Not run by the agent, by design: Step 1 (`make cert`,
  changes keychain trust) and Steps 4–6 (S3, S2, S5: they need TCC dialogs or a person watching Claude Desktop).
  Their exact commands are below so they can be run later.
- S4 (WhisperKit Turkish quality) is measured by Plan 03 Task 1, which appends its own `## S4 — WhisperKit Türkçe` section.

## S1 — `claude auth status` spawned from the app bundle: PASS

Command (Task 11 Step 3):

```bash
make install && open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=auth && sleep 5 && cat /tmp/shotcue-spike-auth.txt
```

Output (`/tmp/shotcue-spike-auth.txt`, written 2026-09-22 21:23; account identifiers redacted, no tokens were printed):

```text
spike=auth
exit=0
stdout={
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "analyticsDisabled": false,
  "projectsDirectory": "/Users/egekibar/.claude/projects",
  "configDirectory": "/Users/egekibar/.claude",
  "email": "<redacted>",
  "orgId": "<redacted>",
  "orgName": "<redacted>",
  "subscriptionType": "max"
}

stderr=
```

Decision: the architecture's core assumption holds. A `claude` child process spawned by the non-sandboxed,
hardened-runtime app bundle (with `HOME` set, `~/.local/bin` first on `PATH`, `ANTHROPIC_API_KEY` removed) sees the
claude.ai subscription login (`loggedIn: true`, `subscriptionType: max`) with no keychain error on stderr.
Plan 04 may start. (Measured with the ad-hoc signed bundle; the credential is read by the `claude` binary itself, so the
parent's signature should not matter, but the same command can be re-run after `make cert` to confirm.)

## S2 — Screen Recording permission survives a rebuild: PENDING (user step)

Not measured yet. Prerequisite: Task 11 Step 1 and S3 (the permission must first be granted to the "Shotcue Dev"-signed app).

Step 1 (once):

```bash
make cert
```

Expected: `Certificate ready: Shotcue Dev`. If `security add-trusted-cert` fails: Keychain Access → login → Certificates →
"Shotcue Dev" → Get Info → Trust → Code Signing: Always Trust, then run the command again.

S2 (Task 11 Step 5), after S3 has granted the permission:

```bash
touch Sources/ShotcueApp/ShotcueApp.swift && make install && open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=capture
# select a region, then:
cat /tmp/shotcue-spike-capture.txt
```

Expected: no new permission dialog, `exit=0`. If the dialog appears again, the signature is still ad-hoc:
`codesign -dv ~/Applications/Shotcue.app 2>&1 | grep -E "Authority|flags"` must show `Authority=Shotcue Dev`; if it
does not, repeat Step 1.

Result: pending.

## S3 — `screencapture -i -s` from the bundle, cancel and success: PENDING (user step)

Not measured yet (needs the TCC dialog and a person pressing Esc / selecting a region). Run after Step 1 (`make cert`)
and `make install`; if the app is already running, quit it first (`pkill -x Shotcue`), otherwise `open` only
activates it and the `--env` value is ignored.

Command (Task 11 Step 4):

```bash
open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=capture
# when the selection cursor appears, press Esc, then:
cat /tmp/shotcue-spike-capture.txt
```

Expected: on the first run macOS shows the Screen Recording permission dialog for Shotcue; grant it and run again.
Cancel → `exit=1` and empty `stderr`. Run once more and select a region → `exit=0` and
`/tmp/shotcue-spike-capture.png` exists (`file /tmp/shotcue-spike-capture.png` → PNG).

Result: pending.

## S5 — Does the Claude Desktop deep link attach the image?: PENDING (user step)

Not measured yet (needs a person watching Claude Desktop, and `/tmp/shotcue-spike-capture.png` from S3).

Commands (Task 11 Step 6):

```bash
open "claude://code/new?q=Test%20from%20Shotcue&folder=/tmp&file=/tmp/shotcue-spike-capture.png"
open "claude://cowork/new?q=Test%20from%20Shotcue&file=/tmp/shotcue-spike-capture.png"
```

Expected: Claude Desktop opens and the composer is pre-filled with the text; note on which route the image is actually
attached. Decision rule for Plan 04 `HandoffService.openDesktopComposer`: use `code/new` (default); use `cowork/new`
only if `code/new` does not attach the image.

Result: pending. Until it is measured, Plan 04 keeps the default `code/new`.
