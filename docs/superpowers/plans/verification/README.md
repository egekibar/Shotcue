# Plan 06 — uçtan uca doğrulama kayıtları

Makine: macOS 26.6.2 (25G83) · CLT 27.0 / Swift 6.4 · claude 2.1.278 (Claude Code) · tarih: 2026-09-23
Uygulama kodu: `82d859b` (branch `worktree-agent-ac4075b117bee8f68`, taban `367e7eb`; Plan 07 birleşimi `2a2d8fe`,
düzeltme turu 1: `25e3a6f`…`82d859b`)

## Durum anahtarı

- **geçti** — ajan ölçtü, beklenen çıktı alındı (kanıt satırda).
- **kısmen (ajan)** — otomatikleştirilebilen kısım ajan tarafından ölçüldü ve geçti; kalan adımlar PENDING (user).
- **PENDING (user)** — ajanın yapamayacağı / yapmaması gereken adım: TCC diyaloğu yanıtlamak, `make cert` +
  Keychain güveni, `make reset-tcc`, gerçek `claude -p` çalıştırmak, WhisperKit modelini indirmek, fiziksel tuş/fare,
  ikinci ekran, uyku, kullanıcının ayarlarını (giriş öğeleri vb.) değiştirmek, Ekran Kaydı izni gerektiren `make shot`.
- **geçmedi (neden)** — şu an yok.

Ajan bu oturumda hiçbir TCC diyaloğu tetiklemedi ya da yanıtlamadı (tccd kayıtlarında Shotcue'ya ait her istek
`preflight=yes`), model indirmedi, `claude -p` başlatmadı, `make cert` / `make reset-tcc` çalıştırmadı, kullanıcı
ayarlarına / giriş öğelerine dokunmadı. Ölçümlerin bir kısmı, commit'lenmeyen geçici bir ortam-değişkeni "probe"u ile
gerçek uygulama içinde alındı (probe kodu her seferinde silindi; `git diff` boş). Düzeltme turu 1'in probe'ları gerçek
denetleyicileri/store'ları bellek içi bir GRDB veritabanına karşı çalıştırdı (F3, F5) ya da uygulamanın boş veritabanına
geçici satırlar yazıp sildi (F4: sonrasında `task` 0, `project` 0).

## Kurulum (kullanıcı, bir kez)

```bash
make cert                    # "Shotcue Dev" sertifikası; Keychain Access'te "Always Trust" (spec §10.2)
make install
mkdir -p docs/superpowers/plans/verification
sqlite3 ~/Library/Application\ Support/Shotcue/shotcue.sqlite ".tables"   # capture project run task voice_note …
```

- `make shot`, onu çalıştıran uygulamanın (Terminal / iTerm / Claude) Ekran Kaydı iznine ihtiyaç duyar. Ajanın
  kabuğunda `CGPreflightScreenCaptureAccess()` → `false` olduğu için hiçbir PNG üretilmedi; tablodaki `*.png`
  kanıtlarını izin verilmiş bir terminalden `./scripts/shot.sh Shotcue docs/superpowers/plans/verification` ile üret.
- Test projesi: temiz bir git repo'su (`~/Projects/shotcue-testbed`: `git init`, küçük bir dosya, `git commit`),
  Kütüphane > Projeler > "+" ile ekle.
- **Tarih dönüşümü:** veritabanındaki tarihler 2001-01-01'den beri geçen saniyedir (Double, `Date`'in referansı; Plan 01
  düzeltmesi). Ham değeri okurken **978307200 ekle**:
  - SQL: `datetime(scheduled_at + 978307200, 'unixepoch', 'localtime')`
  - shell: `date -r $(( ${X%.*} + 978307200 ))`
- Uygulamanın kendi log satırları: `log stream --predicate 'subsystem == "com.shotcue.app" AND category == "app"'`
  (ör. `hotkey ⌃⇧2 registered`, `claude found: 2.1.278 (Claude Code)`, bildirim aksiyonları).

## V1–V14

