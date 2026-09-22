# Shotcue — Tasarım Spec'i

Tarih: 2026-09-22 · Durum: kullanıcı incelemesi bekliyor · Çalışma dizini: `~/Projects/tasker` (isim değişikliği sonra yapılabilir)

Araştırma raporları: `docs/research/01…05`. Bu spec o raporların doğrulanmış bulgularına dayanır; rapordaki komut/API imzaları bu makinede derlenerek veya çalıştırılarak doğrulanmıştır.

---

## 1. Amaç

Klavye kısayoluyla ekranın bir bölgesini yakala, üzerine sesli veya yazılı not ekle, bunları **proje bazında** bir kütüphanede grupla/sırala ve tek tıkla ya da zamanlanmış olarak **headless Claude Code**'a görev olarak gönder. Claude Code görevi ilgili proje klasöründe çalıştırır; sonuç, maliyet ve session Shotcue içinde görünür; oturum terminalde veya Claude Desktop'ta devam ettirilebilir.

Tek kullanıcı: uygulama sahibi, kendi Mac'inde. Dağıtım yok.

## 2. Kullanıcıyla netleşen kararlar

| Konu | Karar |
|---|---|
| Ürün adı | **Shotcue** (bundle id `com.shotcue.app`, depolama `~/Library/Application Support/Shotcue/`) |
| Yaklaşım | Native Swift 6 + SwiftUI, **Xcode'suz** (CLT 27 + SwiftPM), hedef **macOS 26.0** |
| Gönderim kanalı | Headless Claude Code (`claude -p`), seçili proje klasöründe, kullanıcının Max aboneliğiyle (API key yok) |
| Grup modeli | **Grup = Proje klasörü** |
| Yetki modu | Uygula modunda **`bypassPermissions`**, gözetimsiz çalışmalar dahil (kullanıcı kararı; ayarlardan düşürülebilir) |
| Dağıtım | Kişisel; self-signed sertifika, notarization yok, **sandbox kapalı** |
| Zamanlama | Tek seferlik "şu tarih-saatte" + proje başına "günlük HH:MM kuyruk" |
| Kütüphane düzeni | Sidebar (projeler) + grid/liste; Kanban v2 |
| Dil | UI Türkçe; kod, identifier ve commit mesajları İngilizce; dokümanlar Türkçe |

## 3. Kapsam

