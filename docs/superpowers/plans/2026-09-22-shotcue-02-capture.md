# Shotcue v1 — Plan 02: Capture

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ShotcueCapture` modülünü, Plan 00'ın `ShotcueCore` protokollerini birebir karşılayan altı üretim tipiyle kurmak: `ScreencaptureService` (bölge yakalama, iptal tespiti), `ImageInfo` (PNG piksel boyutu + Retina ölçeği), `ImageIOThumbnailService` (JPEG thumbnail), `SystemPermissionService` (Ekran Kaydı / Mikrofon / Bildirim TCC durumu + Sistem Ayarları linkleri), `CarbonHotKeyService` (izin istemeyen global kısayol) ve `PasteboardWriter` (PNG + dosya URL'i panoya). Hepsi Swift Testing ile test edilir; testler gerçek TCC diyaloğu açmaz, gerçek `screencapture` çalıştırmaz.

**Architecture:** Modül dışa yalnızca Core protokollerinin implementasyonlarını verir; hiçbir tip Core'daki bir protokolü değiştirmez veya yeni bir ortak sözleşme icat etmez. Yakalama, `/usr/sbin/screencapture -i -s -x -t png <hedef>` alt sürecini `Process` ile çalıştırır (spec §6.1); TCC kontrolü "responsible process" üzerinden yapıldığı için izin diyaloğu Shotcue.app adına çıkar (araştırma §2.2). Süreç sonucu üç yola ayrılır: çıkış 0 → PNG metadata'sından `CaptureResult`; çıkış 1 + boş stderr → `nil` (kullanıcı `Esc`'ledi); diğer → `CaptureError.screencaptureFailed`. Kısayol tarafı Carbon `RegisterEventHotKey` + `InstallEventHandler` ile kurulur; Swift closure'ı `Unmanaged` ile opak `userData` olarak taşınır ve handler main queue'da çağrılır. İzin servisi saf bir `settingsURL(for:)` eşlemesi ve yan etkili `state`/`request` çiftinden oluşur, böylece testler URL eşlemesini diyalog açmadan doğrular.

**Tech Stack:** Swift 6.4 (CLT 27.0, SDK 27.0), SwiftPM, Swift Testing. Bu modülde izinli import'lar: `Foundation`, `AppKit`, `ImageIO`, `UniformTypeIdentifiers`, `CoreGraphics`, `Carbon.HIToolbox`, `AVFoundation` (yalnızca `AVCaptureDevice` mikrofon yetkisi için), `UserNotifications` (yalnızca bildirim yetki durumu için). Harici bağımlılık yok; `Package.swift` bu planda **değiştirilmez**.

**Spec:** `docs/superpowers/specs/2026-09-22-shotcue-design.md` (§5.1, §6.1, §9, §12; araştırma: `docs/research/02-screen-capture-and-hotkeys.md`)

## Global Constraints

- `// swift-tools-version: 6.4`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`.
- UI/App target'ları `.defaultIsolation(MainActor.self)`; servis/test target'ları `.defaultIsolation(nil)`; tüm target'larda `NonisolatedNonsendingByDefault` ve `InferIsolatedConformances` upcoming feature'ları.
- **Xcode yok.** `xcodebuild`, `actool`, `.xcassets`, `#Preview` makrosu ve `#Preview` içeren bağımlılıklar **yasak** (CLT'de `PreviewsMacros` eklentisi yok, derleme kırılır). Yalnızca `swift build`, `swift test`, `swift-format`, `codesign`, `iconutil`, `plutil`.
- Bağımlılık: yalnızca `https://github.com/groue/GRDB.swift.git` `from: "7.11.0"` ve `https://github.com/argmaxinc/argmax-oss-swift.git` `from: "1.1.0"`. Başka paket eklenmez.
- Bundle id `com.shotcue.app`; `LSUIElement` true; `LSMinimumSystemVersion` 26.0; depolama kökü `~/Library/Application Support/Shotcue/`.
- İmza: self-signed "Shotcue Dev" (ad-hoc `--sign -` yalnızca sertifika yoksa uyarıyla); App Sandbox **kapalı**; Hardened Runtime **açık**; entitlement `com.apple.security.device.audio-input = true`.
- Kod, identifier'lar ve commit mesajları İngilizce; UI metinleri Türkçe literal; Swift Testing (`import Testing`, `#expect`, `#require`); XCTest kullanılmaz.
- Domain görev tipi **`ShotTask`** (Swift'in `Task` tipiyle çakışmasın diye). Çalışma kaydı `Run`, ekran görüntüsü `Capture`, ses notu `VoiceNote`, proje `Project`.
- `ShotcueCore` yalnızca `Foundation` import eder. AppKit/SwiftUI/AVFoundation/GRDB Core'a giremez.
- Her task `swift test` yeşilken commit'lenir. Commit mesajı sonu: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Dosya haritası

```
Sources/ShotcueCapture/
  ShotcueCapture.swift              # Plan 00'dan gelen ShotcueCaptureInfo yer tutucusu — SİLİNMEZ (smoke test ona bakıyor)
  CaptureError.swift                # CaptureError (Task 2)
  ImageInfo.swift                   # ImageInfo.read(url:) → (width, height, scale) (Task 1)
  ScreencaptureService.swift        # ScreencaptureService: CaptureService (Task 2)
  ImageIOThumbnailService.swift     # ImageIOThumbnailService: ThumbnailService (Task 3)
  SystemPermissionService.swift     # SystemPermissionService: PermissionService (Task 4)
  CarbonHotKeyService.swift         # HotKeyError, CarbonHotKeyService: HotKeyService (Task 5)
  PasteboardWriter.swift            # PasteboardWriter.copyPNG(at:) (Task 6)
Tests/ShotcueCaptureTests/
  SmokeTests.swift                  # Plan 00'dan gelir, dokunulmaz
  TestPaths.swift                   # Plan 00'ın helper'ı, birebir kopya (Task 1)
  CaptureTestSupport.swift          # scratchURL(_:) geçici dosya üreteci (Task 1)
  ImageInfoTests.swift              # 3 test (Task 1)
  ScreencaptureServiceTests.swift   # 7 test (Task 2)
  ImageIOThumbnailServiceTests.swift# 4 test (Task 3)
  SystemPermissionServiceTests.swift# 2 test (Task 4)
  CarbonHotKeyServiceTests.swift    # 4 test (Task 5)
  PasteboardWriterTests.swift       # 2 test (Task 6)
```

Bu planın dokunmadığı ama okuduğu dosyalar: `Sources/ShotcueCore/Services/CaptureServices.swift` (protokoller), `Sources/ShotcueCore/Models/KeyCombo.swift`, `Tests/Fixtures/fake-screencapture.sh`, `Tests/Fixtures/sample.png`. **Hiçbiri değiştirilmez.** `Package.swift` değiştirilmez (`ShotcueCapture` target'ı ve `ShotcueCaptureTests` test target'ı Plan 00 Task 0'da tanımlandı).

Modül kuralları (Global Constraints'in üstüne):
- Bu modülde `ScreenCaptureKit` **kullanılmaz** (v1 kararı, spec §6.1); `CGWindowListCreateImage` / `CGDisplayCreateImage` **yasak** (macOS 15'te obsoleted, derlenmez — araştırma §1.6).
- `NSScreen.backingScaleFactor` ile ölçek **tahmin edilmez**; ölçek PNG'nin DPI metadata'sından okunur (araştırma §7.4).
- `AVFoundation` yalnızca `AVCaptureDevice.authorizationStatus(for:)` / `requestAccess(for:)` için; ses kaydı Plan 03'ün işi.
- `UserNotifications` yalnızca yetki durumu için; bildirim gönderimi Plan 04/06'nın işi (`Notifier`).
- Test target'ında `import Carbon.HIToolbox` **yazılmaz**. Carbon sabitleri testte sayısal literal olarak yazılır (gerekli olan tek sabit `-9878` = `eventHotKeyExistsErr`); `OSStatus` `Foundation` ile birlikte zaten görünür.
- **Bilinen build flake (kodla ilgisi yok):** CLT-only toolchain'de SwiftPM'in varsayılan (swiftbuild) build sistemi ardışık `swift test` çağrılarında bazen `external macro implementation type 'TestingMacros.SuiteDeclarationMacro' could not be found for macro 'Suite'; plugin for module 'TestingMacros' not found` hatası veriyor — her seferinde farklı bir test dosyasında, deterministik değil. **Çözüm: komutu aynen bir–iki kez tekrar çalıştır** (bu makinede bazen ikinci denemede geçti); ısrar ederse `rm -rf .build`. `--build-system native` denemeyin, CLT'de `Testing` modülünü hiç bulamıyor (`no such module 'Testing'`). Bu hata bir test başarısızlığı olarak yorumlanmamalı.

### Derlenerek doğrulanmış semboller (scratchpad spike, 2026-09-22)

Aşağıdaki API'ler `/private/tmp/.../scratchpad/spike-capture` altında `swift-tools-version 6.4`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`, `swiftSettings: [.defaultIsolation(nil), .enableUpcomingFeature("NonisolatedNonsendingByDefault"), .enableUpcomingFeature("InferIsolatedConformances")]` ayarlarıyla **derlendi ve 22 testle çalıştırıldı**. Bu planda geçen kod o spike'tan alınmıştır; imza tahmini yoktur.

| Alan | Doğrulanan semboller |
|---|---|
| Carbon global hotkey | `RegisterEventHotKey`, `UnregisterEventHotKey`, `InstallEventHandler`, `RemoveEventHandler`, `GetApplicationEventTarget()`, `GetEventParameter`, `EventTypeSpec(eventClass:eventKind:)`, `EventHotKeyID(signature:id:)`, `EventHotKeyRef`, `EventHandlerRef`, `EventHandlerUPP`, `EventParamName`, `EventParamType`, `kEventClassKeyboard`, `kEventHotKeyPressed`, `kEventParamDirectObject`, `typeEventHotKeyID`, `noErr`, `eventNotHandledErr`, `OSType`, `OSStatus` |
| Closure köprüleme | `Unmanaged.passUnretained(_:).toOpaque()`, `Unmanaged<T>.fromOpaque(_:).takeUnretainedValue()`; `EventHandlerUPP`'ye atanan Swift closure literal'i hiçbir şey capture etmediği sürece C fonksiyon pointer'ına dönüşüyor (static üye erişimi capture sayılmıyor) |
| Carbon çalışma zamanı | `RegisterEventHotKey` `swift test` sürecinde (`.app` bundle'ı olmadan, NSApplication çalışmadan) `noErr` döndürüyor; aynı kombinasyon ikinci kez kaydedilirse `-9878` (`eventHotKeyExistsErr`) döndürüyor |
| ImageIO okuma | `CGImageSourceCreateWithURL`, `CGImageSourceCopyPropertiesAtIndex`, `kCGImagePropertyPixelWidth`, `kCGImagePropertyPixelHeight`, `kCGImagePropertyDPIWidth`, `CGImageSourceGetType` |
| ImageIO thumbnail/yazma | `CGImageSourceCreateThumbnailAtIndex`, `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform`, `kCGImageSourceThumbnailMaxPixelSize`, `CGImageDestinationCreateWithURL`, `CGImageDestinationAddImage`, `CGImageDestinationFinalize`, `kCGImageDestinationLossyCompressionQuality`, `UTType.jpeg.identifier` |
| Process / Pipe | `Process.executableURL/arguments/environment/standardOutput/standardError/terminationHandler/run()/terminationStatus`, `Pipe.fileHandleForReading`, `FileHandle.readToEnd()`, `FileHandle.nullDevice`; `Task.detached(priority:)` ile eşzamanlı stderr drenajı + `withCheckedThrowingContinuation` ile `terminationHandler` → kilitlenme yok |
| TCC | `CGPreflightScreenCaptureAccess()`, `CGRequestScreenCaptureAccess()`, `AVCaptureDevice.authorizationStatus(for: .audio)`, `await AVCaptureDevice.requestAccess(for: .audio)`, `await UNUserNotificationCenter.current().notificationSettings()`, `try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`, `UNAuthorizationStatus.{authorized,provisional,ephemeral,denied,notDetermined}` |
| Pano / Ayarlar | `NSPasteboard.general.clearContents()`, `.setData(_:forType: .png)`, `.writeObjects([NSURL])`, `.data(forType:)`, `.readObjects(forClasses:)`, `NSWorkspace.shared.open(_:)` |

Spike'ta ölçülen davranışlar (testlerin beklentileri buradan geliyor):
- `Tests/Fixtures/sample.png` → 64×64 piksel, DPI 144 → `scale == 2.0`.
- Thumbnail `maxPixel: 32` → 32×32 JPEG (~1 KB), DPI yazılmadığı için **thumbnail'ın kendi `scale` değeri 1.0**; `maxPixel: 512` → kaynak 64×64 kaldığı için 64×64 (ImageIO upscale yapmıyor).
- Var olmayan hedef dizin veya yazılamayan yol → `CGImageDestinationCreateWithURL` `nil` → `CaptureError.unreadableImage(destination)`.
- `Bundle.main.bundleIdentifier` `swift test` sürecinde **`nil`**; `UNUserNotificationCenter.current()` bundle id'siz süreçte trap ettiği için izin servisi bu çağrıyı bundle id kontrolünün arkasına alır.
- Boşluk içeren hedef yolları `Process.arguments` ile sorunsuz (shell yok, quoting gerekmiyor).

---

### Task 1: `TestPaths`, test yardımcıları ve `ImageInfo`

PNG'nin piksel boyutu ve Retina ölçeği, `ScreencaptureService`'in `CaptureResult` üretmesi için gereken tek veri. Bu yüzden ilk task saf okuma fonksiyonunu ve fixture yolunu kuruyor.

**Files:**
- Create: `Tests/ShotcueCaptureTests/TestPaths.swift`
- Create: `Tests/ShotcueCaptureTests/CaptureTestSupport.swift`
- Create: `Tests/ShotcueCaptureTests/ImageInfoTests.swift`
- Create: `Sources/ShotcueCapture/ImageInfo.swift`

**Interfaces:**
- Consumes: Plan 00 Task 0'ın fixture'ı `Tests/Fixtures/sample.png` (64×64 piksel, DPI 144 — `scripts/make-fixture-png.swift` ile üretildi). Core'dan hiçbir tip kullanılmaz; bu dosya yalnızca `Foundation` + `CoreGraphics` + `ImageIO` import eder.
- Produces:
  - `public enum ImageInfo` · `public static func read(url: URL) -> (width: Int, height: Int, scale: Double)?`
  - Test yardımcıları (aynı test target'ındaki diğer dosyalar kullanır): `TestPaths.fixtures: URL`, `TestPaths.fixture(_ name: String) -> URL`, `func scratchURL(_ ext: String) -> URL`

- [ ] **Step 1: Test yardımcılarını ve başarısız testi yaz**

`Tests/ShotcueCaptureTests/TestPaths.swift` (Plan 00 Task 0 Step 3'teki dosyanın birebir kopyası; Plan 00 bunu zaten bırakmış olabilir, o zaman içerik aynı olduğu için üzerine yazmak güvenli):
```swift
import Foundation

enum TestPaths {
    /// Tests/Fixtures dizini. Her test target'ı Tests/<Target>Tests/ altında olduğu için iki üst dizin.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestPaths.swift
            .deletingLastPathComponent()   // <Target>Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
}
```

`Tests/ShotcueCaptureTests/CaptureTestSupport.swift`:
```swift
import Foundation

/// Unique path under the system temp dir. Nothing is created; the caller writes (or expects nothing).
func scratchURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shotcue-capture-test-\(UUID().uuidString).\(ext)")
}
```

`Tests/ShotcueCaptureTests/ImageInfoTests.swift`:
```swift
import Foundation
import Testing
@testable import ShotcueCapture

@Suite("ImageInfo")
struct ImageInfoTests {
    /// sample.png is 64x64 pixels written with 144 dpi, so the Retina scale is 144/72 = 2.
    @Test func readsPixelSizeAndRetinaScale() throws {
        let info = try #require(ImageInfo.read(url: TestPaths.fixture("sample.png")))
        #expect(info.width == 64)
        #expect(info.height == 64)
        #expect(info.scale == 2.0)
    }

    @Test func returnsNilForNonImageFile() throws {
        let url = scratchURL("txt")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImageInfo.read(url: url) == nil)
    }

    @Test func returnsNilForMissingFile() {
        #expect(ImageInfo.read(url: URL(fileURLWithPath: "/nope/missing.png")) == nil)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=ImageInfoTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'ImageInfo' in scope`.

Eğer bunun yerine `external macro implementation type 'TestingMacros...' could not be found` çıkarsa bu modül kurallarında anlatılan build flake'idir: komutu bir kez daha çalıştır, hâlâ sürüyorsa `rm -rf .build`. Kodla ilgisi yok.

- [ ] **Step 3: `ImageInfo`'yu yaz**

`Sources/ShotcueCapture/ImageInfo.swift`:
```swift
import CoreGraphics
import Foundation
import ImageIO

/// Pixel size and Retina scale read straight out of the image metadata.
/// `screencapture` writes DPI (144 on a 2x display), so the scale never has to be guessed from
/// `NSScreen.backingScaleFactor` — the only correct source on mixed-DPI setups (spec §6.1, research §7.4).
public enum ImageInfo {
    /// nil when the file is missing or ImageIO cannot parse it as an image.
    public static func read(url: URL) -> (width: Int, height: Int, scale: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // No DPI in the file (thumbnails we write ourselves, screencapture with -r) means 1x.
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double
        let scale = dpi.map { $0 > 0 ? $0 / 72 : 1 } ?? 1
        return (width: width, height: height, scale: scale)
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=ImageInfoTests 2>&1 | tail -3`
Expected: `Test run with 3 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCapture/ImageInfo.swift Tests/ShotcueCaptureTests/TestPaths.swift Tests/ShotcueCaptureTests/CaptureTestSupport.swift Tests/ShotcueCaptureTests/ImageInfoTests.swift
git commit -m "feat(capture): read pixel size and Retina scale from image metadata

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `CaptureError` ve `ScreencaptureService`

Modülün kalbi: `/usr/sbin/screencapture -i -s -x -t png <hedef>` alt süreci. Üç sonuç yolu (başarı / iptal / hata) spec §6.1 ve araştırma §2.3'ten birebir gelir. Fake, argümanları kaydedemediği için argüman listesi ayrı bir saf fonksiyonda (`arguments(for:)`) test edilir.

**Files:**
- Create: `Sources/ShotcueCapture/CaptureError.swift`
- Create: `Sources/ShotcueCapture/ScreencaptureService.swift`
- Create: `Tests/ShotcueCaptureTests/ScreencaptureServiceTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10, birebir):
  ```swift
  public struct CaptureResult: Hashable, Sendable {
      public var fileURL: URL
      public var width: Int
      public var height: Int
      public var scale: Double
      public init(fileURL: URL, width: Int, height: Int, scale: Double)
  }

  public protocol CaptureService: Sendable {
      func captureRegion(to destination: URL) async throws -> CaptureResult?
  }
  ```
  Ayrıca Task 1'in `ImageInfo.read(url:)`'i ve Plan 00 Task 0'ın `Tests/Fixtures/fake-screencapture.sh` fixture'ı (`FAKE_SCREENCAPTURE_SCENARIO=success|cancel|error`; `success` `sample.png`'i son argümandaki yola kopyalar, `cancel` boş stderr ile `exit 1`, `error` bir satır stderr ile `exit 2`).
- Produces:
  - `public enum CaptureError: Error, Equatable, Sendable` · `case screencaptureFailed(exitCode: Int32, stderr: String)` · `case unreadableImage(URL)` · `case launchFailed(String)`
  - `public struct ScreencaptureService: CaptureService` · `public init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"), environment: [String: String]? = nil)` · `public static func arguments(for destination: URL) -> [String]` · `public let executableURL: URL` · `public let environment: [String: String]?`

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCaptureTests/ScreencaptureServiceTests.swift`:
```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueCapture

@Suite("ScreencaptureService")
struct ScreencaptureServiceTests {
    /// The fake replaces /usr/sbin/screencapture; the scenario comes from the environment.
    func service(_ scenario: String) -> ScreencaptureService {
        ScreencaptureService(
            executableURL: TestPaths.fixture("fake-screencapture.sh"),
            environment: ["FAKE_SCREENCAPTURE_SCENARIO": scenario])
    }

    @Test func buildsExactArgumentList() {
        #expect(
            ScreencaptureService.arguments(for: URL(fileURLWithPath: "/tmp/a b/shot.png"))
                == ["-i", "-s", "-x", "-t", "png", "/tmp/a b/shot.png"])
    }

    @Test func defaultExecutableIsSystemScreencapture() {
        #expect(ScreencaptureService().executableURL.path == "/usr/sbin/screencapture")
    }

    @Test func successCopiesFileAndReportsRetinaSize() async throws {
        let destination = scratchURL("png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try #require(await service("success").captureRegion(to: destination))
        #expect(result == CaptureResult(fileURL: destination, width: 64, height: 64, scale: 2.0))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// ESC in the real tool: exit 1 with empty stderr. Not an error, and nothing is left on disk.
    @Test func cancelReturnsNilAndLeavesNoFile() async throws {
        let destination = scratchURL("png")
        #expect(try await service("cancel").captureRegion(to: destination) == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func errorThrowsWithExitCodeAndStderr() async {
        let destination = scratchURL("png")
        await #expect(
            throws: CaptureError.screencaptureFailed(
                exitCode: 2, stderr: "screencapture: could not create image")
        ) {
            try await service("error").captureRegion(to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func missingExecutableThrowsLaunchFailed() async throws {
        let service = ScreencaptureService(executableURL: URL(fileURLWithPath: "/nope/missing"))
        let destination = scratchURL("png")
        let error = await #expect(throws: CaptureError.self) {
            try await service.captureRegion(to: destination)
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed, got \(String(describing: error))")
            return
        }
    }

    /// Exit 0 but no readable PNG (disk full, tool changed): a hard error, not a silent success.
    @Test func zeroExitWithUnreadableFileThrows() async {
        let destination = scratchURL("png")
        let service = ScreencaptureService(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        await #expect(throws: CaptureError.unreadableImage(destination)) {
            try await service.captureRegion(to: destination)
        }
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=ScreencaptureServiceTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'ScreencaptureService' in scope`.

- [ ] **Step 3: `CaptureError`'ı yaz**

`Sources/ShotcueCapture/CaptureError.swift`:
```swift
import Foundation

/// Failures of the ShotcueCapture module. The UI shows `stderr` verbatim (spec §8:
/// "screencapture hata → Bildirim + log; task oluşturulmaz").
public enum CaptureError: Error, Equatable, Sendable {
    /// screencapture exited non-zero for a reason other than the user pressing ESC.
    case screencaptureFailed(exitCode: Int32, stderr: String)
    /// The file exists (or was just written) but ImageIO cannot read it as an image.
    case unreadableImage(URL)
    /// The child process could not be spawned at all: missing binary, not executable.
    case launchFailed(String)
}
```

- [ ] **Step 4: `ScreencaptureService`'i yaz**

`Sources/ShotcueCapture/ScreencaptureService.swift`:
```swift
import Foundation
import ShotcueCore

/// Region screenshot via `/usr/sbin/screencapture -i -s -x -t png <destination>` (spec §6.1).
///
/// The tool has `com.apple.private.tcc.check-allow-on-responsible-process`, so TCC is evaluated
/// against the *responsible* process: spawned from Shotcue.app the system prompt names Shotcue
/// and Shotcue's own Screen & System Audio Recording grant is what counts (research §2.2).
///
/// Result mapping (research §2.3): exit 0 → success; exit 1 with empty stderr → the user pressed
/// ESC, which is a cancel and not an error; anything else → a real failure worth showing.
public struct ScreencaptureService: CaptureService {
    public let executableURL: URL
    /// nil inherits the parent environment. Tests pass FAKE_SCREENCAPTURE_SCENARIO here.
    public let environment: [String: String]?

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.environment = environment
    }

    /// Kept pure and separate so the exact command line can be asserted without spawning anything
    /// (the fake script cannot record its argv).
    ///   -i interactive · -s mouse selection only (no window mode) · -x no shutter sound
    ///   -t png master format · last argument is the output path
    public static func arguments(for destination: URL) -> [String] {
        ["-i", "-s", "-x", "-t", "png", destination.path]
    }

    public func captureRegion(to destination: URL) async throws -> CaptureResult? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.arguments(for: destination)
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Drain stderr concurrently. Waiting for exit first would deadlock if the child ever
        // filled the 64 KB pipe buffer; reading first would block this task for the whole
        // (interactive, unbounded) selection.
        let readEnd = errorPipe.fileHandleForReading
        let stderrTask = Task.detached(priority: .utility) { () -> Data in
            ((try? readEnd.readToEnd()) ?? nil) ?? Data()
        }

        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(
                        throwing: CaptureError.launchFailed(String(describing: error)))
                }
            }
        } catch {
            stderrTask.cancel()
            throw error
        }

        let stderrText = String(decoding: await stderrTask.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if exitCode == 0 {
            guard let info = ImageInfo.read(url: destination) else {
                try? FileManager.default.removeItem(at: destination)
                throw CaptureError.unreadableImage(destination)
            }
            return CaptureResult(
                fileURL: destination, width: info.width, height: info.height, scale: info.scale)
        }

        // Cancel and failure both may have left a truncated PNG behind; never keep one.
        try? FileManager.default.removeItem(at: destination)
        if exitCode == 1, stderrText.isEmpty { return nil }
        throw CaptureError.screencaptureFailed(exitCode: exitCode, stderr: stderrText)
    }
}
```

- [ ] **Step 5: Testlerin geçtiğini gör**

Run: `make test FILTER=ScreencaptureServiceTests 2>&1 | tail -3`
Expected: `Test run with 7 tests in 1 suite passed`.

`cancel` senaryosu başarısız olup dosya kalıyorsa fixture'ın çalıştırılabilir olmadığına bak: `chmod +x Tests/Fixtures/*.sh` (Plan 00 Task 0 Step 9).

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcueCapture/CaptureError.swift Sources/ShotcueCapture/ScreencaptureService.swift Tests/ShotcueCaptureTests/ScreencaptureServiceTests.swift
git commit -m "feat(capture): wrap screencapture with cancel and failure detection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `ImageIOThumbnailService`

Kütüphane grid'i aynı anda yüzlerce thumbnail istiyor; naif `NSImage` resize yerine `CGImageSourceCreateThumbnailAtIndex` (~30x hızlı, araştırma §7.2) ve iş her zaman main thread dışında.

**Files:**
- Create: `Sources/ShotcueCapture/ImageIOThumbnailService.swift`
- Create: `Tests/ShotcueCaptureTests/ImageIOThumbnailServiceTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10, birebir):
  ```swift
  public protocol ThumbnailService: Sendable {
      /// Writes a JPEG whose longest side is `maxPixel`.
      func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws
  }
  ```
  Ayrıca Task 1'in `ImageInfo.read(url:)`'i (test tarafında boyut doğrulaması için) ve Task 2'nin hata tipi:
  ```swift
  public enum CaptureError: Error, Equatable, Sendable {
      case screencaptureFailed(exitCode: Int32, stderr: String)
      case unreadableImage(URL)
      case launchFailed(String)
  }
  ```
- Produces: `public struct ImageIOThumbnailService: ThumbnailService` · `public init()`. Hata yolu: okunamayan kaynak veya yazılamayan hedef → `CaptureError.unreadableImage(_:)`. `maxPixel` protokolden gelen bir parametre; spec §6.1'in **512** değeri servise gömülmez, çağıran verir (Plan 06 `makeThumbnail(from:to:maxPixel: 512)` çağırır). Hedef dizini de çağıran hazırlar (`FileStore.ensureParentDirectory(for:)`); servis dizin oluşturmaz, eksik dizini hata olarak bildirir.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCaptureTests/ImageIOThumbnailServiceTests.swift`:
```swift
import Foundation
import ImageIO
import Testing
@testable import ShotcueCapture

@Suite("ImageIOThumbnailService")
struct ImageIOThumbnailServiceTests {
    @Test func writesJPEGWithinMaxPixel() async throws {
        let destination = scratchURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await ImageIOThumbnailService()
            .makeThumbnail(from: TestPaths.fixture("sample.png"), to: destination, maxPixel: 32)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let info = try #require(ImageInfo.read(url: destination))
        #expect(info.width <= 32)
        #expect(info.height <= 32)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    /// ImageIO never upscales: a 64x64 source with maxPixel 512 stays 64x64.
    @Test func largerMaxPixelDoesNotUpscale() async throws {
        let destination = scratchURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await ImageIOThumbnailService()
            .makeThumbnail(from: TestPaths.fixture("sample.png"), to: destination, maxPixel: 512)
        let info = try #require(ImageInfo.read(url: destination))
        #expect(info.width == 64 && info.height == 64)
    }

    @Test func throwsForUnreadableSource() async {
        let destination = scratchURL("jpg")
        await #expect(throws: CaptureError.unreadableImage(URL(fileURLWithPath: "/nope/missing.png")))
        {
            try await ImageIOThumbnailService()
                .makeThumbnail(
                    from: URL(fileURLWithPath: "/nope/missing.png"),
                    to: destination, maxPixel: 32)
        }
    }

    /// The caller owns the directory (FileStore.ensureParentDirectory); a missing one is an error.
    @Test func throwsWhenDestinationDirectoryMissing() async {
        let destination = URL(fileURLWithPath: "/nope/deep/thumb.jpg")
        await #expect(throws: CaptureError.unreadableImage(destination)) {
            try await ImageIOThumbnailService()
                .makeThumbnail(from: TestPaths.fixture("sample.png"), to: destination, maxPixel: 32)
        }
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=ImageIOThumbnailServiceTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'ImageIOThumbnailService' in scope`.

- [ ] **Step 3: `ImageIOThumbnailService`'i yaz**

`Sources/ShotcueCapture/ImageIOThumbnailService.swift`:
```swift
import CoreGraphics
import Foundation
import ImageIO
import ShotcueCore
import UniformTypeIdentifiers

/// JPEG thumbnails via ImageIO — roughly 30x faster than redrawing through NSImage
/// (~26 ms for a 12 MP source, research §7.2). Always off the main thread: the library grid
/// asks for a hundred of these at once.
///
/// JPEG at quality 0.8 is fine here because the thumbnail is only ever a grid tile; the master
/// screenshot stays PNG so text edges survive for Claude to read (research §7.1).
public struct ImageIOThumbnailService: ThumbnailService {
    public init() {}

    public func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws {
        try await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                // Always decode from the full image: an embedded EXIF thumbnail may be tiny or absent.
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    imageSource, 0, options as CFDictionary)
            else { throw CaptureError.unreadableImage(source) }

            // Returns nil when the parent directory is missing or not writable.
            guard let output = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw CaptureError.unreadableImage(destination) }
            CGImageDestinationAddImage(
                output, thumbnail,
                [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(output) else {
                throw CaptureError.unreadableImage(destination)
            }
        }.value
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=ImageIOThumbnailServiceTests 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCapture/ImageIOThumbnailService.swift Tests/ShotcueCaptureTests/ImageIOThumbnailServiceTests.swift
git commit -m "feat(capture): generate JPEG thumbnails with ImageIO off the main thread

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `SystemPermissionService`

Spec §6.1 ve §9'daki üç izin: Ekran Kaydı (yakalama için şart), Mikrofon (sesli not), Bildirim (run bitti). Testler TCC diyaloğu açamaz, bu yüzden deterministik olan iki şey test edilir: her `PermissionKind` için `state(of:)` çökmeden bir `PermissionState` döndürüyor ve `settingsURL(for:)` eşlemesi doğru.

**Files:**
- Create: `Sources/ShotcueCapture/SystemPermissionService.swift`
- Create: `Tests/ShotcueCaptureTests/SystemPermissionServiceTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10, birebir):
  ```swift
  public enum PermissionKind: String, Sendable, Codable, CaseIterable {
      case screenRecording, microphone, notifications
  }

  public enum PermissionState: String, Sendable, Codable {
      case notDetermined, granted, denied
  }

  public protocol PermissionService: Sendable {
      func state(of kind: PermissionKind) async -> PermissionState
      /// Triggers the system prompt when possible; returns the resulting state.
      func request(_ kind: PermissionKind) async -> PermissionState
      func openSystemSettings(for kind: PermissionKind)
  }
  ```
- Produces: `public struct SystemPermissionService: PermissionService` · `public init()` · `public static func settingsURL(for kind: PermissionKind) -> URL` (saf, test edilebilir). Plan 06 onboarding'i `state(of: .screenRecording)` → `.notDetermined` görünce `request(.screenRecording)` çağırır, sonuç `.denied` ise `openSystemSettings(for: .screenRecording)` gösterir.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCaptureTests/SystemPermissionServiceTests.swift`:
```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueCapture

@Suite("SystemPermissionService")
struct SystemPermissionServiceTests {
    @Test func settingsURLsMatchSpec() {
        #expect(
            SystemPermissionService.settingsURL(for: .screenRecording).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(
            SystemPermissionService.settingsURL(for: .microphone).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(
            SystemPermissionService.settingsURL(for: .notifications).absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    /// Reading state must never prompt and never trap. In `swift test` there is no bundle
    /// identifier, which is exactly the case UNUserNotificationCenter cannot survive.
    @Test func everyKindReportsAStateWithoutPrompting() async {
        let service = SystemPermissionService()
        for kind in PermissionKind.allCases {
            let state = await service.state(of: kind)
            #expect([PermissionState.notDetermined, .granted, .denied].contains(state))
        }
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=SystemPermissionServiceTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'SystemPermissionService' in scope`.

- [ ] **Step 3: `SystemPermissionService`'i yaz**

`Sources/ShotcueCapture/SystemPermissionService.swift`:
```swift
import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ShotcueCore
import UserNotifications

/// TCC state plus the System Settings deep links (spec §6.1, §9; research §4).
///
/// `CGPreflightScreenCaptureAccess` never prompts. `CGRequestScreenCaptureAccess` prompts once and
/// a previously denied process is *not* re-prompted — the user has to flip the switch in
/// System Settings, which is why `openSystemSettings(for:)` exists. After a grant the app must be
/// relaunched (research §4.1); Plan 06 owns that relaunch.
///
/// The monthly re-consent dialog on macOS 26 is expected behaviour and cannot be turned off
/// (research §4.2); Settings > İzinler explains it to the user.
public struct SystemPermissionService: PermissionService {
    public init() {}

    /// Pure mapping so it is testable without opening anything.
    public static func settingsURL(for kind: PermissionKind) -> URL {
        switch kind {
        case .screenRecording:
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .microphone:
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
    }

    public func state(of kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            // TCC exposes no "denied" here: a denial and "never asked" both preflight as false.
            // The UI therefore always offers both "İzin ver" and the System Settings link.
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .notifications:
            // UNUserNotificationCenter.current() traps in a process without a bundle identifier,
            // and `swift test` has none (verified). Tests see .notDetermined instead of a crash.
            guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                return granted ? .granted : .denied
            } catch {
                return .denied
            }
        }
    }

    public func openSystemSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(Self.settingsURL(for: kind))
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=SystemPermissionServiceTests 2>&1 | tail -3`
Expected: `Test run with 2 tests in 1 suite passed`. Hiçbir izin diyaloğu çıkmaz; `state(of:)` yalnızca okur.

- [ ] **Step 5: Gerçek TCC akışını elle doğrula (manuel, Plan 06 ile tekrar edilecek)**

Run: `make run` sonrası bundle'dan `SHOTCUE_SPIKE=capture` ile (Plan 00 Task 11 Step 4'teki komut) bir yakalama dene.
Expected: Plan 00 Task 11 bunu S3 olarak zaten doğruladı (`docs/superpowers/plans/spike-results.md`): izin diyaloğu Shotcue adına çıkıyor, `Esc` → `exit=1`, bölge seçince `exit=0`, ve S2 gereği self-signed imzayla izin rebuild sonrası korunuyor. Burada yalnızca o kaydın hâlâ geçerli olduğu kontrol edilir: `grep -E "S2|S3" docs/superpowers/plans/spike-results.md`. Kayıt yoksa Plan 00 Task 11 tamamlanmamıştır; bu planı durdur ve raporla.

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcueCapture/SystemPermissionService.swift Tests/ShotcueCaptureTests/SystemPermissionServiceTests.swift
git commit -m "feat(capture): report TCC state and open the matching settings pane

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `CarbonHotKeyService`

Global kısayol için tek izin istemeyen yol Carbon `RegisterEventHotKey` (araştırma §5: `NSEvent.addGlobalMonitorForEvents` Accessibility, `CGEvent.tapCreate` Input Monitoring ister). `sindresorhus/KeyboardShortcuts` kaynağında `#Preview` olduğu için CLT'de derlenmiyor ve Global Constraints gereği elendi; bu yüzden sarmalayıcıyı kendimiz yazıyoruz.

En kritik kısım Swift closure'ının C dünyasına taşınması: `EventHandlerUPP` bir C fonksiyon pointer'ı olduğu için context capture edemez. Closure bir sınıf kutusuna (`HotKeyHandlerBox`) konur, kutunun opak pointer'ı `InstallEventHandler`'ın `inUserData` parametresiyle Carbon'a verilir ve handler içinde `Unmanaged.fromOpaque` ile geri alınır. Kutuyu servis `box` alanında tuttuğu sürece `passUnretained` güvenlidir (Carbon pointer'ı bizden uzun yaşamaz çünkü `unregister()`/`deinit` handler'ı kaldırır).

**Files:**
- Create: `Sources/ShotcueCapture/CarbonHotKeyService.swift`
- Create: `Tests/ShotcueCaptureTests/CarbonHotKeyServiceTests.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10 + Task 3, birebir):
  ```swift
  /// Global hotkey (Carbon RegisterEventHotKey in Plan 02). One combo at a time.
  public protocol HotKeyService: Sendable {
      func register(_ combo: KeyCombo, handler: @escaping @Sendable () -> Void) throws
      func unregister()
  }

  public struct KeyCombo: Hashable, Sendable, Codable {
      public var keyCode: UInt32      // Carbon virtual key code, e.g. 0x13 = kVK_ANSI_2
      public var modifiers: UInt32    // Carbon modifier mask, e.g. controlKey | shiftKey
      public var label: String        // "⌃⇧2"
      public init(keyCode: UInt32, modifiers: UInt32, label: String)
      public static let commandKey: UInt32 = 1 << 8
      public static let shiftKey: UInt32 = 1 << 9
      public static let optionKey: UInt32 = 1 << 11
      public static let controlKey: UInt32 = 1 << 12
      public static let presets: [KeyCombo]     // 6 items, labels ⌃⇧2 ⌃⇧3 ⌃⇧4 ⌘⇧2 ⌥Space ⌃⌥Space
      public static let defaultCombo: KeyCombo  // presets[0] = ⌃⇧2
  }
  ```
  `keyCode` ve `modifiers` Core'da **zaten Carbon değerleri** olarak tutuluyor (Plan 00 Task 3 `KeyComboTests.carbonMasksMatchHIToolbox` bunu kilitliyor), bu yüzden hiçbir dönüşüm yapılmaz — doğrudan `RegisterEventHotKey`'e geçirilir.
- Produces:
  - `public enum HotKeyError: Error, Equatable, Sendable` · `case registrationFailed(OSStatus)`
  - `public final class CarbonHotKeyService: HotKeyService, @unchecked Sendable` · `public init()` · `public var registeredCombo: KeyCombo?` (test ve Ayarlar için; `unregister()` sonrası `nil`)
  - Davranış sözleşmesi: `register` ikinci kez çağrıldığında öncekini **değiştirir**; handler main queue'da çağrılır; `unregister()` idempotent'tir; kayıt sırasında sıfır olmayan `OSStatus` → `HotKeyError.registrationFailed`.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCaptureTests/CarbonHotKeyServiceTests.swift` (bu dosya Carbon'u import **etmez**; `-9878` = `eventHotKeyExistsErr`):
```swift
import Foundation
import ShotcueCore
import Testing
@testable import ShotcueCapture

/// Actual key delivery cannot be tested headlessly: Carbon needs a real application event target
/// with a running event loop, and no permission exists to synthesise a system-wide key press.
/// It is verified manually in Plan 06 with `make run` (press ⌃⇧2, the quick panel must open).
/// These tests cover registration, replacement and teardown, which is where the bugs live.
@Suite("CarbonHotKeyService")
struct CarbonHotKeyServiceTests {
    @MainActor
    @Test func registersAndUnregistersDefaultCombo() throws {
        let service = CarbonHotKeyService()
        #expect(service.registeredCombo == nil)
        try service.register(.defaultCombo) {}
        #expect(service.registeredCombo == KeyCombo.defaultCombo)
        service.unregister()
        #expect(service.registeredCombo == nil)
    }

    @MainActor
    @Test func secondRegistrationReplacesTheFirst() throws {
        let service = CarbonHotKeyService()
        try service.register(KeyCombo.presets[0]) {}
        try service.register(KeyCombo.presets[1]) {}
        #expect(service.registeredCombo == KeyCombo.presets[1])
        service.unregister()
    }

    @MainActor
    @Test func unregisterIsIdempotentAndReRegistrationWorks() throws {
        let service = CarbonHotKeyService()
        service.unregister()
        try service.register(.defaultCombo) {}
        service.unregister()
        service.unregister()
        try service.register(.defaultCombo) {}
        #expect(service.registeredCombo == KeyCombo.defaultCombo)
        service.unregister()
    }

    /// Carbon refuses a combo another registration already holds: -9878 eventHotKeyExistsErr.
    /// The failed service must be left clean so the UI can offer a different preset.
    @MainActor
    @Test func duplicateComboReportsCarbonStatus() throws {
        let holder = CarbonHotKeyService()
        try holder.register(.defaultCombo) {}
        defer { holder.unregister() }
        let second = CarbonHotKeyService()
        #expect(throws: HotKeyError.registrationFailed(OSStatus(-9878))) {
            try second.register(.defaultCombo) {}
        }
        #expect(second.registeredCombo == nil)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=CarbonHotKeyServiceTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'CarbonHotKeyService' in scope`.

- [ ] **Step 3: `CarbonHotKeyService`'i yaz**

`Sources/ShotcueCapture/CarbonHotKeyService.swift`:
```swift
import Carbon.HIToolbox
import Foundation
import ShotcueCore

public enum HotKeyError: Error, Equatable, Sendable {
    /// Non-zero OSStatus from InstallEventHandler or RegisterEventHotKey.
    /// -9878 (eventHotKeyExistsErr) means something else already owns that combination.
    case registrationFailed(OSStatus)
}

/// Retains the Swift closure so Carbon can carry it as opaque userData.
/// EventHandlerUPP is a C function pointer and cannot capture context.
private final class HotKeyHandlerBox {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
}

/// Global hotkey through Carbon `RegisterEventHotKey` — the only mechanism that needs no TCC
/// permission at all. `NSEvent.addGlobalMonitorForEvents` would need Accessibility and
/// `CGEvent.tapCreate` Input Monitoring, and both would see every keystroke (research §5).
///
/// One combination at a time (spec §6.1). Registering again replaces the previous registration,
/// because Carbon rejects a second registration of the same combo with eventHotKeyExistsErr.
public final class CarbonHotKeyService: HotKeyService, @unchecked Sendable {
    private let lock = NSLock()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var box: HotKeyHandlerBox?
    private var combo: KeyCombo?

    /// 'SHTC' — lets the handler ignore hotkeys registered by anything else in this process.
    private static let signature: OSType = 0x5348_5443

    public init() {}

    /// The combination Carbon currently holds; nil before `register` and after `unregister`.
    /// Settings shows it, and the tests assert on it.
    public var registeredCombo: KeyCombo? { lock.withLock { combo } }

    public func register(_ combo: KeyCombo, handler: @escaping @Sendable () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()

        let newBox = HotKeyHandlerBox(handler)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // Captures nothing: it reads the box back out of userData, so it converts to a C pointer.
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == CarbonHotKeyService.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let handler = Unmanaged<HotKeyHandlerBox>.fromOpaque(userData)
                .takeUnretainedValue().handler
            // The handler opens the quick panel: AppKit work, main queue only.
            DispatchQueue.main.async { handler() }
            return noErr
        }

        var newEventHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(newBox).toOpaque(), &newEventHandler)
        guard installStatus == noErr else { throw HotKeyError.registrationFailed(installStatus) }

        var newHotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        // keyCode and modifiers are already Carbon values in Core (KeyCombo), no conversion.
        let registerStatus = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newHotKeyRef)
        guard registerStatus == noErr, let newHotKeyRef else {
            if let newEventHandler { RemoveEventHandler(newEventHandler) }
            throw HotKeyError.registrationFailed(registerStatus)
        }

        // Holding the box keeps the closure alive for as long as Carbon holds the raw pointer.
        box = newBox
        eventHandler = newEventHandler
        hotKeyRef = newHotKeyRef
        self.combo = combo
    }

    public func unregister() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    deinit { teardownLocked() }

    /// Caller holds `lock` (or is deinit, where no other reference can exist).
    private func teardownLocked() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        box = nil
        combo = nil
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=CarbonHotKeyServiceTests 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

`external macro implementation type 'TestingMacros...' could not be found` hatası görürsen test dosyasına yanlışlıkla `import Carbon.HIToolbox` eklemiş olabilirsin; kaldır (modül kuralları), `rm -rf .build` ile temizle ve tekrar çalıştır.

- [ ] **Step 5: Gerçek tuş tesliminin manuel doğrulanacağını kayda geç**

`Sources/ShotcueCapture/CarbonHotKeyService.swift` içindeki sınıf yorumunun altına bir satır ekle:
```swift
// Manual verification (Plan 06, `make run`): press ⌃⇧2 while another app is frontmost; the quick
// panel must open without Shotcue stealing focus. Headless tests cannot cover key delivery.
```

Run: `grep -n "Manual verification" Sources/ShotcueCapture/CarbonHotKeyService.swift`
Expected: bir satır eşleşir.

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcueCapture/CarbonHotKeyService.swift Tests/ShotcueCaptureTests/CarbonHotKeyServiceTests.swift
git commit -m "feat(capture): register a global hotkey with Carbon RegisterEventHotKey

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `PasteboardWriter`

Spec §5.1 adım 3: "Ayar açıksa PNG panoya da kopyalanır". Araştırma §7.5: iki temsili birden yaz — PNG byte'ları (Slack, Notion, Figma) ve dosya URL'i (Finder, Mail). `NSPasteboard` main-thread-only olduğu için API `@MainActor`.

**Files:**
- Create: `Sources/ShotcueCapture/PasteboardWriter.swift`
- Create: `Tests/ShotcueCaptureTests/PasteboardWriterTests.swift`

**Interfaces:**
- Consumes: Core'dan hiçbir tip; yalnızca `AppKit` + `Foundation`. Test fixture'ı `Tests/Fixtures/sample.png`.
- Produces: `public enum PasteboardWriter` · `@MainActor public static func copyPNG(at url: URL) -> Bool`. `false` yalnızca dosya okunamadığında veya pano yazımı reddedildiğinde döner; çağıran (Plan 06) `false` durumunda sessizce geçer, yakalama iptal edilmez.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCaptureTests/PasteboardWriterTests.swift`:
```swift
import AppKit
import Foundation
import Testing
@testable import ShotcueCapture

@Suite("PasteboardWriter")
struct PasteboardWriterTests {
    /// Both representations must land: consumers pick whichever they understand (research §7.5).
    @MainActor
    @Test func writesPNGDataAndFileURL() {
        let url = TestPaths.fixture("sample.png")
        #expect(PasteboardWriter.copyPNG(at: url) == true)
        #expect(NSPasteboard.general.data(forType: .png) != nil)
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        #expect(urls.contains { $0.lastPathComponent == "sample.png" })
    }

    @MainActor
    @Test func returnsFalseForMissingFile() {
        #expect(PasteboardWriter.copyPNG(at: URL(fileURLWithPath: "/nope/missing.png")) == false)
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=PasteboardWriterTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'PasteboardWriter' in scope`.

- [ ] **Step 3: `PasteboardWriter`'ı yaz**

`Sources/ShotcueCapture/PasteboardWriter.swift`:
```swift
import AppKit
import Foundation

/// Copies a capture to the clipboard in both flavours at once: PNG bytes for Slack/Notion/Figma,
/// the file URL for Finder/Mail. Whichever the consumer asks for, it is there (research §7.5).
public enum PasteboardWriter {
    /// false when the file cannot be read or the pasteboard refused the write; the caller treats
    /// that as "no clipboard copy", never as a failed capture (spec §5.1 step 3 is optional).
    @MainActor
    public static func copyPNG(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wroteData = pasteboard.setData(data, forType: .png)
        let wroteURL = pasteboard.writeObjects([url as NSURL])
        return wroteData && wroteURL
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=PasteboardWriterTests 2>&1 | tail -3`
Expected: `Test run with 2 tests in 1 suite passed`. (Bu test makinenin panosunu gerçekten değiştirir; beklenen davranış.)

- [ ] **Step 5: Tüm modülün testlerini çalıştır**

Run: `make test FILTER=ShotcueCaptureTests 2>&1 | tail -4`
Expected: `Test run with 23 tests in 7 suites passed` (Plan 00'ın `CaptureSmokeTests`'i dahil: 1 + 3 + 7 + 4 + 2 + 4 + 2).

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcueCapture/PasteboardWriter.swift Tests/ShotcueCaptureTests/PasteboardWriterTests.swift
git commit -m "feat(capture): copy a capture to the pasteboard as PNG and file URL

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Plan 02 tamamlanma ölçütü

- `make test FILTER=ShotcueCaptureTests` → **23 test, 7 suite, hepsi yeşil**; çalıştırma sırasında hiçbir TCC izin diyaloğu çıkmaz, gerçek `screencapture` çalışmaz.
- `make test` → tüm paket yeşil; Plan 00'ın Core testleri ve diğer modüllerin smoke testleri bozulmamış.
- `Sources/ShotcueCapture/` altında şu altı public tip var ve **hepsi Plan 00 Task 10'daki imzalara birebir uyuyor** (isim veya parametre sapması yok):
  | Tip | Initializer | Karşıladığı Core protokolü |
  |---|---|---|
  | `ScreencaptureService` | `init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"), environment: [String: String]? = nil)` | `CaptureService` |
  | `ImageIOThumbnailService` | `init()` | `ThumbnailService` |
  | `SystemPermissionService` | `init()` | `PermissionService` |
  | `CarbonHotKeyService` | `init()` | `HotKeyService` |
  | `ImageInfo` (enum, örneklenmez) | — | — (yardımcı) |
  | `PasteboardWriter` (enum, örneklenmez) | — | — (yardımcı) |
  Hata tipleri: `CaptureError` (`screencaptureFailed(exitCode:stderr:)`, `unreadableImage(_:)`, `launchFailed(_:)`), `HotKeyError` (`registrationFailed(_:)`).
- `grep -rn "ScreenCaptureKit\|CGWindowListCreateImage\|CGDisplayCreateImage\|#Preview\|backingScaleFactor" Sources/ShotcueCapture/` → **boş** (yasak API'ler ve yasak ölçek kaynağı yok).
- `grep -rn "^import" Sources/ShotcueCapture/ | sed 's/.*import //' | sort -u` → yalnızca `AVFoundation`, `AppKit`, `Carbon.HIToolbox`, `CoreGraphics`, `Foundation`, `ImageIO`, `ShotcueCore`, `UniformTypeIdentifiers`, `UserNotifications`.
- `git diff --stat HEAD~6 -- Package.swift Sources/ShotcueCore Tests/Fixtures` → **boş** (bu plan başka planın dosyasına dokunmadı).
- Manuel doğrulamaya bırakılanlar, Plan 06 (`make run`) kontrol listesine yazılı: (a) `⌃⇧2` başka bir uygulama öndeyken hızlı paneli açıyor ve Shotcue odağı çalmıyor; (b) gerçek `screencapture -i -s` ile bölge seçimi `CaptureResult` üretiyor, `Esc` `nil` döndürüyor; (c) Ayarlar > İzinler'deki üç Sistem Ayarları linki doğru paneli açıyor; (d) Ekran Kaydı izni verildikten sonra uygulama yeniden başlatılıyor. S2/S3 zaten Plan 00 Task 11'de doğrulandı (`docs/superpowers/plans/spike-results.md`).
- Plan 02 bitince Plan 06 (App) `AppEnvironment`'ta `ScreencaptureService()`, `ImageIOThumbnailService()`, `SystemPermissionService()` ve `CarbonHotKeyService()` örneklerini doğrudan kullanabilir; yakalama → `FileStore` yolu → thumbnail → `ShotTask` kaydı zincirini kuran orkestrasyon **bu planın kapsamı dışıdır** (Plan 01 depoları + Plan 06 composition root).