| # | Kontrol | Sonuç | Kanıt |
|---|---|---|---|
| V1 | İmza + TCC kalıcılığı (`Authority=Shotcue Dev`) | PENDING (user) | Ajan ölçümü: keychain'de kod imzalama kimliği yok (`security find-identity -v -p codesigning` → 0), `bundle.sh` ad-hoc'a düştü: `codesign -dv` → `Identifier=com.shotcue.app`, `flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set`, `Authority=` satırı yok. `make cert` + Always Trust sonrası iki ardışık `make install` arasında Ekran Kaydı izni korunmalı. |
| V2 | İzin onboarding'i + relaunch | kısmen (ajan) | Ekran Kaydı izni olmayan build açılışta onboarding'i açtı: bir Shotcue penceresi 480 × 539, `lsappinfo` → `Foreground` (Dock ikonu). Relaunch yolu probe ile: pid 65763 `relaunching after the Screen Recording grant` → eski süreç bitti → yeni pid 65800 0,2 sn sonra `hotkey ⌃⇧2 registered` (çakışma yok), ikinci relaunch yok. PENDING (user): `make reset-tcc`, satırlar "Sorulmadı" + "İzin ver" / reddedilince "Reddedildi" + "Sistem Ayarları", izni ver, **"Başla"** → yeni PID, onboarding bir daha açılmaz; `v2-onboarding.png`. **Yaz:** izin verildikten sonra macOS "yeniden başlat" diyaloğu gösterirse **Later**'ı seç, onboarding'e dönüp **"Durumları yenile"**'ye bas ve "Başla"nın yeniden başlatmadan etkinleşip etkinleşmediğini not et (`CGPreflightScreenCaptureAccess` süreç yeniden başlamadan `true` dönmeyebilir; dönmüyorsa kullanıcı "Başla"ya basamaz ve uygulamayı elle kapatıp açması gerekir — bulguyu buraya yaz). |
| V3 | İki ekranda yakalama + ölçek | PENDING (user) | Harici ekran gerekir (`select width, height, scale from capture order by created_at desc limit 2;` → Retina 2, 1x ekranda 1). Ekran yoksa "ekran yok — doğrulanamadı". |
| V4 | Panel odağı, ⌘↩ / ⌘⇧↩ / Esc | kısmen (ajan) | Probe (uygulama `open -g` ile arka planda başlatıldı, var olmayan bir task id ile panel açıldı — hiçbir kayıt yazılamaz): önce `appActive=false policy=1 frontmost=<başka uygulama>`; `makeKeyAndOrderFront` sonrası panel `key=true main=false`, first responder `PlatformTextView` (not alanı), **`frontmostApplication` değişmedi**, policy `accessory` (Dock ikonu yok). Çerçeve `{{1134, 670}, {560, 387}}`, visibleFrame `{{0, 0}, {1710, 1073}}` → sağ ve üst kenarda tam 16 pt. İki satırlık hata eklenince `{{1134, 634}, {560, 423}}`: üst kenar sabit, panel aşağı büyüyor. `dismiss()` → panel kapandı, menü ikonu vurgusu (`captureFlash=true`). Not: panel key iken AppKit `NSApp.isActive` = true okuyor (spike'ta false idi); sistem düzeyinde öndeki uygulama değişmiyor. PENDING (user): TextEdit öndeyken yakala → başlık çubuğu aktif kalır, yazı panele gider; ⌘1…⌘9; ⌘↩ → `ready`, run yok; ⌘⇧↩ → `queued`/`running` + **bir** run; Esc → `inbox`, `project_id` NULL; `v4-quick-panel.png`. |
| V5 | Sesli not → transkript | PENDING (user) | Ajan modeli indirmez. Ayarlar > Ses > "Modeli indir" (açık onayla; indirme sürerken ilerleme çubuğu ve "İndiriliyor… %n" yarım saniyede bir ilerler, düğmeye ikinci basış ikinci indirme başlatmaz), sonra `select transcript_state, length(transcript), engine from voice_note order by created_at desc limit 1;` → önce `pending`, sonra `done`; teknik terimler bozulmamış; panel Esc ile kapansa da transkript tamamlanır. |
| V6 | Gönder → canlı log → done → bildirim → terminal | PENDING (user) | Gerçek `claude -p` gerekir. `select state, subtype, num_turns, cost_usd, git_head_before is not null, git_head_after is not null from run order by started_at desc limit 1;` → `succeeded\|success\|n\|usd\|1\|1`; bir Analiz run'ı sonrası `git status --porcelain` boş; `v6-live-log.png`. **Bilinen açık:** "done" bildiriminde maliyet **yok** — Core `AppNotification`'ın maliyet alanı yok, gövde sonucun ilk satırı ya da "Tamamlandı"; spec §5.5 / brief'in "özet + maliyet" beklentisi bu satırda karşılanamaz (maliyet Inspector'daki run satırında görünür). **Yaz:** "Terminalde devam et" açılan terminal `$HOME`'da başlar (`.command` dosyası proje klasörüne `cd` etmez); `claude --resume <id>` oturumu oradan bulabiliyor mu? "No conversation found" görülürse not et. |
| V7 | Desktop resume + composer (görsel iliştiriliyor mu?) | PENDING (user) | Claude Desktop gerekir. Composer görseli iliştirmiyorsa bulgu buraya: rota `cowork/new` olmalı (spike S5). |
| V8 | Tek seferlik zamanlama (tek tetikleme) | PENDING (user) | `select status, datetime(scheduled_at + 978307200, 'unixepoch', 'localtime') from task where scheduled_at is not null order by updated_at desc limit 1;` — zamanında (≤ 30 sn gecikme) `queued`→`running`, bir kez. |
| V9 | Günlük kuyruk (proje başına 1 run, gün içinde tekrar yok) | PENDING (user) | `select status, count(*) from task group by status; select name, daily_time, datetime(daily_last_fired_at + 978307200, 'unixepoch', 'localtime') from project;` |
| V10 | Uyku/uyanma catch-up | PENDING (user) | `pmset sleepnow`, 4+ dk sonra uyandır; ≤ 30 sn içinde bir run, flood yok. `SchedulerDriver` uyanmayı log'lamaz; kanıt DB'den (`select count(*) from run;`). |
| V11 | Yarım kalan run → failed(interrupted) | PENDING (user) | Gerçek run gerekir: run başlayınca `pkill -9 -x Shotcue` → `running`; yeniden açınca `select state, error from run order by started_at desc limit 1;` → `failed` + `interrupted`; "Terminalde devam et" çalışır. **Yaz:** terminal `$HOME`'da açılır (`.command` proje klasörüne `cd` etmez) — yarıda kalan oturum oradan devam ettirilebiliyor mu? |
| V12 | Menü çubuğu menüsü + Dock politikası | kısmen (ajan) | Dock politikası ölçüldü: açılışta `lsappinfo` → `UIElement` (Dock yok); `SHOTCUE_OPEN_LIBRARY=1` → `Foreground` + 1180 × 760 kütüphane penceresi; probe: kütüphane + onboarding açıkken `policy=0`, kütüphane kapatılınca onboarding yüzünden hâlâ `0` (referans sayımı), onboarding kırmızı düğme yoluyla (`performClose`) kapatılınca `policy=1`, `lsappinfo` → `UIElement`, süreç çalışmaya devam ediyor. PENDING (user): menü içeriği (son 5 task, Kuyruğu şimdi çalıştır, Duraklat/Sürdür, Kütüphane, Ayarlar, Çık), Duraklat → yeni gönderim `queued`'da bekler; menü ikonunun kendisi (macOS 26'da üçüncü taraf durum öğeleri izinsiz pencere listesinde görünmüyor); `v12-menu-and-library.png`. |
| V13 | Ayarlar, kısayol değişimi, login item, tanılama | kısmen (ajan) | Tanılama raporu probe ile yazıldı (düzenleyicide açılmadan): `$(getconf DARWIN_USER_TEMP_DIR)shotcue-diagnostics.txt`, mod `-rw-------` (600), klasör `drwx------`; içerik aşağıda ("Ajanın tanılama çıktısı"); `grep -c "@"` → 0, e-posta/org yok; `claude auth: loggedIn=true authMethod=claude.ai subscriptionType=max`. PENDING (user): dört sekme; kısayol seçicide 6 kombinasyon, seçilen yeni kısayol Ayarlar kapanmadan çalışır; "Oturum açılışında başlat" aç/kapat → şerit gerçek `SMAppService` durumunu gösterir (ad-hoc build'de `.notFound`, bkz. Notlar); "Tanılama çalıştır" düğmesi; `make cert` sonrası `cp "$(getconf DARWIN_USER_TEMP_DIR)shotcue-diagnostics.txt" docs/superpowers/plans/verification/v13-diagnostics.txt` (`imza: Authority=Shotcue Dev` satırını içermeli); `v13-settings.png`. |
| V14 | Hata yolları (spec §8, 8 satır) | PENDING (user) | Aşağıdaki tablo. |

### V14 — hata yolları

| Durum | Nasıl tetiklenir | Beklenen | Sonuç |
|---|---|---|---|
| Ekran kaydı izni yok | `make reset-tcc` + `⌃⇧2` | Onboarding açılır, seçim imleci çıkmaz, task satırı oluşmaz | PENDING (user) — ajan: izinsiz build açılışta onboarding'i açıyor (V2); kısayol yolu her basışta izinleri tazeleyip `isBlocking` ise onboarding'i açar (kod). |
| Mikrofon izni yok | Sistem Ayarları'ndan mikrofonu kapat | Panelde "Mikrofon izni yok", ses düğmesi devre dışı; metin notu çalışır; onboarding açılmaz | PENDING (user) |
| Disk yazma / `screencapture` hatası | Uygulama açıkken `chmod a-w ~/Library/Application\ Support/Shotcue/captures`, `⌃⇧2` ile yakala; sonra `chmod u+w …/captures` | Bildirim ("Yakalama diske yazılamadı") + Ayarlar alt şeridinde hata; **task oluşmaz** | PENDING (user) — Not: depolama kökünü salt-okunur bir yola ayarlamak açılışta ölümcül uyarı verir ("Shotcue başlatılamadı — Depolama klasörü kullanılamıyor: …"), yakalama hatası değil; o da ayrıca kontrol edilebilir. |
| `claude` bulunamadı | Makinede `claude` hiç yokken çalıştır (yalnızca `/tmp/yok` yolu yetmez: özel yol çalıştırılabilir değilse varsayılan konumlara bakılır ve `~/.local/bin/claude` bulunur) | Açılış beklemez; Ayarlar > Claude'da önce "aranıyor…", ≤ 3 sn sonra kırmızı "bulunamadı — gönderme devre dışı", alt şeritte kırmızı `claude:` satırı. Kaydet ve gönder / Şimdi gönder / Ayrı ayrı gönder / bildirimden "Yeniden çalıştır" → "claude bulunamadı — Ayarlar > Claude'dan yolu ayarlayıp Shotcue'yu yeniden başlatın." hatası, **run satırı oluşmaz, RUN_FAILED banner'ı çıkmaz**; menüde "Kuyruğu şimdi çalıştır" hiçbir şey yapmaz; zamanlanmış task'lar `scheduled` kalır. Ayarlar > Claude > Yol değişince alt şerit "…yeniden başlatın (… / claude yolu)" der. (Gönder düğmeleri Plan 05'e ait olduğu için gri değil; red hatası gösterilir.) | kısmen (ajan): probe — sahte bir dispatcher üzerinde `claude` yokken `enqueue` tam bu Türkçe metinle `ClaudeMissingError` fırlattı, `runQueueNow` alttaki dispatcher'a hiç ulaşmadı, `cancel`/`setPaused`/`isPaused`/`liveEvents` iletildi; `claude` varken `enqueue` + `runQueueNow` iletildi; `services.dispatcher` = `ClaudeGatedDispatcher`; yol değişikliği uyarıyı gösterdi. PENDING (user / claude'suz makine): uçtan uca. |
| `error_max_turns` | Max tur = 1, bir task gönder | Run `failed`, otomatik yeniden denenmez, Inspector logunda "limit aşıldı (error_max_turns)" | PENDING (user) |
| Zaman aşımı | Zaman aşımı = 1 dk, uzun bir görev | Run `failed`, "Zaman aşımı. Çalışma durduruldu.", süreç SIGINT → SIGKILL | PENDING (user) |
| Proje klasörü yok | Proje yolunu var olmayan bir dizine değiştir | Run başlamaz, proje kırmızı | PENDING (user) |
| Whisper modeli yok | Model indirmeden sesli not | `transcript_state` `pending` kalır / hata → `failed`, ses saklanır, "tekrar dene" | PENDING (user) |

