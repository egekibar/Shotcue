# Tasker — macOS Platform, Tooling, Mimari ve Persistence Araştırması

> Kapsam: yalnızca native Swift platformu, build tooling, mimari ve persistence.
> Tarih: 2026-09-22 · Hedef makine: macOS 26.6.2 (25G83), Apple Silicon, Xcode **kurulu değil**.

---

## TL;DR

- **macOS 27 "Golden Gate" 14 Eylül 2026'da çıktı**, Xcode 27 (Swift 6.4) aynı gün yayınlandı. Ama bu makine hâlâ **26.6.2**'de — dolayısıyla deployment target **macOS 26.0** olmalı; 27-only API'ler `if #available(macOS 27, *)` ile gate'lenmeli.
- **Xcode'suz, sadece Command Line Tools + SwiftPM ile tam bir SwiftUI .app üretmek mümkün — bu makinede test edilip doğrulandı.** CLT 27.0 zaten `MacOSX27.sdk` içeriyor; `import SwiftUI/SwiftData/ScreenCaptureKit`, `MenuBarExtra`, `Settings`, `glassEffect()`, `@Observable` hepsi `swift build` ile derlendi.
- `notarytool`, `stapler`, `swift-format` ve `codesign` **CLT içinde mevcut** → notarization pipeline'ı da Xcode'suz kurulabilir. Xcode sadece Previews/Instruments/UI test için gerekir.
- **Kritik tuzak doğrulandı:** ad-hoc imza (`codesign --sign -`) designated requirement'ı `cdhash H"..."` yapar → her rebuild TCC için *yeni bir uygulama*. Çözüm: **stabil self-signed sertifika** + stabil bundle id + stabil kurulum yolu.
- Swift 6.2+ "approachable concurrency": `swiftLanguageModes: [.v6]` + UI modüllerinde `.defaultIsolation(MainActor.self)`, domain/servis modüllerinde `.defaultIsolation(nil)` — SPM'de bu ayar **default olarak gelmiyor**, elle yazılmalı.
- Persistence: **GRDB.swift (metadata/SQLite) + dosya sistemi (PNG/m4a)** öneriliyor; SwiftData değil (concurrency + arka plan yazma + sorgu ifade gücü sınırları bu uygulamanın profiline uymuyor).
- Mimari: **vanilla SwiftUI + `@Observable` + protocol-based servis/repository** (TCA değil) — paralel AI agent'lar için modül sınırları protokol dosyalarıyla net çizilir, boilerplate düşük.
- Sandbox **kapalı** olmalı: sandbox'lı bir app `claude` CLI'ı `Process`/`posix_spawn` ile çalıştıramaz (EPERM) ve child sandbox'ı miras alır. Bu, Mac App Store dağıtımını da eler → Developer ID + notarization + Sparkle 2.

---

## 1. Platform durumu ve deployment target

**Sürümler (2026-09-22 itibarıyla):**

| | Sürüm |
|---|---|
| Güncel macOS | **26** değil → **macOS 27 "Golden Gate"**, 14 Eylül 2026 (duyuru: WWDC 8 Haziran 2026) |
| Güncel Xcode | **Xcode 27** (27A266a), 14 Eylül 2026 — macOS 26.6+ ve **yalnızca Apple Silicon** |
| Güncel Swift | **6.4** (Xcode 27 ile gelen; bu makinedeki CLT de `swiftlang-6.4.0.34.1`) |
| Bu makine | macOS 26.6.2 — Xcode 27 kurulabilir ama **macOS 27 target'lı app çalıştıramaz** |

Yerel doğrulama: CLT paketi `com.apple.pkg.CLTools_Executables` **27.0.0.0**; `xcrun --show-sdk-version` → **27.0**; SDK'lar: `MacOSX26.sdk`, `MacOSX26.5.sdk`, `MacOSX27.sdk`.

**Öneri: `platforms: [.macOS(.v26)]`.** Gerekçeler:

