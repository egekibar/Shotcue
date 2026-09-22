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

## S4 — WhisperKit Türkçe kalite/hız (Plan 03 Task 1): PENDING (user step)

Not measured yet. The Plan 03 agent wrote the spike CLI exactly as Plan 03 Task 1 Steps 2–3 give it, in its session
scratchpad (outside the repo), and compiled it: `swift build` → `Build complete!` (2026-09-22, 230 s, Apple M2 16 GB,
macOS 26.6.2, Swift 6.4 / Command Line Tools 27.0, WhisperKit 1.1.0); it compiled again with the required `modelFolder`
fix described in Step 2. By controller ruling it did not download any model (~1.6 GB + ~632 MB need the user's
explicit permission) and recorded no audio: the samples must be the user's own voice, because synthetic `say` audio
skews this measurement (research 03). Until S4 is measured, the default model stays
`openai_whisper-large-v3-v20240930_turbo` (spec §6.2); see "KARAR" at the end of this section, which Plan 03 Task 5
reads.

Step 1 (user) — record the samples. QuickTime Player → Dosya → Yeni Ses Kaydı (or Voice Memos): 5 separate
recordings, 20–30 s each, normal speaking pace, at your own desk (realistic background noise), each with at least
3 English technical terms inside Turkish sentences. Example topics (Plan 03 Task 1 Step 1):

1. "Login ekranındaki **modal** açıldığında **API endpoint**'ten gelen hata mesajı görünmüyor, önce **cache**'i
   temizleyip tekrar **deploy** etmeyi dene."
2. "Dashboard'daki **dropdown** **mobile** görünümde bozuluyor, **responsive** düzeltme lazım ve **state** yönetimini
   **refactor** etmemiz gerekiyor."
3. "**Migration** dosyasında **foreign key** eksik, **rollback** edip yeniden yaz; sonra **queue worker**'ı
   **restart** et."
4. "Ödeme sayfasındaki **webhook** **timeout** veriyor, **retry** mantığını **exponential backoff** ile değiştir."
5. A real task of your own; anything, as long as it contains English technical terms.

Save them as `~/Desktop/shotcue-s4/note1.m4a` … `note5.m4a` (`.wav` also works) and write what each recording really
says, one line per note, to `~/Desktop/shotcue-s4/ground-truth.txt`. With fewer than 5 recordings, still measure,
and record how many notes were used.

Step 2 — build the spike CLI outside the repo (the agent's scratchpad copy is temporary). `SCRATCH` is any directory
outside the repo with at least ~3 GB free for the two models (this Mac had 12 GiB free on 2026-09-22):

```bash
export SCRATCH=~/shotcue-s4-spike
mkdir -p "$SCRATCH/spike-s4/Sources/SpikeCLI"
# Create $SCRATCH/spike-s4/Package.swift and $SCRATCH/spike-s4/Sources/SpikeCLI/main.swift with the exact contents
# given in docs/superpowers/plans/2026-09-22-shotcue-03-notes.md, Task 1 Steps 2–3, plus the one-line fix below.
cd "$SCRATCH/spike-s4" && swift build 2>&1 | tail -3
```

Required fix in the plan's `main.swift`: add the `modelFolder:` line to the `WhisperKitConfig(...)` call:

```swift
    let config = WhisperKitConfig(model: variant, downloadBase: modelsDirectory, modelRepo: repo,
                                  modelFolder: modelFolder(variant).path,
                                  verbose: false, logLevel: .error, prewarm: false, load: true,
                                  download: false)
```

Without it, WhisperKit 1.1.0's `setupModels` never sets a model folder when `download: false`, so every load fails with
`WhisperError.modelsUnavailable("Model folder is not set.")`, right after the downloads. Reproduced offline on 2026-09-22
by running the plan's CLI against empty model folders (no download); with the fix the same run fails with
`Model file not found at …/openai_whisper-large-v3-v20240930_turbo/…`, i.e. it now reads the right folder. Plan 03's
`WhisperKitEngine.load()` carries the same fix.

Expected: `Build complete!` (the first build resolves and compiles WhisperKit: 230 s on this Mac while another build
was running; `ld: warning: search path … not found` warnings are harmless).

Step 3 (user permission: downloads ~1.6 GB + ~632 MB into `$SCRATCH/s4-models` on the first run) — measure both
models:

```bash
cd "$SCRATCH/spike-s4" && ./.build/debug/SpikeCLI "$SCRATCH/s4-models" ~/Desktop/shotcue-s4/note*.m4a 2>&1 | tee "$SCRATCH/s4-output.txt"
```

Expected: `device default` / `supported: true` lines for both variants, download percentages, `load … s`, and for
each note `audio … s · transcribe … s · …x realtime` followed by the transcript and its segment lines. On a
`modelsUnavailable` error, compare the model name with the `supported` output.

Step 4 — fill in the tables below from `$SCRATCH/s4-output.txt` and `ground-truth.txt` with real measurements (no
empty cells; write "ölçülemedi: <sebep>" for anything that could not be measured), replace "PENDING (user step)" in
this heading with the outcome, and apply the decision rule: if the 632MB variant is as good as turbo on the technical
terms and passes the speed criterion (a 30 s note in < 5 s), make it the default (saves ~1 GB of disk); otherwise the
default stays `openai_whisper-large-v3-v20240930_turbo`. If both models mangle the technical terms, stop: spec §6.2's
single-engine decision must be revisited before relying on voice notes (research 03 §5's AssemblyAI fallback could
move into v1). If the default changes, update the default model name that Plan 03 Task 5 put in `ShotcueNotes`.

Results (to fill after Step 3):

Tarih: <YYYY-MM-DD> · Makine: <chip>, macOS <sürüm> · Kayıtlar: `~/Desktop/shotcue-s4/note1..5`
Ground truth: `~/Desktop/shotcue-s4/ground-truth.txt`

| Model | Disk | Yükleme | 5 notun toplam süresi | Toplam transkripsiyon | Ortalama hız |
|---|---|---|---|---|---|
| `openai_whisper-large-v3-v20240930_turbo` | | | | | x realtime |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | | | | | x realtime |

### Teknik terim doğruluğu (ground truth'a göre)

| Terim | turbo | turbo_632MB |
|---|---|---|
| modal | | |
| API endpoint | | |
| cache | | |
| deploy | | |
| dropdown | | |
| responsive | | |
| state | | |
| refactor | | |
| migration / foreign key / rollback | | |
| webhook / timeout / retry | | |

Her not için tam transkriptler: `$SCRATCH/s4-output.txt` (özeti aşağıda)

1. note1: turbo → "…" · 632MB → "…"
2. note2: …
3. note3: …
4. note4: …
5. note5: …

### Başarı ölçütü kontrolü (spec §12)

- Teknik terimler korunuyor mu? turbo: <evet/kısmen/hayır> · 632MB: <evet/kısmen/hayır>
- 30 sn not < 5 sn mi? turbo: <ölçüm> · 632MB: <ölçüm>

### KARAR

Varsayılan model: `openai_whisper-large-v3-v20240930_turbo`
Gerekçe: S4 henüz ölçülmedi (kullanıcı adımı); ölçülene kadar spec §6.2'nin varsayılanı geçerli.