## Bildirim aksiyonları (spec §11 "bildirim aksiyonları")

| # | Kontrol | Beklenen | Sonuç |
|---|---|---|---|
| N1 | RUN_FAILED → "Yeniden çalıştır" | Ayarlar > Claude > Maksimum tur = 1, Ayarlar'ı kapat; projeli bir task gönder → run `failed` (`subtype = error_max_turns`), **RUN_FAILED** banner'ı **"Aç" / "Yeniden çalıştır"** aksiyonlarıyla çıkar → "Yeniden çalıştır"a bas → task `queued` → `running` ve o task'ın run sayısı **bir** artar: `select count(*) from run where task_id = (select id from task order by updated_at desc limit 1);` basmadan önce ve sonra. Ardından Maksimum tur'u eski değerine (50) geri al. | PENDING (user) |
| N2 | Uygulama öndeyken banner | Kütüphane penceresi öndeyken bir task gönder → run bitince banner **yine görünür** ve **Bildirim Merkezi'nde listelenir** (`willPresent` → `[.banner, .sound, .list]`). | PENDING (user) |
| N3 | "Aç" — kütüphane kapalıyken (P4'ün varyantı) | Kütüphane penceresi **kapalıyken** bir run bildirimine (gövdesine ya da "Aç"a) tıkla → kütüphane açılır, kenar çubuğu task'ın projesine (projesizse "Gelen") geçer, **task seçili** ve Inspector açık kalır (sonraki akış güncellemelerinde seçim düşmez). | kısmen (ajan): probe — kütüphane hiç açılmamışken `revealTask` 0,46 sn'de seçti; kapatılıp yeni bir task için tekrar: 0,23 sn; ikisi de 1,5 sn sonra hâlâ seçili, Inspector ve detay store'u o task'ta. Eski sıra (önce seç, sonra aç) aynı durumda seçimi düşürdü (`ids=0`) — düzeltmenin gerekçesi. Bildirime tıklama PENDING (user). |

## Ek kontroller — önceki plan incelemelerinden (hepsi kullanıcı adımı)

| # | Kontrol | Beklenen | Sonuç |
|---|---|---|---|
| E1 | Pano: tek pasteboard öğesi | Ayarlar > Genel > "Yakalamayı panoya da kopyala" açıkken yakala; Finder'a yapıştır → **dosya** kopyalanır; Mail ve Slack'e yapıştır → görsel **bir kez** eklenir (iki kez değil) | PENDING (user) |
| E2 | Mikrofon cihazı | Ayarlar > Ses > Giriş cihazı listesi cihazları gösterir; seçim sonrası şerit "yeniden başlatın" der (kaydedici açılışta kurulur), yeniden başlatınca kayıt o cihazdan; kayıt sürerken cihaz değişimi (kulaklık tak/çıkar) kaydı bozmaz ve not kaydedilir; başlatılamayan kayıttan sonra (ör. seçili cihaz çıkarılmış) hata görünür ve bir sonraki deneme çalışır | PENDING (user) |
| E3 | Gerçek CLI ile iptal ve limit | Çalışan run'da Inspector > İptal → run `cancelled` ("İptal edildi."); max tur = 1 → log "limit aşıldı" gösterir | PENDING (user) |
| E4 | ⌘C | Inspector'da odaklı yakalama önizlemesinde ⌘C görseli kopyalar; metin alanlarında ⌘C metni kopyalamaya devam eder | PENDING (user) |
| E5 | Kart ve hızlı panel yerleşimi | Geniş ekran görüntüsü kartın içinde kalır; hızlı panelin cam yüzeyi yuvarlak köşeli, arkasında kare çerçeve yok (panel penceresi şeffaf: `backgroundColor = .clear`, `isOpaque = false`) | PENDING (user) |
| E6 | Silme | Alt çubuk / bağlam menüsü / ⌫ → onay diyaloğu; "Sil" görselleri, sesleri ve logları da siler; "Vazgeç" hiçbir şey silmez | PENDING (user) |
| E7 | Inspector taslakları | Başlık/not düzenlemesi alan odağı kaybedince ve "Şimdi gönder"den önce kaydedilir (gönderilen prompt son metni içerir) | PENDING (user) |

## Plan 06'ya özgü ek kontroller

| # | Kontrol | Beklenen | Sonuç |
|---|---|---|---|
| P1 | Kısayol çakışması (R5) | Başka bir uygulamanın kullandığı bir kombinasyonu seç (ör. ⌥Space bir başlatıcıda kayıtlıysa) → alt şeritte kırmızı "Kısayol ⌥Space kaydedilemedi (başka bir uygulama kullanıyor). ⌃⇧2 kullanılmaya devam ediyor.", seçici ⌃⇧2'ye döner, ⌃⇧2 çalışır | PENDING (user) |
| P2 | Panel açıkken ikinci yakalama | İlk panele not yazılmışken (Esc'e basılmadan) ⌃⇧2 → tek panel (yeni yakalama); ilk task **notuyla birlikte projesiz inbox taslağı** olarak kaydedilir (başlık notun ilk cümlesi; panelde seçili proje onaylanmadığı için atanmaz). İlk panelde ses kaydı sürüyorsa o sesli not da kaydedilir (ilk task'ın `voice_note` satırı). Not boşsa ilk task'a hiçbir şey yazılmaz. | kısmen (ajan): probe (bellek içi DB, gerçek `QuickPanelController` + `QuickPanelStore`): panel "Probe" projesini varsaymışken not "İlk panelin notu. İkinci cümle" → ikinci yakalama sonrası `note` korunmuş, `title='İlk panelin notu'`, `project=nil`, `status=inbox`, `onClose` tetiklendi; boş notlu panel ve Esc ile kapatılan panel → satır hiç değişmedi. Ses kaydı ve gerçek ⌃⇧2 PENDING (user). |
| P3 | Menü ikonu vurgusu | Panel ⌘↩ / ⌘⇧↩ / Esc / Zamanla ile kapandıktan sonra menü ikonu ~1,2 sn onay işaretine döner (spec §5.1 adım 5) | kısmen (ajan): kapanışta `captureFlash=true` ölçüldü (V4); görsel PENDING (user) |
| P4 | Bildirim "Aç" — kütüphane açıkken | Kütüphane açık ve Inbox'ı ("Gelen") gösterirken bir projenin task'ının bildirimine tıkla → kenar çubuğu o projeye geçer, task seçili, Inspector açık. (Kütüphane kapalıyken varyantı: N3.) | PENDING (user) |
| P5 | Onboarding kırmızı düğme | Kapatınca Dock ikonu kaybolur, uygulama menü çubuğunda kalır | geçti (ajan, probe: `performClose` → `policy=1`, `UIElement`) |
| P6 | Tanılama şeridi | "claude: 2.1.278 (Claude Code)", "Girişte başlat: …", "Apple Intelligence (Foundation Models): …" satırları; hata varsa kırmızı | PENDING (user) — ajan: rapor içeriği ölçüldü (V13) |
| P7 | Terminalde devam et / Desktop'ta aç — oturum id'si | Bildirimden "Terminalde devam et", Inspector'dan "Terminalde devam et" ve "Desktop'ta aç": üçü de `claude --resume <küçük harfli id>` / `claude://code/resume?session=<küçük harfli id>` ile run'ın `--session-id`'siyle aynı yazımı kullanır ve oturumu açar. **Yaz:** terminal `$HOME`'da açılır (`.command` proje klasörüne `cd` etmez) — `--resume` oturumu oradan buluyor mu, yoksa "No conversation found" mı? | kısmen (ajan): probe — gerçek `TaskDetailStore` (bellek içi DB) `A4CEE351-…` üretti, `ClaudeHandoff` alttaki servise Terminal ve Desktop için `a4cee351-…` iletti; bildirim yolunun `uuidString`'i de küçültüldü; composer argümanları değişmeden geçti; `services.handoff` = `ClaudeHandoff`. Gerçek resume PENDING (user). |
| P8 | İkon 32 px'te | Finder liste görünümünde / küçük Dock boyutunda Shotcue ikonu: mavi-mor plaka, beyaz köşe ayraçları ve ortadaki amber nokta seçilebiliyor, bulanık bir lekeye dönmüyor | kısmen (ajan): `sips -z 32 32 Resources/AppIcon.icns` çıktısı büyütülerek incelendi — ayraçlar ve nokta ayrı ayrı seçiliyor (Task 8); Finder/Dock'ta bakış PENDING (user) |
| P9 | `claude` araması açılışı bekletmez | `claude` yalnızca login shell PATH'inde (ör. npm-global, nvm) kuruluysa: uygulama hemen açılır, Ayarlar > Claude sürüm satırı önce "aranıyor…", sonra sürümü gösterir | kısmen (ajan): probe — sabit konum kontrolü ana iş parçacığında 50 µs; login shell yolu zorlanınca (`candidates: []`) `init` 14 µs'de döndü, arama arka planda 0,12 sn'de `~/.local/bin/claude`'u buldu; `sleep 10` kabuğu 3,00 sn zaman aşımında "bulunamadı" oldu ve ertelenmiş runner `notFound` fırlattı; bu sürede ana iş parçacığı 20 ms'lik 141 tik attı (bloke olmadı). "aranıyor…" etiketi PENDING (user, uygun kurulum) |

## Son düzeltme dalgası (tüm dal incelemesi, C1 · I1–I6 · M1–M9)

Kod testleri ajan tarafından koşuldu; aşağıdaki satırlar gerçek uygulamada kullanıcının göreceği davranışı kontrol eder.

| # | Kontrol | Beklenen | Sonuç |
|---|---|---|---|
| F1 | Sesli not bekleyen gönderim — model **hazır** (C1) | Hızlı panelde kayıt yap, durdur ve hemen ⌘⇧↩ → panel **hemen kapanır**, run transkript bitince başlar (`select started_at from run order by started_at desc limit 1;` notun transkripti bittikten sonra); "Terminalde devam et" ile açılan oturumun ilk kullanıcı mesajında `VOICE NOTE` bloğu ve transkript görünür. Inspector'dan "Şimdi gönder" / "Yeniden çalıştır" → başlıkta "Sesli not yazıya dökülüyor…" + gönder düğmeleri pasif, bitince `queued`. Kütüphane "Ayrı ayrı gönder" / "Tek görev olarak gönder" → alt çubukta "Sesli not yazıya dökülüyor…" kapsülü. | PENDING (user) |
| F2 | Sesli not bekleyen gönderim — model **yok** (C1) | Model indirilmemişken sesli notlu bir görevi ⌘⇧↩ / Şimdi gönder / Ayrı ayrı gönder ile gönder → gönderilmez; Türkçe hata "…transkripsiyon modeli indirilmedi. Ayarlar > Ses'ten modeli indir…"; hızlı panel **açık kalır**; `select count(*) from run;` değişmez. Transkripti başarısız olmuş (ve elle yazılmamış) notlu görev → "Sesli not yazıya dökülemedi… transkripti elle yaz ya da Yeniden çevir'e bas" hatası. | PENDING (user) |

## Tamamlanma ölçütleri (ajanın koşturduğu)

- `make build` → `Build complete!` (derleyici uyarısı yok); `make test` → 404 test geçti (145 + 44 + 49 + 63 + 80 + 23;
  Plan 07 birleşimiyle; birleşimden önce 378).
- `grep -rn "@State \|#Preview\|activate(ignoringOtherApps" Sources/ShotcueApp | wc -l` → `0`.
- `Sources/ShotcueApp/` içinde 17 dosya: planın 15 dosyası (`UIState.swift` yerine `AppLog.swift`: typealias zaten
  `ShotcueUI`'da public) + düzeltme turu 1'in `ClaudeExecutableLocator.swift` ve `ClaudeGatedDispatcher.swift`'i.
- Bu dal yalnızca planın dosyalarını değiştirdi. Plan 07 birleşiminden sonra `367e7eb..HEAD` farkı birleşen modül
  dosyalarını da içerdiği için ölçüt iki biçimde koşuldu:
  `git diff --name-only 2da522c HEAD | grep -vE '^(Sources/ShotcueApp/|Resources/AppIcon.icns|scripts/(make-icon.sh|render-icon.swift)|docs/)' | wc -l` → `0`
  ve dalın kendi commit'leri (`git log --first-parent --no-merges --name-only 367e7eb..HEAD`) için aynı filtre → `0`.
- `Resources/AppIcon.icns`: 364K, `file` → `Mac OS X icon, 371813 bytes, "ic12" type`; kurulu bundle'da birebir aynı
  (`cmp`), `NSWorkspace.icon(forFile:)` yeni ikonu döndürüyor.
- Tanılama raporunda e-posta/org yok (V13).
- Açık: `Authority=Shotcue Dev` (V1, `make cert`), Spec §5 akışlarının gerçek `claude` ile uçtan uca koşusu (V3–V11) —
  kullanıcı adımları.

## Ajanın tanılama çıktısı (ad-hoc imzalı build, 2026-09-23 00:38)

```
Shotcue tanılama — 2026-09-23T00:38:36+03:00
app: /Users/egekibar/Applications/Shotcue.app
sürüm: 0.1.0 (1)
imza: CodeDirectory v=20500 size=39856 flags=0x10002(adhoc,runtime) hashes=1235+7 location=embedded
claude yolu: /Users/egekibar/.local/bin/claude
claude ayarı: (otomatik)
claude sürümü: 2.1.278 (Claude Code)
claude auth: loggedIn=true authMethod=claude.ai subscriptionType=max
izinler: ekran kaydı=notDetermined mikrofon=notDetermined bildirimler=notDetermined
girişte başlat: kullanılamıyor (uygulama ~/Applications'a kurulmalı)
kısayol: ⌃⇧2
depolama kökü: /Users/egekibar/Library/Application Support/Shotcue
veritabanı: 4 KB
boş disk alanı: 9,44 GB
transkripsiyon modeli: indirilmedi (openai_whisper-large-v3-v20240930_turbo)
Foundation Models: Apple Intelligence kapalı
```

(`girişte başlat` metni bu ölçümden sonra düzeltildi: `.notFound` artık "~/Applications'a imzalı kurulum gerekir: make
cert + make install" diyor.) `claude auth` satırı spike S1'in kalıcı kanıtıdır: bundle'dan başlatılan `claude`
aboneliğin oturumunu görüyor.

## Notlar

- **Sözleşme uzlaştırması A1 / A13 / A17 kapandı.** A1: `grep -rn "@State " Sources/ShotcueUI` → boş; `UIState` typealias'ı
  `ShotcueUI`'da public. A13: `SettingsView(projects: [Project])` birleşmiş kodda aynen böyle. A17: birleşmiş imzalar
  `OnboardingView(permissions:onDone:)`, `MenuBarView(store:openLibrary:openSettings:quit:)`,
  `LibraryView(store:thumbnails:)`, `QuickPanelView(store:thumbnails:)`, `SettingsView(…, claudeVersion: String?, …,
  inputDevices:)`; App çağrıları bunlara uyarlandı, tek bir paylaşımlı `ThumbnailCache` geçiliyor.
- **Login item:** ad-hoc imzalı build `~/Applications`'tan çalışırken de `SMAppService.mainApp.status == .notFound`
  (ölçüldü). "Shotcue Dev" imzasıyla `.notRegistered` olup olmadığı V13'te kontrol edilecek.
- **Relaunch:** `/usr/bin/open` ortam değişkenlerini yeni örneğe aktarıyor (ölçüldü); relaunch `SHOTCUE_*`
  değişkenlerini temizler, yeni örnek eski süreç bittikten sonra açılır (kısayol çakışması yok).
- **Kütüphane penceresinin başlığı** kenar çubuğu seçimini gösterir ("Gelen", proje adı …), "Kütüphane" değil:
  Plan 05'in `navigationTitle`'ı sahne başlığının yerini alıyor. Pencere kimliği `library`.
- **`NSApp.isActive`** hızlı panel key iken `true` okunuyor (2026-09-22 spike'ı `false` ölçmüştü); öndeki uygulama
  (`NSWorkspace.frontmostApplication`) ve Dock durumu değişmiyor. V4'te TextEdit başlık çubuğu gözlemi bunu kesinleştirir.
- **Menü çubuğu ikonu** ajan tarafından görülemiyor: macOS 26'da üçüncü taraf durum öğeleri Ekran Kaydı izni olmadan
  pencere listesinde yer almıyor. Dolaylı kanıt: `SHOTCUE_OPEN_LIBRARY=1` kütüphaneyi açıyor, yani `MenuBarExtra`
  etiketi `openWindow` eylemini `applicationDidFinishLaunching`'den önce bağlıyor.
- Bildirim izni ajan tarafından istenmedi: açılışta onboarding gösterildiği sürece ayrı bir bildirim istemi çıkmaz
  (onboarding'in kendi "Bildirimler" satırı var); onboarding gerekmiyorsa açılışta bir kez sorulur.
- **Bilinen açık — bildirimde maliyet yok:** "done" bildirimi başlık + sonucun ilk satırını taşır; Core
  `AppNotification`'da maliyet alanı olmadığı için maliyet bildirimde gösterilemez (V6). Kapatmak Core + Plan 04
  değişikliği gerektirir; bu planın kapsamı dışında.
- **`claude` yokken gönder düğmeleri** (spec §8 "devre dışı") Plan 05'in görünümlerinde olduğu için gri yapılamıyor;
  bunun yerine her gönderim yolu ortak dispatcher'da açık bir hatayla reddediliyor (V14). Gerçek devre dışı bırakma
  için Plan 05'e bir "gönderilebilir mi" girdisi gerekir.
- **Terminalde devam et** `.command` dosyası proje klasörüne `cd` etmeden `claude --resume <id>` çalıştırır; Claude Code
  oturumları proje klasörüne göre sakladığı için `$HOME`'dan bulunamayabilir (V6, V11, P7'de gözlenecek). Bulgu
  olumsuzsa düzeltme Plan 04'ün `DesktopHandoffService.commandFileContents`'ındadır.