### v1'de var
Global kısayolla bölge yakalama (sistem seçici), hızlı panel (metin + sesli not, proje, mod), cihaz içi Türkçe/İngilizce transkripsiyon, kütüphane penceresi (proje sidebar, grid/liste, sıralama, arama, çoklu seçim, Inspector), Claude runner (canlı log, sonuç, maliyet, bildirim, terminal/Desktop'a aktarım), zamanlayıcı (tek seferlik + günlük kuyruk, uyanma sonrası catch-up), ayarlar, izin onboarding'i, menü çubuğu.

### v1 dışı
Custom capture overlay (v2), annotasyon, Kanban görünümü, canlı transkript taslağı, bulut/sync, MCP sunucusu, Anthropic API ile uygulama içi sohbet, launchd ile uygulama kapalıyken zamanlama, otomatik güncelleme, App Store, çoklu kullanıcı.

## 4. Mimari

### 4.1 Paket düzeni

```
Package.swift                      # swift-tools-version 6.4, platforms [.macOS(.v26)], swiftLanguageModes [.v6]
Sources/
  ShotcueCore/          # saf domain: modeller, protokoller, durum makinesi, prompt üretici, zamanlayıcı mantığı, stream-json ayrıştırıcı. Bağımlılık: yok.
  ShotcuePersistence/   # GRDB: migration'lar, repository implementasyonları, dosya deposu (PNG/m4a yolları)
  ShotcueCapture/       # screencapture sarmalayıcı, thumbnail üretici, izin servisi, KeyboardShortcuts entegrasyonu
  ShotcueNotes/         # AVAudioEngine kayıt, WhisperKit transkripsiyon, (opsiyonel) Foundation Models
  ShotcueClaudeBridge/  # Process runner, RunCoordinator, git durum kaydı, aktarım (terminal/deep link), zamanlayıcı sürücüsü
  ShotcueUI/            # SwiftUI görünümleri ve @Observable store'lar
  ShotcueApp/           # @main, sahneler, composition root, bildirimler, login item
Tests/
  ShotcueCoreTests/  ShotcuePersistenceTests/  ShotcueCaptureTests/  ShotcueNotesTests/  ShotcueClaudeBridgeTests/
  Fixtures/            # fake-claude.sh, fake-screencapture.sh, sample.png, sample-stream.jsonl
Resources/             # Info.plist, Shotcue.entitlements, AppIcon.icns (iconutil ile); UI metinleri v1'de Türkçe literal, lokalizasyon dosyası yok
scripts/               # bundle.sh, make-cert.sh, install.sh, shot.sh
Makefile               # build, test, bundle, install, run, shot, reset-tcc
CLAUDE.md              # ajanlar için kurallar (bkz. §10.4)
docs/                  # research/, superpowers/specs/, superpowers/plans/
```

Bağımlılık yönü: `App → UI → Core`, `App → {Persistence, Capture, Notes, ClaudeBridge} → Core`. UI modülü servis modüllerini **bilmez**; sadece Core'daki protokolleri kullanır. Composition root `ShotcueApp/AppEnvironment.swift`.

### 4.2 Swift ayarları

- UI ve App target'ları: `.defaultIsolation(MainActor.self)`; servis target'ları: `.defaultIsolation(nil)`; tümünde `NonisolatedNonsendingByDefault` ve `InferIsolatedConformances` upcoming feature'ları.
- Dil modu Swift 6 (strict concurrency). Servisler `actor` veya `Sendable` sınıf; Core tipleri `Sendable` value type.

### 4.3 Bağımlılıklar (üçü de SPM)

| Paket | Sürüm | Amaç |
|---|---|---|
| `groue/GRDB.swift` | 7.x | SQLite, migration, `ValueObservation` |
| `sindresorhus/KeyboardShortcuts` | 3.1.x | Global kısayol (Carbon, izin istemez) + SwiftUI recorder |
| `argmaxinc/argmax-oss-swift` (WhisperKit) | 1.1.x | Cihaz içi Türkçe/İngilizce transkripsiyon |

Başka bağımlılık eklenmez. Waveform için basit SwiftUI seviye çubuğu yeterli.

### 4.4 Core protokolleri (her biri için production + fake implementasyon)

```
CaptureService        func captureRegion() async throws -> CaptureResult?   // nil = kullanıcı iptal etti
ThumbnailService      func makeThumbnail(for: URL, maxPixel: Int) async throws -> URL
PermissionService     var screenRecording: PermissionState; var microphone: PermissionState; func request(_:)
AudioRecorder         func start(to: URL) throws; func stop() async -> RecordingInfo; var level: AsyncStream<Float>
Transcriber           func transcribe(file: URL, language: String) async throws -> Transcript; var modelState: ModelState
ClaudeRunner          func run(_ spec: RunSpec, events: (RunEvent) -> Void) async throws -> RunResult; func cancel(runID:)
GitInspector          func snapshot(at: URL) async -> GitSnapshot?
Clock                 var now: Date   // testte sahte
TaskRepository, ProjectRepository, RunRepository (GRDB)
Notifier              func notify(_: AppNotification)
HandoffService        func openInTerminal(sessionID:); func openInDesktop(sessionID:); func openDesktopComposer(task:)
```

## 5. Kullanıcı akışları

### 5.1 Yakalama
1. Global kısayol (varsayılan `⌃⇧2`; Ayarlar'da recorder ile değiştirilir).
2. `CaptureService` `/usr/sbin/screencapture -i -s -x -t png <geçici yol>` çalıştırır. Kullanıcı sürükleyerek seçer; `Esc` iptal (çıkış kodu 1 + boş stderr).
3. PNG `captures/YYYY/MM/<uuid>.png`'e taşınır; boyut/ölçek okunur; thumbnail (`CGImageSource`, 512 px, arka planda) üretilir; `Capture` ve `inbox` durumunda bir `Task` kaydı oluşur. Ayar açıksa PNG panoya da kopyalanır.
4. Ekranın sağ üst köşesinde **hızlı panel** açılır (odak çalmayan `NSPanel`): önizleme, not alanı (odak burada), mikrofon düğmesi, proje seçici (son kullanılan varsayılan; `⌘1..⌘9`), mod seçici (proje varsayılanı), aksiyonlar `⌘↩` Kaydet, `⌘⇧↩` Kaydet ve gönder, `Zamanla…`, `Esc` (görüntü inbox'ta projesiz kalır).
5. Panel kapanır; menü çubuğu ikonu kısa süre vurgulanır.

### 5.2 Sesli not
Mikrofon düğmesine tıkla → kayıt başlar (süre + seviye çubuğu görünür) → tekrar tıkla veya `⌘⇧V` → durur. Ses `audio/<uuid>.m4a` (AAC-LC, 48 kHz mono, 64 kbps) olarak yazılır; `VoiceNote` kaydı `transcriptState = pending` ile oluşur; transkripsiyon arka planda başlar ve bitince transkript alanına dolar. Kullanıcı transkripti düzenlerse `editedByUser = true` olur ve bir daha otomatik üzerine yazılmaz. Panel kapansa da transkripsiyon devam eder; sonuç kütüphanede görünür.

### 5.3 Kütüphane
Sidebar: Projeler (her biri sayaçla), Inbox (projesiz), durum filtreleri. İçerik: grid (thumbnail, başlık, durum çipi, ses ikonu, tarih) veya `Table` liste. Sıralama: En yeni / En eski / Manuel / Durum. `⌘F` arama (başlık, not, transkript). Çoklu seçim → alt çubuk: Tek task olarak birleştir ve gönder, Ayrı ayrı gönder, Projeye taşı, Zamanla, Sil. Sürükle-bırak: task'ları sidebar'daki projeye bırakma; manuel sırada yeniden sıralama (macOS 27'de `reorderable`, 26'da `draggable`/`dropDestination`, `sort_index` fractional).

### 5.4 Task detayı (Inspector)
Görüntüler (büyük önizleme, `⌘C`, Finder'da göster), başlık (otomatik: not metninin ilk cümlesi; not yoksa transkriptin ilk cümlesi; ikisi de yoksa "Yakalama <gün.ay saat:dk>"; kullanıcı düzenlerse bir daha otomatik değişmez), not, transkript + ses oynatıcı, proje, mod (Analiz/Uygula), model override, zamanlama (Şimdi gönder / Tarih-saat / Günlük kuyruğa al / Zamanlamayı kaldır), run geçmişi (her run: durum, süre, tur, maliyet tahmini, özet) ve seçili run'ın canlı/kayıtlı logu; aksiyonlar: Terminalde devam et, Desktop'ta aç, Desktop composer'da aç, Diff'i göster, Yeniden çalıştır, İptal (çalışıyorsa).

### 5.5 Gönderme ve sonuç
`Şimdi gönder` → `queued` → `RunCoordinator` sırası gelince `running` → `done`/`failed`. Bitişte bildirim (başlık + tek satır özet + maliyet; aksiyonlar: Aç, Terminalde devam et). Menü çubuğu menüsü: son 5 task ve durumları, Kuyruğu şimdi çalıştır, Duraklat/Sürdür, Kütüphane, Ayarlar, Çık.

## 6. Bileşen tasarımı

### 6.1 Capture (`ShotcueCapture`)
- **v1 yöntemi:** `screencapture -i -s -x -t png`. TCC kontrolü "responsible process" üzerinden yapılır, yani izin Shotcue.app'e sorulur. Sonuç doğrulama: çıkış 0 → başarı; 1 + boş stderr → iptal; diğer → hata.
- **İzinler:** açılışta `CGPreflightScreenCaptureAccess()`; false ise onboarding görünümü → `CGRequestScreenCaptureAccess()`; reddedilmişse `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` linki; izin verilince uygulama yeniden başlatılır. Aylık yeniden onay diyaloğu beklenen davranıştır (Ayarlar > İzinler'de açıklama).
- **Kısayol:** `KeyboardShortcuts.Name.captureRegion`; Ayarlar'da `KeyboardShortcuts.Recorder`.
- **Thumbnail:** `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize: 512`), `Task.detached(priority: .utility)`.
- **Retina:** PNG piksel boyutu + `scale` (`NSScreen.backingScaleFactor` yerine görüntü DPI metadata'sından; screencapture bunu yazar) kaydedilir; SwiftUI'da nokta boyutuyla gösterilir.
- **v2 (planlanmış, v1 dışı):** her ekran için `NSPanel` overlay + `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)`; aynı bölgeyi tekrar çek, büyüteç.

### 6.2 Notes (`ShotcueNotes`)
- **Kayıt:** `AVAudioEngine`, `inputNode.installTap(onBus: 0)` tek tap; blokta `AVAudioFile` yazımı (AAC ayarları) + RMS seviye. `AVAudioEngineConfigurationChange` bildiriminde tap kaldır, formatı yeniden oku, tap kur, `engine.start()`; 0 Hz format koruması. Giriş cihazı seçimi: `AVCaptureDevice.DiscoverySession` listesi → `kAudioOutputUnitProperty_CurrentDevice`.
- **Mikrofon izni:** `NSMicrophoneUsageDescription` + entitlement `com.apple.security.device.audio-input` (Hardened Runtime'da yoksa diyalog hiç çıkmaz).
- **Transkripsiyon (tek motor, v1):** WhisperKit, model ayarı varsayılan `openai_whisper-large-v3-v20240930_turbo` (alternatif `…_626MB`), dil ayarı varsayılan `tr` (`en` seçilebilir; `auto` yok, karışık dilde Türkçe sabit). Model ilk kullanımda **açık onayla** indirilir (boyut gösterilir, arka planda ilerleme çubuğu). Model hazır değilken sesli notlar kaydedilir, transkript `pending` kalır, model gelince kuyruk işlenir; bu arada kullanıcı metin yazabilir.
  - Gerekçe: `SpeechTranscriber` Türkçe desteklemiyor; Apple'ın Türkçe dikte modeli İngilizce teknik terimleri bozuyor (rapor 03'te ölçüldü). `SFSpeechRecognizer` kullanılmaz.
  - Çıktı: `Transcript { text, language, engine, segments[{start,end,text,confidence?}] }`; DB'de `voice_note.transcript` + `transcript_json`.
- **v1.1 seçenekleri:** kayıt sırasında canlı taslak (`DictationTranscriber` tr-TR / `SpeechTranscriber` en-US), bulut fallback (AssemblyAI). Runtime'da `SpeechTranscriber.supportedLocales` kontrol edilir; Türkçe gelirse ayarlarda motor seçeneği olarak açılır (`supportedLocale(equivalentTo:)` kullanılmaz, yanıltıcı).
- **Foundation Models (opsiyonel ayar, varsayılan kapalı):** `SystemLanguageModel.default.availability == .available` ise `@Generable TaskDraft { title, summary, tags }` ile başlık ve temiz görev metni **önerisi** (kullanıcı onaylar; transkript sessizce değiştirilmez). Türkçe destekleniyor (`tr-Latn-TR`); Apple Intelligence kapalıysa özellik gizlenir.

### 6.3 Persistence (`ShotcuePersistence`)
GRDB `DatabasePool` (WAL), `DatabaseMigrator` ile numaralı migration'lar. Dosya kökü `~/Library/Application Support/Shotcue/`; DB'de **göreli yol** tutulur.

```
project     id TEXT PK, name, path, default_mode, default_model NULL, default_effort NULL,
            daily_time NULL (HH:MM), daily_enabled INT, daily_last_fired_at NULL,
            run_in_branch INT DEFAULT 0, stash_before_run INT DEFAULT 0, sort_index REAL, created_at
task        id TEXT PK, project_id NULL FK, title, note_text, status, mode, model_override NULL,
            sort_index REAL, scheduled_at NULL, created_at, updated_at
capture     id TEXT PK, task_id FK, rel_path, thumb_rel_path NULL, width, height, scale, created_at
voice_note  id TEXT PK, task_id FK, rel_path, duration_sec, transcript NULL, transcript_json NULL,
            transcript_state, engine NULL, edited_by_user INT DEFAULT 0, created_at
run         id TEXT PK (= claude session id), task_id FK, state, started_at, finished_at NULL,
            num_turns NULL, cost_usd NULL, result_text NULL, subtype NULL, exit_code NULL, error NULL,
            log_rel_path, git_head_before NULL, git_dirty_before NULL, git_head_after NULL, git_branch NULL
```
İndeksler: `task(project_id, status)`, `task(scheduled_at)`, `run(task_id, started_at)`. Ayarlar `UserDefaults` (`@AppStorage`).

Dosyalar: `captures/YYYY/MM/<uuid>.png`, `thumbs/<uuid>.jpg`, `audio/<uuid>.m4a`, `runs/<runId>.jsonl`, `shotcue.sqlite`. Thumbnail kaybolursa yeniden üretilir.

### 6.4 Claude runner (`ShotcueClaudeBridge`)
**Komut** (Uygula modu, varsayılan):
```
claude -p "<prompt>" --session-id <run.id> --output-format stream-json --verbose \
  --add-dir "<Application Support/Shotcue/captures>" --permission-prompts none \
  --permission-mode bypassPermissions --max-turns <ayar, 50> --max-budget-usd <ayar, 5> \
  --append-system-prompt "<sabit talimat>" [--model <proje/task ayarı>] [--effort <ayar>]
```
Analiz modu farkı: `--permission-mode dontAsk --allowedTools "Read,Glob,Grep,WebFetch,WebSearch,Bash(git log *),Bash(git diff *),Bash(git status *),Bash(git show *)"`.
- `cwd` = proje yolu. Ortam: `HOME`, `PATH` (claude'un dizini + sistem yolları) açıkça verilir; `ANTHROPIC_API_KEY` kaldırılır (abonelik kullanılsın). `--bare` asla kullanılmaz.
- `claude` yolu: ayar → yoksa sırayla `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, login shell `which claude`. Açılışta `claude --version` okunur ve gösterilir (test edilen sürüm 2.1.278).
- **Prompt üretici (Core, saf fonksiyon):** `TASK TYPE` (ANALYZE ONLY / IMPLEMENT), `TITLE`, `SCREENSHOTS` (mutlak yollar, her biri kullanıcı notundan türetilen kısa etiketle, "read these first with the Read tool"), `NOTE` (metin) ve `VOICE NOTE (dictated, verbatim transcript)` blokları, `PROJECT`, `EXPECTED OUTCOME` (moda göre sabit şablon; Uygula: "fix/implement, add or update tests, do NOT commit or push"; Analiz: "report only, do not modify files"). Çoklu görsel tek prompt'ta listelenir.
- **Sabit sistem talimatı (append):** Shotcue bağlamı; görselleri düzenlemeden önce oku; transkript dikte edilmiş olabilir, niyeti yorumla; her zaman 3 satır özet + değişen dosyalar + yapılamayanlar ile bitir; ANALYZE ONLY'de dosya değiştirme.
- **Akış ayrıştırma (Core):** stdout NDJSON satırları → `RunEvent` (`init`, `assistantText`, `toolUse(name, inputSummary)`, `apiRetry`, `result`). Her satır `runs/<id>.jsonl`'a olduğu gibi eklenir. `result` olayından `subtype`, `is_error`, `result`, `total_cost_usd`, `num_turns`, `duration_ms`, `permission_denials` okunur.
- **Sonuç eşlemesi:** `success` → `done`; `error_max_turns` / `error_max_budget_usd` → `failed` (yeniden denenmez, kullanıcıya sorulur); `error_during_execution` → `failed`; çıkış kodu ≠ 0 → `failed` + stderr; 130/143 → `cancelled`.
- **İptal:** SIGINT → 10 sn → SIGKILL. Zaman aşımı ayarı (varsayılan 30 dk) aynı yolu kullanır.
- **RunCoordinator (actor):** kuyruk; proje başına aynı anda en fazla 1 run; global limit ayarı (varsayılan 2); run sırasında `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`.
- **Git güvenlik ağı:** run öncesi `git rev-parse HEAD`, `git status --porcelain`, `git branch --show-current`; sonrası HEAD. Proje ayarı `run_in_branch` açıksa run öncesi `git switch -c shotcue/<taskId-kısa>`; `stash_before_run` açıksa `git stash push -u -m shotcue`. Varsayılan ikisi de kapalı. "Diff'i göster": `git diff <head_before>` + çalışma ağacı, uygulama içinde salt metin.
- **Aktarım:** Terminal: geçici `.command` dosyası (`claude --resume <id>`) `NSWorkspace.open`; Desktop: `claude://code/resume?session=<id>`; Composer: `claude://code/new?q=…&folder=…&file=…` (prompt 14 000 karakterde kırpılır, uzun not `runs/<id>-prompt.md`'ye yazılıp yol verilir; dosya eki çalışmazsa `cowork/new`; her ikisi de otomatik göndermez).

### 6.5 Zamanlayıcı
- Core'da saf fonksiyon: `dueActions(now, tasks, projects) -> [ScheduledAction]` (`.runTask(id)`, `.fireDailyQueue(projectId)`); tamamen test edilebilir.
- Sürücü (ClaudeBridge): `DispatchSourceTimer` 30 sn; `NSWorkspace.didWakeNotification` ve uygulama açılışında anında `reconcile()`.
- Tek seferlik: `scheduled_at <= now` ve durum `scheduled` → `queued`. Günlük: `daily_enabled` ve bugün `daily_time` geçmiş ve `daily_last_fired_at` bugünden önce → o projenin `ready`/`queued` taskları manuel sıraya göre kuyruğa; `daily_last_fired_at = now`. Uyku sonrası kaçanlar bir kez çalışır (flood yok).
- Zaman dilimi yerel. Opsiyonel ayar: "önümüzdeki 1 saat içinde zamanlanmış iş varsa uyanık tut".

### 6.6 UI (`ShotcueUI`)
- **Sahneler (App):** `MenuBarExtra("Shotcue", systemImage:)` `.menuBarExtraStyle(.window)`; `Window("Kütüphane", id: "library")`; `Settings`. Hızlı panel ve onboarding `NSPanel`/`NSWindow` + `NSHostingView` (bridging App'te, içerik UI'da).
- **Hızlı panel:** `NSPanel(styleMask: [.nonactivatingPanel, .fullSizeContentView])`, `isFloatingPanel`, `level = .floating`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `canBecomeKey` override, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`; `NSApp.activate` çağrılmaz; odak `panel.makeKey()` + `@FocusState` (bir frame sonra); `⌘↩`/`Esc` için `NSEvent.addLocalMonitorForEvents`; dışarı tıklamada kapanmaz (kullanıcı bilinçli kapatır), `Esc` kapatır.
- **Kütüphane:** `NavigationSplitView` (sidebar `List` + `Section`; içerik `LazyVGrid`/`Table`, `Picker` ile geçiş; `.inspector(isPresented:)`), `.searchable`, `.contextMenu(forSelectionType:)`, alt seçim çubuğu `.safeAreaInset(edge: .bottom)` + `glassEffect`. Store'lar: `LibraryStore`, `TaskDetailStore`, `QuickPanelStore`, `SettingsStore` (`@Observable`, GRDB `ValueObservation` ile beslenir).
- **Ayarlar sekmeleri:** Genel (kısayol recorder, login'de başlat `SMAppService`, yakalamada panoya kopyala, depolama konumu, varsayılan proje), Claude (CLI yolu + sürüm, varsayılan mod, model, effort, max tur, bütçe tahmini, zaman aşımı, eş zamanlı run, ek sistem talimatı), Ses (giriş cihazı, model seçimi + indirme durumu, dil), İzinler (Ekran Kaydı, Mikrofon, Bildirim durumu + Sistem Ayarları linkleri; Foundation Models durumu).
- **Dock:** `LSUIElement = true`; kütüphane açılınca `NSApp.setActivationPolicy(.regular)` + `activate()`, kapanınca `.accessory`.
- **Görsel dil:** toolbar ve panel yüzeyinde Liquid Glass (`glassEffect`, `.buttonStyle(.glass)`/`.glassProminent`), SF Symbols, sistem renkleri; ikonlar asset catalog gerektirmez.

### 6.7 App (`ShotcueApp`)
`AppEnvironment` composition root (tüm servislerin production örnekleri), `AppDelegate` (kısayol kaydı, panel yöneticisi, bildirim delegesi, uyanma gözlemcisi), `UNUserNotificationCenter` kategorileri (`RUN_DONE`: Aç / Terminalde devam et; `RUN_FAILED`: Aç / Yeniden çalıştır), açılışta `running` kalan run'ları `failed(interrupted)` yapma, `claude` ve izin durumu kontrolü.

## 7. Durum makinesi

```
inbox ──(proje atandı)──► ready ──(gönder)──► queued ──► running ──► done
  │                          │                             ▲  │
  │                          └──(zamanla)──► scheduled ────┘  └──► failed ──(yeniden çalıştır)──► queued
  └─ projesiz: gönderilemez (uyarı)               cancelled: running'den kullanıcı iptaliyle; queued/scheduled'dan "zamanlamayı kaldır" → ready
```
Kurallar: `running` task düzenlenemez (iptal edilebilir); bir task'ın birden çok `Run` kaydı olabilir (geçmiş); `done` task tekrar gönderilebilir (yeni run). Geçişler Core'da `TaskStatus.transition(to:)` ile doğrulanır ve test edilir.

## 8. Hata yönetimi

| Durum | Davranış |
|---|---|
| Ekran kaydı izni yok | Onboarding + Sistem Ayarları linki; kısayol izin verilene kadar onboarding'i açar |
| Mikrofon izni yok | Ses düğmesi devre dışı + açıklama; metin not çalışır |
| `screencapture` hata | Bildirim + log; task oluşturulmaz |
| `claude` bulunamadı / sürüm okunamadı | Ayarlar'da kırmızı durum; gönder düğmeleri devre dışı, açıklama |
| Oturum düşmüş (auth hatası) | Run `failed`, mesaj "`claude` ile tekrar giriş yapın" |
| CLI hata / exit ≠ 0 | stderr + kod `run.error`; bildirim; Yeniden çalıştır |
| `error_max_turns` / `error_max_budget_usd` | `failed`, yeniden denenmez; Inspector'da limit artırma önerisi |
| Zaman aşımı | SIGINT → SIGKILL; `failed(timeout)` |
| Uygulama run ortasında kapandı | Açılışta `failed(interrupted)`; session id ile "Terminalde devam et" |
| Whisper modeli inmedi / transkripsiyon hatası | `transcript_state = failed`, ses saklanır, kullanıcı metin yazar; tekrar dene düğmesi |
| Disk yazma hatası | Yakalama iptal, uyarı |
| Proje klasörü yok/taşınmış | Run başlatılmaz; proje kırmızı; yol düzeltilir |

## 9. Güvenlik ve izinler

- Sandbox kapalı; Hardened Runtime açık; entitlements: `com.apple.security.device.audio-input = true`, `app-sandbox = false`.
- Info.plist: `CFBundleIdentifier com.shotcue.app`, `LSUIElement true`, `LSMinimumSystemVersion 26.0`, `NSMicrophoneUsageDescription`, `CFBundleURLTypes` yok (Shotcue URL scheme almaz).
- Ekran görüntüleri ve sesler yalnızca yerel diskte; Claude Code'a giden veri kullanıcının kendi aboneliği üzerinden gider. `bypassPermissions` kullanıcı kararıdır; Ayarlar > Claude'da uyarı metniyle gösterilir ve `acceptEdits`'e düşürülebilir.
- Hassas veri redaksiyonu (Xnapper tarzı) v1 dışı; not olarak kaydedildi.

## 10. Build, imzalama, geliştirme döngüsü

### 10.1 Makefile hedefleri
`make build` (`swift build -c debug`), `make test` (`swift test`), `make bundle` (`scripts/bundle.sh`: `.app` iskeleti, Info.plist, ikon, binary kopyası, entitlements ile `codesign --force --options runtime --sign "Shotcue Dev"`), `make install` (`~/Applications/Shotcue.app`'e kopyala, çalışanı kapat, yeniden başlat), `make run` (`install` + `open`), `make shot` (`scripts/shot.sh`: kütüphane penceresini açtır, `screencapture -l <windowid>` ile PNG al, yolu yazdır; bunu çalıştıran sürece, yani Terminal'e veya Claude uygulamasına bir kez Ekran Kaydı izni verilmesi gerekir), `make reset-tcc` (`tccutil reset ScreenCapture com.shotcue.app; tccutil reset Microphone com.shotcue.app`), `make format` (`swift-format`).

### 10.2 Sertifika (tek seferlik, kullanıcı yapar)
`scripts/make-cert.sh` self-signed "Shotcue Dev" code-signing sertifikasını üretir ve keychain'e alır; Keychain Access'te "Always Trust" kullanıcı tarafından verilir. Ad-hoc imza (`--sign -`) **kullanılmaz** (her build'de TCC sıfırlanır). Bundle id ve kurulum yolu sabit.

### 10.3 Test fixture'ları
`Tests/Fixtures/fake-claude.sh`: argümanları bir dosyaya yazar, `sample-stream.jsonl`'i stdout'a basar (senaryo: başarı / max_turns / hata / yavaş). `fake-screencapture.sh`: `sample.png`'i hedef yola kopyalar veya `exit 1` ile iptal simüle eder. Runner ve capture testleri bu betikleri `executableURL` olarak alır.

### 10.4 `CLAUDE.md` (proje kökü, ajanlar için)
Kurallar: Xcode yok, `make test` birincil döngü; mantık Core'a, UI ince; yasak API'ler (`CGWindowListCreateImage`, `CGDisplayCreateImage`, `SFSpeechRecognizer`, `SpeechTranscriber.supportedLocale(equivalentTo:)`, `NSApp.activate` panelde, ad-hoc imza, `AVAudioSession`, `Timer` yerine `DispatchSourceTimer`, `--bare`); Swift Testing; `swift-format`; commit mesajları İngilizce; her task için testler önce; UI değişikliğinde `make shot` ile görsel doğrulama.

## 11. Test stratejisi

- **Core (Swift Testing, ~6 sn döngü):** durum geçişleri; kuyruk sıralama ve proje başına tek run kuralı; `dueActions` (sahte saat: gece geçişi, uyku sonrası catch-up, aynı gün tekrar tetiklenmeme); prompt üretici (Analiz/Uygula, çoklu görsel, boş transkript); stream-json ayrıştırma (fixture satırları, bozuk satır toleransı); `ClaudeRunResult` decode; fractional `sort_index` hesapları; git snapshot ayrıştırma.
- **Persistence:** bellek içi GRDB ile migration ve repository testleri; göreli/mutlak yol dönüşümü.
- **Capture:** fake screencapture ile başarı/iptal/hata; thumbnail üretimi gerçek küçük PNG ile.
- **Notes:** `AVAudioFile` yazımı geçici dosyaya; transcriber fake ile pipeline (gerçek WhisperKit testi manuel).
- **ClaudeBridge:** fake claude ile uçtan uca run (event akışı, sonuç eşlemesi, iptal, zaman aşımı, ortam değişkenleri, argüman doğrulama); RunCoordinator eş zamanlılık kuralları.
- **Manuel kontrol listesi:** TCC akışları, çoklu ekran yakalama, panel odak davranışı, uyku/uyanma, bildirim aksiyonları, gerçek `claude` ile bir Analiz ve bir Uygula run'ı, Desktop deep link'leri.

## 12. Riskler ve spike'lar (uygulama planında Task 0)

| Spike | Neden | Başarı ölçütü |
|---|---|---|
| S1: Bundle'dan spawn edilen `claude` Keychain'e erişiyor mu | Tüm mimari buna dayanıyor | `.app` içinden `claude auth status` `loggedIn: true` döner |
| S2: Self-signed sertifika ile TCC kalıcılığı | Aksi halde her build'de izin | İki ardışık `make install` sonrası Ekran Kaydı izni korunur |
| S3: `screencapture -i -s` bundle'dan | İzin prompt'u ve iptal tespiti | Prompt Shotcue adına çıkar; `Esc` → exit 1 |
| S4: WhisperKit Türkçe kalite/hız | Model seçimi (turbo vs 626MB) | 5 gerçek not, teknik terimler korunuyor, 30 sn not < 5 sn |
| S5: `claude://code/new?file=` görseli iliştiriyor mu | Composer aktarımı | Görsel eklenmezse `cowork/new` kullanılır |

Diğer riskler: aylık TCC yeniden onayı (kabul edildi); WhisperKit'in Swift 6.4/SDK 27 ile derlenmesi (S4'te görülür; sorun çıkarsa `626MB` + eski sürüm pin); SwiftUI incremental build ~31 sn (mantık Core'da; UI değişiklikleri toplu); `claude` bayraklarının sürümle değişmesi (sürüm kontrolü + argümanlar tek dosyada).

## 13. Superpowers ile uygulama süreci

1. Bu spec onaylanınca `superpowers:writing-plans` ile `docs/superpowers/plans/2026-09-22-shotcue-v1.md` yazılır: küçük, bağımsız, test-önce görevler; her görev hangi modüle dokunduğunu belirtir.
2. Uygulama `superpowers:subagent-driven-development` ile: Task 0 (iskelet + Makefile + sertifika + spike'lar) tek ajan; ardından **paralel Opus ajanları** modül başına (`Core` protokolleri ve testleri önce; sonra `Persistence`, `Capture`, `Notes`, `ClaudeBridge` eş zamanlı; sonra `UI`; sonra `App` entegrasyonu). Her ajan kendi git worktree'sinde (`superpowers:using-git-worktrees`), TDD (`superpowers:test-driven-development`), bitince kod incelemesi (`superpowers:requesting-code-review`), doğrulama kanıtıyla tamamlanma (`superpowers:verification-before-completion`).
3. Modül sınırı = Core protokolleri; ajanlar birbirinin dosyasına dokunmaz. Entegrasyon `App` görevinde yapılır; `make run` + `make shot` ile görsel doğrulama.
4. Dal bitince `superpowers:finishing-a-development-branch`.
