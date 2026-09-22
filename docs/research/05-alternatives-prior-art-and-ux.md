# 05 — Stack Alternatifleri, Prior Art ve UX Tasarımı

> Araştırma tarihi: **2026-09-22** · Kapsam: (A) bu uygulamaya özel stack karşılaştırması, (B) rakip/prior art UX analizi, (C) ekran & akış tasarımı + SwiftUI component eşlemesi.
> Kapsam dışı (başka ajanlar işliyor): derin native Swift detayları, capture API'lerinin iç işleyişi, voice pipeline detayı, Claude entegrasyonunun protokol seviyesi.

---

## TL;DR

- **Öneri: native Swift 6 + SwiftUI (macOS 26 target).** Bu uygulamanın en zor 4 özelliği — çok ekranlı region overlay, non-activating floating panel, on-device speech-to-text, TCC izinleri — tam olarak cross-platform stack'lerin en zayıf olduğu yerler. Mac-only bir üründe cross-platform vergisi karşılığında hiçbir şey satın almıyoruz.
- **Bu makinede native yol bugün çalışıyor — doğruladım.** Xcode olmadan, sadece Command Line Tools ile `MenuBarExtra` + `.menuBarExtraStyle(.window)` + `Settings` scene + `.glassEffect()` + `ScreenCaptureKit` içeren bir SwiftUI app'i Swift 6 language mode'da temiz derledi (cold build 38 sn).
- **Kritik mimari kural: logic'i saf Swift library target'ına koy, SwiftUI'ı ince tut.** Ölçtüm: SwiftUI app target'ının incremental rebuild'i **~31 sn**, saf logic library + `swift test` (Swift Testing) ise **~6 sn**. Ajanın feedback loop'u bu farkta yaşıyor veya ölüyor.
- **Xcode'suzluğun iki gerçek bedeli var:** `xcodebuild` ve `actool` CLT'de shim ve hata veriyor → **asset catalog (.xcassets) derlenemiyor** (çözüm: SF Symbols + `iconutil` ile `.icns`) ve **SwiftUI Preview / Instruments yok**. `codesign`, `plutil`, `sips`, `iconutil`, Swift Testing hepsi mevcut.
- **Tauri 2.11'in (stable 2.11.6, ayrıca 3.0.0-alpha yolda) asıl sorunu Rust değil, macOS'a özel iki eksik:** hazır bir region-capture yok (transparent overlay'i ekran başına elle yazmak gerekiyor, scaled display koordinat hataları bilinen bir dert) ve non-activating panel üçüncü parti `tauri-nspanel`'e bağlı — ki onun **macOS 27'de panel'in pencere gibi focus aldığına dair açık issue'su var**.
- **Electron 44 (44.3.0, 9 Eyl 2026) en hızlı başlangıç ama en pahalı son:** 120–200 MB bundle, 150–300 MB idle RAM ve helper process'ler yüzünden en kötü TCC sürtünmesi. Üstelik ürünün tek farklılaştırıcısı olan "native cila" burada mümkün değil.
- **Flutter / Compose Multiplatform bu iş için eleniyor:** bu makinede ne Flutter SDK ne JDK+Gradle var, on-device Apple STT için yine native köprü yazmak gerekiyor ve AI ajanların en az verimli olduğu ekosistemler bunlar.
- **Hybrid (Swift shell + `WebView`/`WebPage`) gerçek bir B planı:** capture overlay, panel ve hotkey native kalır, sadece library/board penceresi web olur. macOS 26'da `WebView` artık native SwiftUI view'ı. Ama plan A olarak başlatma — bir ekranı web yapmak iki runtime bakımı demek.
- **Prior art'ta en büyük boşluk net: capture ile dispatch hiçbir üründe aynı hareket değil.** Ekran-farkında araçların hepsi (Raycast Screen Awareness, ChatGPT Appshots, Highlight AI) bir **chat**'te bitiyor; ajan koşturucuların hepsi (Codex, Cursor, Linear coding sessions, Warp) bir **issue/prompt**'tan başlıyor. Ekran görüntüsünü repo scope'u ile birlikte kalıcı bir ajan kuyruğuna alan doğrulanmış bir ürün yok.
- **Tasker'ın savunulabilir dört farkı:** (1) yakalama anında sesli not, (2) kalıcı capture inbox'ı, (3) toplu/zamanlanmış dispatch, (4) proje/repo scope'unun capture'a yapışması. Bunların dördü de bugün boşta.

---

## Bölüm A — Stack Alternatifleri

### A.0 Bu makinede doğrulanan gerçekler (varsayım değil, ölçüm)

| Kontrol | Sonuç |
|---|---|
| Swift | 6.4 (`swiftlang-6.4.0.34.1`), target `arm64-apple-macosx26.0` |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` (Xcode yok) |
| SDK'lar | `MacOSX26.sdk`, `MacOSX26.5.sdk`, **`MacOSX27.sdk`** |
| `xcodebuild` / `actool` | ❌ shim, "requires Xcode" hatası → **.xcassets derlenemez** |
| `iconutil` / `plutil` / `sips` / `codesign` | ✅ çalışıyor → `.icns` + `Info.plist` + imzalama mümkün |
| Swift Testing | ✅ `Testing.framework` CLT içinde; `swift test` koştu, geçti |
| SDK framework'leri | `ScreenCaptureKit`, `Speech`, `SwiftUI`, `AVFoundation`, `AppKit` ✅ |
| **SwiftUI smoke build** | `MenuBarExtra` + `.menuBarExtraStyle(.window)` + `Settings` + `.glassEffect()` + `import ScreenCaptureKit` → **Build complete, 38.38 sn** |
| Incremental rebuild (SwiftUI app target) | **~31.5 sn** |
| Saf logic library + `swift test` | **build 4.0 sn / toplam 6.4 sn** |
| Rust / cargo | ❌ kurulu değil |
| Node / Bun | ✅ v22.23.2 / 1.4.2 |

Ek bağlam: makine **macOS 26.6.2 (Tahoe)**, ama **macOS 27 "Golden Gate" 14 Eylül 2026'da çıktı** ve CLT zaten `MacOSX27.sdk` taşıyor. Yani deployment target `macOS 26` seçmek hem `glassEffect`'i hem de `SpeechAnalyzer`'ı garantiye alır, hem de kullanıcı tabanının tamamını kapsar.

### A.1 Skor matrisi (1–5, yüksek = iyi)

| Kriter | Swift 6 + SwiftUI | Tauri 2.11 | Electron 44 | Flutter / Compose MP | Hybrid (Swift + WebView) |
|---|---|---|---|---|---|
| (a) Çok ekranlı region overlay | **5** | 3 | 3 | 2 | **5** |
| (b) Global hotkey | **5** | 4 | 4 | 3 | **5** |
| (c) Menu bar + non-activating panel | **5** | 3 | 3 | 3 | **5** |
| (d) Mikrofon + on-device STT | **5** | 2 | 2 | 2 | **5** |
| (e) `claude` CLI subprocess + streaming | 4 | 4 | **5** | 3 | 4 |
| (f) TCC izin sürtünmesi | **5** | 3 | 2 | 3 | **5** |
| (g) Binary boyutu + idle RAM | **5** | **5** | 2 | 3 | 4 |
| (h) Bu makinede toolchain kurulumu | 4 | 2 | **5** | 1 | 4 |
| (i) AI ajan verimliliği | 4 | 3 | **5** | 2 | **5** |
| (j) UI cila tavanı (Liquid Glass / native) | **5** | 3 | 2 | 2 | 4 |
| **Toplam (50 üzerinden)** | **47** | 32 | 33 | 24 | **46** |

### A.2 Gerekçeler

**1) Native Swift 6 + SwiftUI.** Region overlay için ekran başına borderless `NSWindow` + `ScreenCaptureKit`; hotkey için Carbon `RegisterEventHotKey` (Accessibility izni bile istemez); panel için `NSPanel` + `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` + `.floating` + `NSHostingView`; STT için macOS 26'nın `SpeechAnalyzer` / `SpeechTranscriber`'ı — tamamen cihaz üstü, ağ yok, ekstra model indirme yok, sıfır bağımlılık. `claude` CLI'ı için `swiftlang/swift-subprocess` 1.0, `AsyncBufferSequence.LineSequence` ile satır satır streaming veriyor. TCC tarafında tek bundle + tek Developer ID imzası = tek prompt. Tek tek her kutucuğu işaretliyor.
**Dürüst maliyet:** geliştirici Swift bilmiyor, Xcode yok (preview/Instruments yok), SwiftUI app target'ı her dokunuşta ~30 sn derleniyor.

**2) Tauri 2.11.** Rust core + native WebView; 3–10 MB bundle, 30–50 MB idle RAM — boyut/RAM tarafında kusursuz. `tauri-plugin-global-shortcut` resmi ve macOS'ta çalışıyor. Ama `tauri-plugin-screenshots` sadece **pencere ve monitör** yakalıyor — region yok. Region'ı monitör başına transparent overlay pencereyle kendin yazacaksın ve sahadaki bug raporları scaled display'lerde overlay'in yanlış boyutlanıp crop'un kullanıcının seçimiyle uyuşmadığını gösteriyor. Non-activating panel `ahkohd/tauri-nspanel`'e bağlı; o repo'da **"In macOS 27 the panel focuses like a window"** başlıklı açık bir issue var — yani ürünün en kritik yüzeyi, kontrol edemediğin bir third-party'nin OS upgrade'e yetişmesine bağlı. On-device Apple STT için Rust'tan objc2 köprüsü yazmak gerekir; alternatifi 100 MB+ Whisper modeli paketlemek. Ve geliştirici Rust'ı ne yazabilir ne review edebilir — ajanın en çok denetime ihtiyaç duyduğu yerde denetim sıfır.

**3) Electron 44** (son stable major; 44.3.0 / 9 Eyl 2026, Electron 45 → 20 Eki 2026). Başlangıç sürtünmesi sıfır: Node 22 + Bun zaten kurulu, `child_process` ile `claude` CLI streaming'i geliştiricinin zaten bildiği şey, ekosistem dokümantasyonu ve ajan eğitim verisi en zengin burada. Karşılığında: `desktopCapturer` region API'si sunmuyor, çok ekranlı marquee seçimi için "tek state, N view" mimarisini elle kurmak gerekiyor; `globalShortcut` tarihsel olarak `NSEvent` tabanlı olduğu için bazı accelerator'lar Accessibility izni istiyor; TCC en kötü burada (dev binary Screen Recording listesinde hiç görünmüyor, `Info.plist`'i imzayı yenilemeden yamalamak tüm child process izinlerini sessizce düşürüyor). Ve asıl mesele: 150–300 MB idle RAM'li bir menu-bar app'i, CleanShot X'in yanında duracak bir ürün değil.

**4) Flutter desktop / Compose Multiplatform.** Flutter macOS hedefi olgun (native menu bar, tray, Mac App Store) ve Compose tarafında `compose-macos-26-ui` 1.0.0 macOS 26 görünümünü taklit ediyor — ama anahtar kelime "taklit". Traffic light'lar, köşe yarıçapı ve sidebar glass materyali native yüzeyler; Compose bunları kendi çizemiyor, Nucleus/Tao köprüsüyle sarmalıyor. Buna ek olarak: bu makinede ne Flutter SDK ne JDK+Gradle var, on-device STT için yine native köprü, ve AI ajanların Dart/Kotlin-desktop'ta üretkenliği listenin en düşüğü. Bu uygulama için eleniyor.

**5) Hybrid: Swift shell + web library UI.** macOS 26 ile WebKit artık SwiftUI-native: `WebView` + `WebPage` (`Observable`) tipleri var, `NSViewRepresentable` köprüsü gerekmiyor. Capture overlay, `NSPanel`, hotkey, STT, subprocess tamamen native kalır; sadece board/library penceresi React+TS olur — geliştiricinin gerçekten review edebildiği tek kod. Skoru neredeyse saf native kadar yüksek. Plan A yapmama sebebim: iki build sistemi, iki state modeli ve `Transferable` tabanlı native drag&drop ile web drag&drop arasında bir köprü daha demek. **Bunu bir escape hatch olarak sakla:** SwiftUI board'u 2 hafta içinde kanamaya başlarsa, sadece o pencereyi web'e çevir.

### A.3 Karar ve gerekçe

> **Native Swift 6 + SwiftUI, deployment target macOS 26.** Hybrid (`WebView` ile library penceresi) açık B planı olarak kalır.

Mantık üç adımda:

1. **Bu uygulama %70 "OS entegrasyonu", %30 "CRUD UI".** Region overlay, non-activating panel, global hotkey, on-device STT, TCC, subprocess — bunların hepsi OS tarafı. Cross-platform stack'ler bu altı kalemin beşinde ya native köprü yazdırıyor ya da third-party plugin'e bağlıyor. Yani "web bildiğim için Tauri/Electron" argümanı, işin zor %70'inde geçersiz.
2. **Cross-platform vergisi karşılıksız.** Ürün Mac-only. `ScreenCaptureKit`, `SpeechAnalyzer`, Liquid Glass, `MenuBarExtra` — bunların Windows/Linux karşılığı yok zaten. Taşınabilirlik için ödeme yapıp taşınmıyoruz.
3. **Öğrenme eğrisi argümanı, kodu ajan yazdığında tersine dönüyor.** Yaygın olarak atıf alan bir vaka raporunda ("I Shipped a macOS App Built Entirely by Claude Code") 20.000 satırlık bir macOS app'in ~%95'i Claude Code tarafından yazılmış, geliştirici elle 1.000 satırın altında kod yazmış. Aynı raporun dürüst uyarıları da bizim için yol haritası: ajanlar modern SwiftUI yerine eski AppKit API'lerine kayıyor, Swift Concurrency'de zorlanıyor ve **uygulamayı kullanıcı gibi kullanamadığı için feedback loop'u kendi kapatamıyor**.

**Riskler ve mitigasyonlar:**

| Risk | Mitigasyon |
|---|---|
| Geliştirici Swift'i review edemiyor | Logic'i `AppCore` adlı saf Swift library target'ına topla, Swift Testing ile %100 ölçülebilir hale getir (6 sn loop). SwiftUI view'lar "dumb" kalsın. Review, testlerin okunmasıyla yapılır. |
| Ajan eski AppKit/deprecated API'ye kayıyor | `twostraws/SwiftUI-Agent-Skill` (`swiftui-pro`) plugin'ini kur; `CLAUDE.md`'ye açık bir **yasak API listesi** yaz (`NSHostingController` yerine ne, `SFSpeechRecognizer` yerine `SpeechTranscriber`, `CGWindowListCreateImage` yerine `ScreenCaptureKit`). |
| Ajan uygulamayı çalıştırıp göremiyor | `make run` + `make shot` script'i: build → `.app` bundle → launch → `screencapture` ile pencere görüntüsü al → ajana geri ver. Feedback loop'u kapatan tek şey bu. |
| SwiftUI app target rebuild'i ~30 sn | Görsel olmayan her şeyi `AppCore`'a taşı; ajan iterasyonlarının çoğu `swift test` ile 6 sn'de dönsün. |
| Xcode yok → .xcassets yok | App icon için `iconutil` ile `.icns`; UI ikonları için SF Symbols (asset catalog gerektirmez). Xcode 27 sonradan kurulabilir, mimariyi değiştirmez. |
| macOS 27 uyumu | Deployment target `macOS 26` kalsın, ama CI/manuel testi `MacOSX27.sdk` ile de derleyerek yap — SDK zaten makinede. |

---

## Bölüm B — Prior Art

Aşağıdakilerin hepsi Eylül 2026 itibarıyla **canlı doğrulandı** (Glass/Pickle hariç — bkz. not).

| Ürün | Ödünç alınacak fikir | URL |
|---|---|---|
| **CleanShot X 5.0** | Post-capture **floating thumbnail + quick actions** kalıbının kanonik hali: yakalama sessizce Desktop'a düşmez, üstünde durur ve oradan annotate/pin/upload/drag-out yapılır. Ayrıca "capture history" ayrı bir birinci sınıf komut. | https://cleanshot.com |
| **Shottr 1.9.2** | **"Repeat area screenshot"** — aynı dikdörtgeni tek tuşla yeniden yakala. Bir bug'ın before/after'ı için birebir bizim senaryomuz. Ayrıca pin-as-always-on-top. | https://shottr.cc |
| **Xnapper** | **Otomatik hassas veri redaksiyonu** — e-posta, kredi kartı, IP, API key'leri sorulmadan bulanıklaştırıyor. Ekran görüntüsünü bir AI ajanına yollayan bir üründe bu bir güvenlik özelliği, kozmetik değil. | https://xnapper.com |
| **ScreenFloat** | **Shots Browser**: tag, collection, klasör, favori + Spotlight. Ayrıca bir shot'ı **belirli bir uygulamaya/Space'e sabitleme** — "proje scope'u" fikrinin görsel atası. | https://eternalstorms.at/screenfloat/ |
| **Zight** | Yakalamaların **MCP server üzerinden** Claude/Cursor tarafından okunabilir olması; ve "Collections" ile gruplama. | https://zight.com |
| **Dropshare** | **"Bring your own backend"** (36+ hedef: S3, SFTP, WebDAV…) — proprietary cloud'a mahkûm etmeme. Bizde: storage location ayarı. | https://dropshare.app |
| **Snipaste 2.11.3** | Pin'lenen pencerenin **yarı saydam ve click-through** yapılabilmesi; ve capture UI'ının içinde **history playback**. | https://www.snipaste.com |
| **Flameshot 14** | Seçim alanının kenarında beliren **radial/in-canvas toolbar** — araçlar imlecin yanında, üst chrome'da değil. | https://flameshot.org |
| **macOS Screenshot (⌘⇧5)** | Taban çizgisi: tek kompakt toolbar'da 5 mod, timer, hatırlanan hedef, ve sağ-alt **swipe-away edilebilir thumbnail**. ⚠️ macOS 26'da HDR ekranlarda varsayılan HEIC'e döndü ve yapıştırmayı bozuyor — **biz PNG default verelim.** | https://support.apple.com/en-us/122868 |
| **Raycast Screen Awareness** | En iyi tasarlanmış capture UX'i: **çift-tap sağ ⌘** ile tetikleme; yakalama bir resim değil bir **bundle** (app adı, pencere başlığı, accessibility metni, seçim, screenshot, tarayıcı sekmesi); ve **attachment card** — hangi veri kaynaklarının dahil edildiğini gösteren tıklanabilir çip. | https://manual.raycast.com/ai/screen-awareness |
| **Jam.dev** | **Sıfır-prompt teknik bağlam**: tek tıkla console log, network isteği, user event, cihaz/tarayıcı metadata otomatik iliştirilir. Kullanıcıya "ne yapıyordun?" diye sorulmaz. | https://jam.dev |
| **BugHerd / Marker.io** | Geri bildirimin **sayfadaki gerçek elemana sticky-note gibi çakılması** (prose ile tarif edilmesi değil) ve raporlayan → **Kanban board** hattı. Marker'da ayrıca rapora iliştirilen **session replay**. | https://bugherd.com · https://marker.io |
| **Apple Quick Note** | **Hot-corner** ile sıfır-chrome yakalama ve en az kopyalanan fikir: bir sayfaya geri döndüğünde ilgili notun **köşede thumbnail olarak yeniden belirmesi** (bağlamsal resurfacing). | https://support.apple.com/guide/notes/apdf028f7034/mac |
| **ChatGPT Appshots** (macOS) | **Çift modifier chord** (iki ⌘'ya birden basmak) — hiçbir kısayolla çakışmaz, mod yok. Yakalama piksel değil **görüntü + pencerenin görünür alan dışındaki metni**. Ve "son 60 saniyede dokunduğun sohbete iliştir" heuristiği. | https://learn.chatgpt.com/docs/appshots |
| **Codex app / Cursor 3** | **Review queue / Agents Window**: biten iş bir kuyruğa düşer, her ajan kendi git worktree'sinde izole; Cursor'ın cloud ajanları işlerinin **demo ve screenshot'ını üretip** doğrulamana sunuyor. | https://cursor.com |
| **Devin Desktop** (eski Windsurf) | **Running / Waiting for review / Done** sütunlu Kanban — piyasadaki gerçek "ajan görev inbox"una en yakın şey. | https://devin.ai/desktop |
| **Warp (Oz / Factories)** | Girişlerin **çoğul ve dışsal** olması (Slack, Linear, GitHub, CLI, schedule aynı ajanı başlatır) ve ajanın **onay gerektiğinde bildirim atması**. | https://www.warp.dev |
| **Linear coding sessions** | Issue'yu ajana atama; sonucun issue içinde **diff + PR preview** olarak dönmesi; ve oturumların **screenshot/recording "verification artifact"** üretmesi. ⚠️ Linear'ın native screenshot→issue capture'ı **yok**; bunu üçüncü partiler dolduruyor. | https://linear.app/changelog/2026-06-11-coding-sessions |
| **Highlight AI** | Tek hotkey → ekran bağlamı **zaten çözülmüş** bir prompt bar (attach adımı yok) ve **capture exclusion list** (şifre/sağlık/finans ekranları yakalanmaz) — gizlilik, policy sayfası değil capture-time filtresi. | https://highlightai.com |
| **Screen Studio** | **Niyeti input event'lerinden çıkarmak** (tıklama/tuş vuruşlarına göre otomatik zoom) — kullanıcıya "önemli anı işaretle" dedirtmemek. Ve on-device transkripsiyonun upsell değil varsayılan olması. | https://screen.studio |

> Not: **Glass / Pickle** (github.com/pickle-com/glass) repo olarak duruyor ama kaynaklar canlılığı konusunda çelişiyor (son gerçek feature çalışması 2025 ortası gibi görünüyor). Üstüne inşa edilmemeli. **Cluely** hayatta ama toplantı asistanına daralmış durumda.

### Tasker'ın farkı

Prior art taramasının en net sonucu: **capture ile dispatch hiçbir üründe aynı hareket değil.** Ekran-farkında araçların hepsi bir sohbette bitiyor; ajan koşturucuların hepsi bir issue/prompt'tan başlıyor. Doğrulanmış hiçbir ürün "ekran görüntüsü → kalıcı kuyruk → repo scope'lu coding agent" hattını kurmuyor.

Tasker'ın sahiplenebileceği dört şey:

1. **Yakalama anında sesli not.** Highlight ve ChatGPT'de iyi voice input var, ajan koşturucularda (Warp, Cursor, Linear) pratikte yok. "Tuşu basılı tut, bug'ı göster, ne olduğunu söyle" uçtan uca hiçbir yerde yok. `SpeechTranscriber` ile bu bizde sıfır maliyetli ve cihaz üstünde.
2. **Kalıcı capture inbox'ı.** Raycast yakalamayı bilinçli olarak atıyor; Codex'in kuyruğu **biten** işi tutuyor, **bekleyen** işi tutan bir yüzey yok. "Bugün altı şey gördüm, akşam triyaj ederim" diyebileceğin bir yer yok.
3. **Toplu ve zamanlanmış dispatch.** Codex Automations ve Cursor Subscriptions **tekrar eden** görevleri zamanlıyor; ad-hoc yakalamaları biriktirip tek repo'ya tek batch olarak, seçtiğin saatte ateşleyen bir şey yok.
4. **Proje/repo scope'unun capture'a yapışması.** Bozuk bir UI'ın screenshot'ı hangi repo/branch/worktree'ye ait olduğuna dair sinyal taşımıyor; her araç bunu insana tekrar söyletiyor. Bizde grup = proje dizini, yani routing yakalama anında çözülüyor.

---

## Bölüm C — Ekranlar, Akışlar ve Component Eşlemesi

### C.1 Capture flow (hotkey → overlay → post-capture panel)

Akış, klavye-öncelikli: `⌘⇧2` (ya da Appshots'tan ödünç: **çift-tap sağ ⌘**) → tüm ekranlara borderless overlay → sürükle/`Space` ile pencere seç → bırak → post-capture panel imlecin yakınında açılır ve **odak doğrudan not alanındadır**.

```
┌──────────────────────────────────────────────────────────┐
│  ▣ Tasker · Yeni yakalama                     ⌘⏎ Gönder  │
├──────────────────────────────────────────────────────────┤
│  ┌────────────────────────┐  Proje  ▼ [ acme-web      ]  │
│  │                        │  Grup   ▼ [ Checkout bug  ]  │
│  │   [ screenshot 16:10 ] │  Mod      (•) analyze ( ) impl│
│  │                        │                              │
│  └────────────────────────┘  ⌥1 Aynı alanı tekrar çek    │
│   🔒 2 hassas alan gizlendi   ⌥2 Anotasyon               │
├──────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────┐│
│  │ Not yaz…                                    (odakta) ││
│  └──────────────────────────────────────────────────────┘│
│  ▁▃▅▇▅▃▁ 0:04  "butonun hitbox'ı 4px kayıyor…"           │
│  [◉ Basılı tut: Space]              on-device transcript │
├──────────────────────────────────────────────────────────┤
│  ESC Vazgeç   ⌘S Kaydet   ⌘⏎ Kaydet & şimdi gönder       │
└──────────────────────────────────────────────────────────┘
```

**Component eşlemesi:** Menu bar girişi `MenuBarExtra("Tasker", systemImage:)` + `.menuBarExtraStyle(.window)`. Overlay: ekran başına `NSScreen` üstünde borderless `NSWindow`, `.screenSaver` level, içerik `NSHostingView` — `NSApplication`'ı aktive etmeden. Post-capture panel: `NSPanel` + `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded = true` + `.floating` + `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, içeride SwiftUI. Uygulama `LSUIElement = true` (Dock'ta görünmez). Kısayollar `.keyboardShortcut(.return, modifiers: .command)` / `.cancelAction`. Panel yüzeyi `.glassEffect()`, aksiyon butonları `.buttonStyle(.glass)` — birincil aksiyon `.glassProminent`, hepsi bir `GlassEffectContainer` içinde. Ses: `AVAudioEngine` + `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26, on-device). Xnapper'dan ödünç alınan redaksiyon uyarısı panelin görsel altında bir satır olarak durur.

### C.2 Library / board penceresi

**Seçenek 1 — Sidebar-groups + grid.** Sol sidebar: projeler, gruplar, durumlar (saved search gibi); sağda `LazyVGrid` thumbnail galerisi.
*Artı:* Mac'te en tanıdık kalıp (Photos/Finder/Mail), `NavigationSplitView` ile bedava geliyor; 200+ öğede performanslı; çoklu seçim, `.searchable`, sıralama menüsü doğal; ajan için en az özel kod.
*Eksi:* "iş akışının neresindeyim" hissi zayıf — durum bir çip, bir sütun değil.

**Seçenek 2 — Kanban (gruplar = sütun, drag & drop).** Sütunlar: Inbox / Queued / Scheduled / Sent / Done.
*Artı:* Devin Desktop'ın "Waiting for review" sütunu gibi, ajan işinin durumu bir bakışta okunuyor; sürükleyerek dispatch etmek tatmin edici.
*Eksi:* Sütun sayısı sabit olmak zorunda (grup = proje mi, durum mu? ikisini birden sütun yapamazsın); yatay scroll + thumbnail büyüklüğü çatışıyor; reorder/drop state'i elle yazılacak en pahalı SwiftUI işi; 50+ karta çıkınca kullanışsızlaşıyor.

> **Öneri: Seçenek 1.** Sidebar'da gruplama, grid'de durum çipleri, ve **Kanban'ı ayrı bir view mode olarak sonraya bırak** (`Picker` ile Grid / List / Board). Böylece v1'de `NavigationSplitView` + `LazyVGrid` ile hızlı çıkarsın, board'u kanıtlanmış bir ihtiyaç olduğunda eklersin.

```
┌ Tasker ────────────────────────────────────────── ⌘F ────┐
│ PROJELER        │ Checkout bug · 6 öğe    [▦ Grid|▤ Liste]│
│  ◈ acme-web  12 │ Sırala: En yeni ▼   Durum: Tümü ▼       │
│  ◈ api-core   3 │ ┌────────┐┌────────┐┌────────┐          │
│  ◈ Inbox      5 │ │  ▣ img ││  ▣ img ││  ▣ img │          │
│ ─────────────── │ │● queued││○ inbox ││✓ done  │          │
│ GRUPLAR         │ │ 0:04 🎙││   —    ││ 0:11 🎙│          │
│  ▸ Checkout  6  │ └────────┘└────────┘└────────┘          │
│  ▸ Nav bar   4  │ ┌────────┐┌────────┐┌────────┐          │
│  ▸ Perf      2  │ │⧗ sched ││✗ failed││➤ sent  │          │
│ ─────────────── │ └────────┘└────────┘└────────┘          │
│ DURUM           │                                         │
│  ○ inbox     5  │ ── 3 seçili ──────────────────────────  │
│  ● queued    4  │ [Tek görev olarak gönder] [Ayrı ayrı]   │
│  ⧗ scheduled 2  │ [Gruba taşı ▼] [Zamanla ▼]     ⌫ Sil    │
└─────────────────┴─────────────────────────────────────────┘
```

**Component eşlemesi:** `WindowGroup` + `NavigationSplitView` (sidebar / content / `Inspector`). Sidebar `List` + `Section`. Grid `LazyVGrid(columns:)` + `ScrollView`; liste modu `Table` (sortable `TableColumn`'lar → "newest / manual / status" sıralaması bedava). Arama `.searchable(text:placement:.toolbar)` + `.searchScopes`. Çoklu seçim `List/Table(selection: Set<Capture.ID>)`, grid'de `⌘`/`⇧` tıklama elle. Sürükle-bırak: `Capture: Transferable` (`ProxyRepresentation` + `FileRepresentation` — Finder'a sürüklemek de bedava gelir), `.draggable(capture)` ve sidebar grupları üstünde `.dropDestination(for: Capture.self)`. Sağ tık `.contextMenu(forSelectionType:)` → Gönder / Grup ata / Yeniden çek / Sil. Durum çipleri `Label` + `.symbolVariant` + `Capsule` arka plan. Toolbar `.toolbar { ToolbarItemGroup }` (macOS 26'da otomatik Liquid Glass). Alt seçim çubuğu `.safeAreaInset(edge: .bottom)` içinde `.glassEffect()`.

### C.3 Task detail

```
┌ Checkout · "hitbox kayıyor" ─────────────── ● queued ─────┐
│ ┌──────────────────────────┐ │ DETAY                      │
│ │                          │ │ Proje  [ ~/dev/acme-web ▼] │
│ │   screenshot preview     │ │ Branch [ fix/checkout    ] │
│ │   (zoom / annotate)      │ │ Mod    (•) analyze ( ) impl│
│ │                          │ │ Model  [ opus-5         ▼] │
│ └──────────────────────────┘ │ Zaman  [ Bu gece 02:00  ▼] │
│ TRANSKRİPT            🎙0:04 │ ────────────────────────── │
│ ┌──────────────────────────┐ │ RUN LOG           ⏹ Durdur │
│ │ butonun hitbox'ı 4px     │ │ › claude -p --output-format│
│ │ kayıyor, muhtemelen…     │ │     stream-json …          │
│ │ [düzenlenebilir]         │ │ ● Read  Checkout.tsx       │
│ └──────────────────────────┘ │ ● Edit  Button.tsx (+12/-3)│
│ EKLER [+ görsel] [+ dosya]   │ ▌akıyor…                   │
└──────────────────────────────┴────────────────────────────┘
```

**Component eşlemesi:** Detay, library penceresinin `Inspector`'ı olarak açılır (`.inspector(isPresented:)`), `⌘⌥I` ile toggle; çift tıkta ayrı `Window` olarak da açılabilir. Preview `Image` + `.scaledToFit()` + magnification gesture. Transkript `TextEditor` (düzenlenebilir — STT'yi hiçbir zaman kilitleme). Proje dizini `.fileImporter` + son kullanılanlar `Menu`. Mod `Picker(.segmented)`. Zamanlama `DatePicker` + hazır seçenekler (`Menu`: "1 saat sonra", "Bu gece 02:00", "Yarın sabah"). Run log: `ScrollViewReader` + `LazyVStack`, satırlar `swift-subprocess`'in `AsyncBufferSequence.LineSequence`'inden `@MainActor` bir `@Observable` store'a akar; Linear'dan ödünç: koşu bitince üretilen diff/artifact aynı ekranda görünür. Durum rozeti toolbar'ın sağında `.toolbar(placement: .primaryAction)`.

### C.4 Settings

`Settings { TabView { ... } }` scene'i (`⌘,` bedava gelir), her sekme bir `Form` + `.formStyle(.grouped)`:
- **General** — varsayılan proje, PNG/HEIC formatı (⚠️ PNG default), storage location (`.fileImporter`), "yakalamaları N gün sonra çöpe at" (Raycast'ten ödünç).
- **Shortcuts** — hotkey recorder: `NSEvent.addLocalMonitorForEvents` ile tuş yakalayan küçük bir `NSViewRepresentable`; kayıt Carbon `RegisterEventHotKey` ile yapılır.
- **Permissions** — Screen Recording / Microphone / Speech Recognition / Accessibility durumları `Label` + yeşil-sarı-kırmızı `symbolVariant`, her biri yanında "System Settings'te aç" butonu (`x-apple.systempreferences:` URL'i). Highlight AI'dan ödünç: **capture exclusion list** de buraya.
- **Claude** — CLI yolu (`.fileImporter`, varsayılanı `which claude` ile doldur), model seçimi, varsayılan mod, eşzamanlı koşu limiti.

---

## İsim Önerileri

"Tasker" hem çok genel hem de Android'de büyük bir otomasyon uygulamasının adı. 5 alternatif (hepsi için ticari marka/domain kontrolü ayrıca yapılmalı):

| İsim | Mantık |
|---|---|
| **Shotcue** | *shot* (yakalama) + *cue* (sıraya alma). Taramada eşleşen bir macOS ürünü çıkmadı. Ürünün tam cümlesi: "cue it up for the agent". |
| **Snagline** | *snag* (hem "yakala" hem "pürüz/bug") + *line* (kuyruk). İki anlamı da ürüne oturuyor. |
| **Kesit** | Türkçe "kesit/kırpma". Kısa, global olarak ayırt edici, telaffuzu kolay, `.app` için uygun. |
| **Snapq** | *snap* + *queue*, 5 harf. Agresif biçimde kısa; CLI adı olarak da iyi (`snapq send`). |
| **Brief** | "Ajanı brief'le." Yakalama + not + scope = bir brief. Kavramsal olarak en güçlüsü, ama genel bir kelime olduğu için marka kontrolü en riskli olanı. |

---

## Kaynaklar

Stack: [Tauri releases](https://tauri.app/release/core/) · [tauri crate (2.11.6)](https://crates.io/crates/tauri) · [tauri-plugin-global-shortcut](https://v2.tauri.app/plugin/global-shortcut/) · [tauri-plugin-screenshots](https://crates.io/crates/tauri-plugin-screenshots) · [ahkohd/tauri-nspanel](https://github.com/ahkohd/tauri-nspanel) · [Electron schedule](https://releases.electronjs.org/schedule) · [Electron desktopCapturer](https://www.electronjs.org/docs/latest/api/desktop-capturer) · [Electron globalShortcut](https://www.electronjs.org/docs/latest/api/global-shortcut) · [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess) · [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [What's new in SwiftUI (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/269/) · [Adopting drag and drop in SwiftUI](https://developer.apple.com/documentation/SwiftUI/Adopting-drag-and-drop-using-SwiftUI) · [Compose Multiplatform](https://kotlinlang.org/compose-multiplatform/) · [compose-macos-26-ui](https://github.com/kdroidFilter/compose-macos-26-ui) · [I Shipped a macOS App Built Entirely by Claude Code](https://www.indragie.com/blog/i-shipped-a-macos-app-built-entirely-by-claude-code) · [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/swiftui-agent-skill) · [Cindori: floating panel in SwiftUI](https://cindori.com/developer/floating-panel)

Prior art URL'leri Bölüm B tablosundadır.