1. **Çalıştırılabilirlik.** Deployment target 27.0 olursa üretilen binary bu makinede (26.6.2) açılmaz. Geliştirme döngüsü kırılır.
2. **İhtiyacımız olan her şey zaten 26.0'da.** SDK interface'inden doğrulandı: `glassEffect` → `@available(iOS 26.0, macOS 26.0, ...)`; `SpeechAnalyzer` (actor), `SpeechTranscriber`, `SpeechDetector` → Speech.framework, macOS 26+; `SystemLanguageModel` / `LanguageModelSession` (FoundationModels) → macOS 26+.
3. **27-only kazanımlar gate'lenebilir.** SDK'da doğrulandı: `reorderable()` ve `reorderContainer(for:)` → `@available(iOS 27.0, macOS 27.0, ...)`. SwiftData'nın `ResultsObserver`/`HistoryObserver`/`fetchCount`/`fetchIdentifiers` da 27. Bunlar "nice to have", blocker değil.
4. **Universal build.** Xcode 27 release notes: deployment target ≥ macOS 27.0 olan target'larda `ARCHS_STANDARD` artık x86_64 içermiyor. Yerel testte de `--arch arm64 --arch x86_64` derlemesi "x86_64 is deprecated for your deployment target (macOS 27.0)" uyarısı verdi.

Kaynaklar: [9to5Mac – macOS 27 çıkış tarihi](https://9to5mac.com/2026/09/09/apple-confirms-macos-27-golden-gate-launch-date-september-14/) · [MacRumors](https://www.macrumors.com/2026/09/10/macos-27-golden-gate-release-date/) · [Xcode 27 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) · [Xcode 27 requirements](https://blakecrosley.com/blog/xcode-27-release) · [SpeechAnalyzer API](https://blog.addpipe.com/apple-speechanalyzer-api/)

---

## 2. SwiftUI (macOS 26/27) — bu uygulama için somut API'ler

SDK interface taramasıyla doğrulanmış API'ler:

**Menu bar + pencereler**
- `MenuBarExtra` + `.menuBarExtraStyle(.window)` → popover içinde tam SwiftUI view, dışarı tıklayınca kapanır. Basit menü/popover için doğru default.
- Scene tipleri mevcut: `Window`, `WindowGroup`, `Settings`, **`UtilityWindow` (macOS 15+)**, `MenuBarExtra`.
- `@Environment(\.openWindow)` ile library penceresini açmak; `.windowResizability`, `.windowLevel(.floating)`, `.windowBackgroundDragBehavior`, `.defaultLaunchBehavior`, `.restorationBehavior` modifier'ları mevcut.
- Settings scene macOS'ta var (iOS/tvOS/watchOS'ta unavailable) — Tasker'ın ayarları buraya.

**Transparan / click-through overlay (bölge seçimi için)**
- **Pure SwiftUI yetmiyor.** SwiftUI'da `allowsHitTesting` var ama **pencere seviyesinde** `ignoresMouseEvents` karşılığı yok. Tam ekran, tıklama-geçirgen, tüm Space'lerde görünen overlay için hâlâ `NSPanel` bridging gerekiyor:
  `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`, `level = .screenSaver`/`.floating`, `isOpaque = false`, `backgroundColor = .clear`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `ignoresMouseEvents` (toggle), içerik `NSHostingView`.
- macOS 26 gotcha: toolbar/title-bar alanına bindirilen SwiftUI butonları, `NSToolbarView` içine eklenen `NSGlassContainerView` mouse event'leri yakaladığı için tıklanamıyor. Overlay'i toolbar üstüne koymayın.

**Liquid Glass**
- `glassEffect(...)` ve `GlassEffectContainer` SwiftUICore'da, **macOS 26.0+** (visionOS'ta unavailable). macOS 27'de API aynı kaldı; sadece render maliyeti düştü ve iç içe container'lar daha öngörülebilir blend ediyor. Yani 26 target'la yazıp 27'de bedava iyileşme alıyoruz.
- Toolbar'lar current SDK'ya build edildiğinde otomatik glass alıyor. Elde `toolbarMinimizationBehavior`, `toolbarBackgroundVisibility`, `toolbarItemHidden`, `toolbarRole` var. (`visibilityPriority` 27 tarafında.)

