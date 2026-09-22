# Shotcue v1 — Plan dizini ve yürütme haritası

Spec: `../specs/2026-09-22-shotcue-design.md` · Araştırma: `../../research/01…05`

## Planlar

| Plan | Dosya | Modül / sahiplik | Bağımlılık |
|---|---|---|---|
| 00 | `2026-09-22-shotcue-00-foundation.md` | `Package.swift`, `Makefile`, `scripts/`, `Resources/`, `CLAUDE.md`, `Sources/ShotcueCore`, `Sources/ShotcueTestSupport`, `Tests/Fixtures`, `Tests/ShotcueCoreTests` | — |
| 01 | `2026-09-22-shotcue-01-persistence.md` | `Sources/ShotcuePersistence`, `Tests/ShotcuePersistenceTests` | 00 |
| 02 | `2026-09-22-shotcue-02-capture.md` | `Sources/ShotcueCapture`, `Tests/ShotcueCaptureTests` | 00 |
| 03 | `2026-09-22-shotcue-03-notes.md` | `Sources/ShotcueNotes`, `Tests/ShotcueNotesTests` | 00 |
| 04 | `2026-09-22-shotcue-04-claude-bridge.md` | `Sources/ShotcueClaudeBridge`, `Tests/ShotcueClaudeBridgeTests` | 00 |
| 05 | `2026-09-22-shotcue-05-ui.md` | `Sources/ShotcueUI`, `Tests/ShotcueUITests` | 00 |
| 06 | `2026-09-22-shotcue-06-app.md` | `Sources/ShotcueApp`, `Resources/AppIcon.icns`, `scripts/make-icon.sh` | 01–05 |

Sözleşme: modüller arası tek bağ `ShotcueCore` protokolleridir (Plan 00 Task 10). Somut tip adları ve init imzaları her planın "Naming contract" bölümünde sabittir; bir plan başka planın dosyasına dokunmaz, `Package.swift` yalnızca Plan 00'da yazılır.

## Yürütme sırası

```
Plan 00 (tek ajan, sıralı; Task 11 spike'ları kullanıcıyla)
   │
   ├── Plan 01 ─┐
   ├── Plan 02 ─┤  aynı anda 5 ajan, her biri kendi git worktree'sinde
   ├── Plan 03 ─┤  (superpowers:using-git-worktrees), TDD, her task sonunda commit
   ├── Plan 04 ─┤
   └── Plan 05 ─┘
          │  hepsi main'e birleşince `swift build && swift test` yeşil
          ▼
      Plan 06 (tek ajan) → make run / make shot ile uçtan uca manuel doğrulama
```

## Superpowers ile nasıl yürütülür

1. `superpowers:subagent-driven-development`: her task için taze bir alt ajan, iki aşamalı inceleme (spec uyumu + kod kalitesi) — Plan 00 için sıralı.
2. Plan 00 bitince 01–05 için **5 paralel Opus ajanı**: her ajana yalnızca kendi planı + spec + `CLAUDE.md` verilir; `superpowers:using-git-worktrees` ile `worktrees/plan-0N` dalında çalışır; `superpowers:test-driven-development` zorunlu; bitişte `superpowers:requesting-code-review` ve `superpowers:verification-before-completion` (test çıktısı kanıtı).
3. Birleştirme: dallar `main`'e sırayla rebase edilir; çakışma beklenmez (dosya sahipliği ayrık). Tam `make test` yeşil olmadan Plan 06 başlamaz.
4. Plan 06 tek ajan; her task `make build` + `make run` + `make shot` ile görsel kanıt üretir (`verification/` altına PNG).
5. `superpowers:finishing-a-development-branch` ile kapanış.

## Kullanıcı adımları (ajanlar yapamaz)

- `make cert` sonrası Keychain Access'te "Shotcue Dev" sertifikasına Code Signing için "Always Trust" (bir kez).
- Ekran Kaydı ve Mikrofon izin diyaloglarını onaylamak; `make shot` için Terminal/Claude uygulamasına Ekran Kaydı izni.
- Plan 03 Task 1 (S4): kendi sesiyle 5 Türkçe not kaydedip model karşılaştırma tablosunu doldurmak.
- Plan 00 Task 11 S5: Claude Desktop deep link'inin görsel ekleyip eklemediğini gözlemlemek.