**Library grid: sıralama + drag & drop**
- **macOS 27 yolu (tercih edilen, gate'li):** `reorderable()` / `reorderable(collectionID:)` + `reorderContainer(for:in:isEnabled:move:)` — `List` dışında `LazyVGrid`, stack ve custom layout'larda da çalışıyor; drag preview, insertion placeholder ve drop animasyonunu SwiftUI hallediyor, siz sadece `ReorderDifference`'ı modele uyguluyorsunuz.
- **macOS 26 fallback:** `Transferable` conformance + `.draggable(_:)` + `.dropDestination(for:)`; çoklu seçim için `dragContainer(for:in:)` ve `dragContainerSelection(_:)` (SDK'da mevcut).
- Bilinen bug: `.reorderable()` conditional compilation veya popover içeren view'larda crash edebiliyor — 27 yolunu feature flag arkasında tutun.

**Observation**
- `@Observable` standart. macOS 27 SDK'da `@State` artık hem struct hem **macro** olarak tanımlı (`@attached(accessor...) public macro State()`), iOS 17'ye back-deploy ediliyor; kaynak uyumlu.

Kaynaklar: [nilcoalescing – yeni reordering/drag-drop API'leri](https://nilcoalescing.com/blog/NewSwiftUIAPIsForReorderingAndDragAndDropOniOS27/) · [Apple – Adopting drag and drop in SwiftUI](https://developer.apple.com/documentation/SwiftUI/Adopting-drag-and-drop-using-SwiftUI) · [Michael Tsai – SwiftUI in appleOS 27](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/) · [Menu bar + floating window best practices](https://fazm.ai/blog/swiftui-menu-bar-app-floating-window-best-practices) · [nilcoalescing – macOS menu bar utility](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/) · [Apple Forums – NSGlassContainerView tıklama sorunu](https://developer.apple.com/forums/thread/788928) · [Liquid Glass pratik rehber](https://spaceport.build/blog/liquid-glass-swiftui)

---

## 3. Swift 6.x concurrency

Swift 6.2 ile gelen "approachable concurrency" paketi 6.4'te de geçerli. **Xcode 26+ yeni proje şablonlarında default açık, ama yeni bir SPM paketinde `defaultIsolation` hiç set edilmiyor** — elle yazmak şart.

Önerilen kalıp: **UI/App katmanı MainActor-default, domain/servis katmanı nonisolated.**

```swift
// swift-tools-version: 6.4
import PackageDescription

let mainActorUI: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),          // SE-0466
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"),      // SE-0470
]
let nonisolatedCore: [SwiftSetting] = [
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Tasker",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Tasker", targets: ["TaskerApp"])],
    targets: [
        .target(name: "TaskerCore",       swiftSettings: nonisolatedCore),
        .target(name: "TaskerPersistence", dependencies: ["TaskerCore"], swiftSettings: nonisolatedCore),
        .target(name: "TaskerCapture",     dependencies: ["TaskerCore"], swiftSettings: nonisolatedCore),
        .target(name: "TaskerNotes",       dependencies: ["TaskerCore"], swiftSettings: nonisolatedCore),
        .target(name: "TaskerClaudeBridge",dependencies: ["TaskerCore"], swiftSettings: nonisolatedCore),
        .target(name: "TaskerUI",          dependencies: ["TaskerCore"], swiftSettings: mainActorUI),
        .executableTarget(name: "TaskerApp",
                          dependencies: ["TaskerUI", "TaskerPersistence", "TaskerCapture",
                                         "TaskerNotes", "TaskerClaudeBridge"],
                          swiftSettings: mainActorUI),
        .testTarget(name: "TaskerCoreTests", dependencies: ["TaskerCore"], swiftSettings: nonisolatedCore),
    ],
    swiftLanguageModes: [.v6]
)
```

Neden bu ayrım: UI'da `@MainActor` spam'i ve gereksiz `Task { @MainActor in }` sarmalları kayboluyor; ama `ScreenCaptureKit` yazımı, ses kaydı, SQLite ve `Process` spawn eden servisler MainActor'a hapsolmamalı. `nonisolated(nonsending)` default'u (SE-0461) async fonksiyonların çağıranın izolasyonunda çalışmasını sağlayarak actor hopping'i azaltıyor.

> Bu makinede doğrulandı: `.defaultIsolation(MainActor.self)` ve `.defaultIsolation(nil)` tools-version 6.2 ve 6.4 ile sorunsuz derlendi.

Kaynaklar: [SwiftLee – Default Actor Isolation](https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/) · [Donny Wals – Should you opt in?](https://www.donnywals.com/should-you-opt-in-to-swift-6-2s-main-actor-isolation/) · [Use Your Loaf – Approachable Concurrency in Swift Packages](https://useyourloaf.com/blog/approachable-concurrency-in-swift-packages/)

---

## 4. Xcode olmadan build (en kritik bölüm — bu makinede test edildi)

### 4.1 Derleme: ÇALIŞIYOR

Scratchpad'de kurulan probe paketi, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`, `.defaultIsolation(MainActor.self)` ile:

```swift
import SwiftUI; import AppKit; import SwiftData; import ScreenCaptureKit
@Observable final class Store { var count = 0 }
struct RootView: View { var body: some View { Text("hi").glassEffect() } }
struct ProbeApp: App {
    var body: some Scene {
        MenuBarExtra("Tasker", systemImage: "camera") { RootView() }.menuBarExtraStyle(.window)
        Window("Library", id: "library") { RootView() }
        Settings { Text("settings") }
    }
}
```

→ `swift build` → **Build complete.** Tek gürültü: iki zararsız `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/...' not found`.

`swift test` + `import Testing` de çalıştı (parametrized test dâhil, Testing Library Version 2084). Universal build (`--arch arm64 --arch x86_64`) da çalıştı ve `lipo -info` fat binary doğruladı.

### 4.2 .app bundle'ı elle üretmek

```
Tasker.app/Contents/
├── Info.plist
├── MacOS/Tasker          # swift build --show-bin-path çıktısındaki executable
└── Resources/            # AppIcon.icns, assets
```

Info.plist'te gereken anahtarlar:

```xml
<key>CFBundleIdentifier</key><string>com.pentayazilim.tasker</string>
<key>CFBundleExecutable</key><string>Tasker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>                                 <!-- Dock'ta görünme -->
<key>NSMicrophoneUsageDescription</key><string>Sesli not almak için.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Sesli notu metne çevirmek için.</string>
```
(Screen Recording için Info.plist anahtarı yok — TCC doğrudan sistem prompt'u gösterir.)

### 4.3 Codesigning: ad-hoc çalışıyor ama TCC'yi bozuyor

```bash
codesign --force --options runtime \
  --entitlements app.entitlements \
  --sign - --identifier com.pentayazilim.tasker Tasker.app
```
Doğrulandı: `flags=0x10002(adhoc,runtime)`, entitlements gömüldü, `codesign --verify --deep --strict` → *valid on disk / satisfies its Designated Requirement*, `spctl -a` → *rejected* (yerel build'de önemsiz; quarantine attribute yok, uygulama açılıyor).

**Sorun:** ad-hoc imzanın designated requirement'ı literal olarak şu:
```
designated => cdhash H"fe3159a28fec541282f42b3d879171b58929fc48"
```
Her rebuild cdhash'i değiştirir → **TCC için yepyeni bir uygulama.** Mikrofon/Screen Recording izni verilir ama bir sonraki `swift build`'de geçersizleşir; System Settings'te ölü bir satır kalır. (Ad-hoc app'ler izin *alabilir*, izni *koruyamaz*.)

**Çözüm — stabil self-signed sertifika (ücretsiz, tek seferlik):**

```bash
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout dev.key -out dev.crt -subj "/CN=Tasker Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"
openssl pkcs12 -export -legacy -in dev.crt -inkey dev.key -out dev.p12 -password pass:dev
security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P dev -T /usr/bin/codesign
# Keychain Access → sertifika → Trust → Code Signing: "Always Trust"
codesign --force --options runtime --sign "Tasker Dev" Tasker.app
```
> Not: Keychain'e sertifika eklemek ve güven ayarı yapmak kullanıcının kendi yapması gereken bir adım — bu rapor sadece komutları belgeliyor.

Ek disiplin: **bundle id sabit**, **kurulum yolu sabit** (`~/Applications/Tasker.app`, build çıktısını oraya kopyala; `.build/` içinden çalıştırma), izin bozulunca `tccutil reset All com.pentayazilim.tasker` + app'i yeniden başlat.

> Uyarı: Bazı ekipler ad-hoc imzayla `CGPreflightScreenCaptureAccess()`'in hiç geçmediğini raporluyor (Cap #1722). Bu riski tamamen elemek için **ilk günden self-signed (veya Apple Development) sertifikayla imzalayın** — ad-hoc'u sadece CI için bırakın.

### 4.4 swift-bundler

[stackotter/swift-bundler](https://github.com/stackotter/swift-bundler) v2.0.x hâlâ aktif (macOS/Linux/Windows/Android/iOS/tvOS/visionOS). Info.plist üretimi, code signing, entitlements, app icon, bundling, **notarization** ve hot reload'u TOML config ile veriyor; `swift bundler create/run/generate-xcode-support`. Ancak: küçük bir topluluk projesi, macOS 27/Swift 6.4 uyumu dokümante değil ve bizim ihtiyacımız ~40 satırlık bir `Makefile`/shell script. **Öneri: bağımlılık almayın; kendi `scripts/bundle.sh`'inizi yazın.** swift-bundler'ı referans/yedek plan olarak tutun.

### 4.5 Notarization — Xcode gerekmiyor

`xcrun -f notarytool` ve `xcrun -f stapler` CLT içinde **mevcut** (`/Library/Developer/CommandLineTools/usr/bin/`). Dağıtım akışı:
1. Developer ID Application sertifikasıyla `codesign --options runtime --timestamp`
2. `ditto -c -k --keepParent Tasker.app Tasker.zip`
3. `xcrun notarytool submit Tasker.zip --key AuthKey.p8 --key-id ... --issuer ... --wait`
4. `xcrun stapler staple Tasker.app`

Tek eksik: Developer ID sertifikası ücretli Apple Developer Program üyeliği gerektirir (~$99/yıl). Sertifika bir kez `security import` ile keychain'e girerse Xcode'a yine gerek yok.

### 4.6 Xcode kurmalı mı?

| | Sadece CLT | + Xcode 27 |
|---|---|---|
| Disk | ~1–2 GB (zaten kurulu) | +~35–60 GB |
| `swift build` / `swift test` | ✅ | ✅ |
| SwiftUI Previews | ❌ | ✅ |
| Instruments (leak/CPU profiling) | ❌ | ✅ |
| XCUITest / UI automation | ❌ | ✅ |
| notarytool / stapler / swift-format | ✅ | ✅ |
| Symbolicated crash log incelemesi | kısıtlı | ✅ |

**Karar (AI-agent workflow için):** birincil döngü **CLT + SwiftPM**. `swift build` / `swift test` terminalden çalışıyor, deterministic, agent-dostu; `.xcodeproj` merge conflict'i yok. Xcode'u **sonraya bırakın** ve yalnızca (a) ciddi bir performans/leak avı çıkarsa (Instruments) veya (b) UI automation testi gerekirse kurun — SPM paketi Xcode'da doğrudan açılabildiği için bu geçiş bedava.

---

## 5. Proje yapısı ve tooling

```
tasker/
├── Package.swift
├── Sources/
│   ├── TaskerCore/          # domain modelleri, protokoller, hata tipleri (bağımlılıksız)
│   ├── TaskerPersistence/   # GRDB, migration'lar, repository implementasyonları
│   ├── TaskerCapture/       # ScreenCaptureKit, overlay NSPanel, hotkey
│   ├── TaskerNotes/         # ses kaydı (AVAudioEngine), SpeechAnalyzer transkripti
│   ├── TaskerClaudeBridge/  # Process spawn, scheduling, dispatch history
│   ├── TaskerUI/            # SwiftUI view'ları, @Observable store'lar
│   └── TaskerApp/           # @main App, MenuBarExtra, Window, Settings, DI composition root
├── Tests/…Tests/            # Swift Testing
├── scripts/{bundle.sh,sign.sh,notarize.sh}
└── Resources/{Info.plist,Tasker.entitlements,AppIcon.icns}
```

`TaskerCore` **hiçbir şeye bağımlı olmamalı** — tüm protokoller (`ScreenshotRepository`, `CaptureService`, `TranscriptionService`, `TaskDispatcher`, `Scheduler`) orada yaşar. Bu, paralel agent'ların birbirine değmeden çalışabilmesinin tek gerçek mekanizması.

- **Test: Swift Testing (`import Testing`).** 2026'da yeni kod için önerilen default; macro tabanlı, default paralel, `#expect`/`#require`. XCTest sadece UI automation (`XCUIApplication`) ve `XCTMetric` performans testleri için gerekir — bizde ikisi de yok. Bu makinede CLT ile çalıştığı doğrulandı.
- **Format: `swift-format`** — CLT'de hazır geliyor (`xcrun swift-format`). Ekstra bağımlılık yok, Apple resmî. `.swift-format` config'i repoya koyun, pre-commit/CI'da `swift-format lint --recursive Sources`.
- **SwiftLint:** hâlâ bakımda ve 200+ kural sunuyor ama ayrı bir binary + swift-format ile layout kavgası riski. **Başlangıçta atlayın**; ihtiyaç doğarsa sadece `--only-rules` ile korelasyon kuralları (force_unwrapping vb.) için ekleyin.
- **Tuist / XcodeGen:** ikisi de yaşıyor (XcodeGen daha yavaş, topluluk bakımlı; Tuist büyük modüler projelere ve cache'e odaklı). Tek hedefli, tek platformlu, `.xcodeproj` olmayan bu projede **gereksiz**. Xcode ileride kurulursa SPM paketi doğrudan açılır — generator gerekmez.

Kaynaklar: [Swift Testing vs XCTest](https://blakecrosley.com/blog/swift-testing-vs-xctest) · [swiftlang/swift-format](https://github.com/swiftlang/swift-format) · [SwiftLint](https://swiftpackageindex.com/realm/SwiftLint) · [Tuist – neden project generation](https://tuist.dev/blog/2025/02/25/project-generation) · [XcodeGen bakım durumu](https://xcodegen.com/is-xcodegen-still-actively-maintained/)

---

## 6. Mimari önerisi (AI agent'ların yazacağı kod tabanı için)

**Öneri: vanilla SwiftUI + `@Observable` + protocol-based servis/repository + constructor injection. TCA değil.**

| Kriter | Vanilla + @Observable | TCA |
|---|---|---|
| Boilerplate | Düşük | Orta–yüksek (State/Action/Reducer/Effect enum'ları) |
| Test edilebilirlik | Protokol mock'larıyla yüksek | Çok yüksek (exhaustive `TestStore`) |
| Öğrenme/token maliyeti | Düşük — agent'lar Apple dokümanından besleniyor | Yüksek; agent'ların TCA versiyon kaymalarında halüsinasyon riski fazla |
| Derleme süresi | İyi | Ağır generic/macro yükü |
| Paralel agent izolasyonu | Modül + protokol sınırı yeterli | Reducer composition merkezî bir dosyada toplanır → çakışma noktası |
| Uygunluk | Utility app, çoğunlukla I/O + lokal state | Karmaşık wizard/undo-redo/deterministik multiplayer |

Tasker büyük ölçüde **I/O orkestrasyonu** (ekran yakala → dosyaya yaz → ses kaydet → transkript et → SQLite'a yaz → `claude` process'i spawn et). TCA'nın asıl kazancı olan "deterministik state machine"e burada ihtiyaç yok; asıl risk yan etkilerin kendisinde ve orayı protokol + fake implementasyon çözüyor.

Somut kalıp: her servis `TaskerCore`'da bir `protocol` + `Sendable` value tipleri; production implementasyonu kendi modülünde; testte `struct FakeDispatcher: TaskDispatcher`. `TaskerApp` içinde tek bir `AppEnvironment` composition root. UI store'ları `@Observable final class LibraryStore` + `@Environment`.

> TCA'nın kendi FAQ'sı bile modern TCA'nın vanilla'ya göre *çok fazla* satır eklememesi gerektiğini savunuyor; yine de AI agent'ların ürettiği kodda framework-spesifik idiom hatası maliyeti yüksek olduğu için Apple-native yüzeye bağlı kalmak daha güvenli.

Kaynaklar: [Point-Free – TCA FAQ](https://www.pointfree.co/blog/posts/141-composable-architecture-frequently-asked-questions) · [TCA eleştirisi](https://medium.com/@redhotbits/tca-architecture-a-glorified-antipattern-5ad356ea39c8) · [iOS App Architecture 2026](https://www.forasoft.com/blog/article/advanced-ios-app-architecture-explained-on-mvvm-977)

---

## 7. Persistence

**Öneri: GRDB.swift (v7.x) — metadata SQLite'ta, binary'ler dosya sisteminde.**

Neden SwiftData değil:
- Bu uygulamada **UI olmayan bileşenler** (scheduler, dispatch worker, transkript pipeline) SwiftUI view'larıyla **eşzamanlı** aynı store'u okuyup yazacak. SwiftData'nın bilinen zayıf noktaları tam burada: unique constraint'ler, migration'lar, background access ve sorgu ifade gücü.
- macOS 27 SwiftData güncellemesi (`ResultsObserver`, `HistoryObserver`, `fetchCount`, `fetchIdentifiers`, Codable custom tipler) boşluk dolduruyor ama performans tarafında net bir sıçrama yok — ve hepsi **27-only**, biz 26 hedefliyoruz.
- Dispatch history + schedule sorguları (durum filtreleri, tarih aralıkları, gruplara göre aggregate) düz SQL'de çok daha rahat.

Neden GRDB: olgun (8.5k+ yıldız), v7 **Swift 6 concurrency**'ye tam uyumlu (`ValueObservation` default MainActor scheduling, `values` async sequence), macOS 10.15+, migration API'si birinci sınıf, `DatabasePool` ile WAL + eşzamanlı okuma. `@Observable` store'lar `ValueObservation`'ı dinleyip UI'ı besler — `@Query` benzeri bir ergonomi, ama kontrol sizde.

Alternatifler: *SQLite.swift* daha ince ama ekosistem/observation desteği zayıf; *düz JSON dosyaları* 500+ screenshot ve tarih/durum filtreleriyle çöker (atomic write + concurrency'yi elle yazmak gerekir). Screenshot/ses gibi **binary'ler asla DB'ye girmemeli** — blob'lar SQLite'ı şişirir, thumbnail üretimi ve Finder'dan inceleme zorlaşır.

**Depolama layout'u:**

```
~/Library/Application Support/com.pentayazilim.tasker/
├── tasker.sqlite            (+ -wal, -shm)
├── screenshots/2026/09/<uuid>.png
├── thumbnails/<uuid>@2x.jpg          # yeniden üretilebilir → cache sayılır
├── audio/<uuid>.m4a
└── logs/dispatch-<date>.jsonl        # append-only ham çıktı
~/Library/Caches/com.pentayazilim.tasker/   # thumbnail'ları buraya da alabilirsiniz
```

Tablo taslağı: `screenshot(id, created_at, file_path, width, height, display_id, thumb_path)`, `note(id, screenshot_id, kind[text|voice], text, audio_path, transcript, created_at)`, `group(id, name, sort_index)`, `group_item(group_id, screenshot_id, sort_index)`, `dispatch(id, target[cli|desktop], payload_json, status, scheduled_at, started_at, finished_at, exit_code, output_path)`, `schedule(id, dispatch_template_json, cron_or_date, next_fire_at, enabled)`.

Sıralama için `sort_index REAL` (fractional indexing) kullanın — reorder'da tek satır güncellenir, `reorderContainer`'ın `ReorderDifference`'ıyla birebir uyuşur. DB'de sadece **göreli yol** tutun (`screenshots/2026/09/x.png`), kök dizini runtime'da çözün; böylece klasör taşınabilir olur.

Kaynaklar: [GRDB vs SwiftData vs Core Data 2026](https://www.pistack.xyz/posts/2026-08-11-grdb-swiftdata-core-data-swift-persistence-comparison/) · [SwiftData limitations](https://fatbobman.com/en/posts/key-considerations-before-using-swiftdata/) · [Michael Tsai – SwiftData in appleOS 27](https://mjtsai.com/blog/2026/06/23/swiftdata-in-appleos-27/) · [GRDB – Swift Concurrency](https://swiftpackageindex.com/groue/GRDB.swift/master/documentation/grdb/swiftconcurrency)

---

## 8. Utility-app plumbing

**Sandbox: KAPALI — doğrulandı.** Sandbox'lı bir app `posix_spawn`/`Process` ile keyfi bir binary (`claude`) çalıştırmaya kalkarsa kernel `process-exec`'i default container'da görmediği için **EPERM** döner; ayrıca child her zaman parent'ın sandbox'ını miras alır, yani `claude` de kısıtlı çalışırdı. App Review "app içindeki tüm kodun sandbox'lı olmasını" şart koştuğu için **Mac App Store dağıtımı da eleniyor.** Entitlements:
```xml
<key>com.apple.security.app-sandbox</key><false/>
<key>com.apple.security.device.audio-input</key><true/>
```
Hardened Runtime **açık** kalsın (`codesign --options runtime`) — notarization için zorunlu ve sandbox'tan bağımsız.

**Launch at login: `SMAppService`** (macOS 13+, `SMLoginItemSetEnabled`/`SMJobBless`'in yerine). `SMAppService.mainApp.register()` / `.unregister()`; durumu `.status` ile okuyun. Ayarlar ekranında **açık bir toggle** olsun ve **default `false`** — Apple otomatik launch'ı kullanıcı onayı olmadan yasaklıyor. Bilinen tuzak: toggle ile gerçek registration desenkron olabiliyor; UI'ı her açılışta `.status`'tan türetin, cache'lemeyin.

**Dock görünürlüğü:** `LSUIElement=true` ile menü-bar-only başlayın; library penceresi açılınca `NSApp.setActivationPolicy(.regular)`, kapanınca `.accessory`'ye dönün. Bu, `Info.plist`'i değiştirmeden dinamik geçiş sağlar (ve `.regular`'a geçiş sonrası `NSApp.activate()` gerekir).

**Güncelleme: Sparkle 2** — Developer ID + notarization varsa değer. EdDSA imzalı appcast, `SUFeedURL`/`SUPublicEDKey` Info.plist'te; sandbox kapalı olduğu için Sparkle'ın XPC service'lerine gerek yok (bu ciddi bir sadeleşme). İlk sürümde erteleyip manuel DMG ile başlanabilir.

**Notarization:** 4.5'teki akış. Dağıtım DMG ise DMG'yi de ayrıca imzalayıp staple edin.

Kaynaklar: [nilcoalescing – Launch at login](https://nilcoalescing.com/blog/LaunchAtLoginSetting/) · [theevilbit – SMAppService](https://theevilbit.github.io/posts/smappservice/) · [Apple – Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) · [Apple Forums – sandboxed app'ten process spawn](https://developer.apple.com/forums/thread/685544) · [Sandboxing on macOS](https://bdash.net.nz/posts/sandboxing-on-macos/) · [Steinberger – Code Signing & Notarization: Sparkle and Tears](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)

---

## Öneri — Stack Kararı

| Alan | Karar | Gerekçe (kısa) |
|---|---|---|
| Deployment target | **macOS 26.0** | Geliştirme makinesi 26.6.2; Liquid Glass/SpeechAnalyzer/FoundationModels zaten 26'da |
| 27-only API'ler | `if #available(macOS 27, *)` | `reorderable()`/`reorderContainer` + SwiftData observer'ları için opsiyonel yol |
| Toolchain | **CLT 27.0 + SwiftPM** (Xcode YOK) | `swift build`/`swift test` bu makinede doğrulandı; agent-dostu, merge-conflict yok |
| Xcode | **Sonraya ertele** | Sadece Instruments/Previews/XCUITest gerekirse; SPM paketi doğrudan açılır |
| Swift language mode | `swiftLanguageModes: [.v6]` | Strict concurrency baştan |
| Izolasyon | UI: `.defaultIsolation(MainActor.self)` · Core/servis: `.defaultIsolation(nil)` | UI'da boilerplate yok, I/O MainActor'a hapsolmuyor |
| Bundling | Kendi `scripts/bundle.sh` | swift-bundler bağımlılığına değmez; ~40 satır shell |
| İmzalama (dev) | **Self-signed "Tasker Dev" sertifikası** | Ad-hoc `cdhash` designated requirement → her rebuild TCC'yi sıfırlar |
| İmzalama (dağıtım) | Developer ID + `--options runtime` + `notarytool`/`stapler` | Hepsi CLT'de mevcut |
| Sandbox | **KAPALI** | `claude` CLI spawn'ı sandbox'ta EPERM; MAS dağıtımı zaten dışarıda |
| UI framework | Vanilla SwiftUI + `@Observable` | TCA'nın determinizm kazancı bu I/O ağırlıklı app'te karşılığını vermiyor |
| Overlay | `NSPanel` + `NSHostingView` bridging | SwiftUI'da pencere seviyesinde click-through yok |
| Persistence | **GRDB.swift v7** + dosya sistemi | Background yazma, SQL ifade gücü, Swift 6 uyumu; SwiftData bu profilde riskli |
| Test | **Swift Testing** | CLT ile çalışıyor; 2026 default'u |
| Format/Lint | `swift-format` (CLT'de hazır) | Ek bağımlılık yok; SwiftLint'i ertele |
| Project gen | **Yok** (Tuist/XcodeGen gereksiz) | `.xcodeproj` yok, üretilecek bir şey yok |
| Login item | `SMAppService.mainApp` | Modern API; toggle default kapalı |
| Dock | `LSUIElement` + `NSApp.setActivationPolicy` | Menü-bar-only başla, pencere açılınca `.regular` |
| Updates | Sparkle 2 (v1'den sonra) | Sandbox kapalı olduğu için sade kurulum |
