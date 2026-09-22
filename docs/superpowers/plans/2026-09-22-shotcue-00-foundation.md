# Shotcue v1 — Plan 00: Temel (iskelet + ShotcueCore)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shotcue SwiftPM paketinin iskeletini (Package.swift, Makefile, bundle/imza scriptleri, CLAUDE.md, test fixture'ları) ve hiçbir Apple framework'üne bağımlı olmayan `ShotcueCore` modülünü (modeller, servis protokolleri, durum makinesi, prompt üretici, stream-json ayrıştırıcı, zamanlayıcı kuralları, kuyruk politikası) testleriyle kurmak. Diğer beş plan (01 Persistence, 02 Capture, 03 Notes, 04 ClaudeBridge, 05 UI+App) bu planın ürettiği arayüzlere göre yazılmıştır ve **bu plan bitmeden başlamaz**; bittikten sonra 01–04 paralel yürütülebilir.

**Architecture:** Tek SwiftPM paketi, yedi target. `ShotcueCore` saf Swift (yalnızca Foundation); tüm servisler Core'daki protokollerin arkasında, her protokolün testte kullanılan bir fake'i var. UI ve App target'ları MainActor-varsayılan, servis target'ları nonisolated-varsayılan. Xcode yok: `swift build` / `swift test` tek döngü; `.app` bundle'ı `scripts/bundle.sh` üretir ve self-signed "Shotcue Dev" sertifikasıyla imzalar.

**Tech Stack:** Swift 6.4 (Command Line Tools 27.0, SDK 27.0), SwiftPM, Swift Testing, macOS 26.0 deployment target. Bağımlılıklar yalnızca `GRDB.swift` 7.11.x (ürün `GRDB`, Plan 01 kullanır) ve `argmax-oss-swift` 1.1.x (ürün `WhisperKit`, Plan 03 kullanır); ikisi de bu planda `Package.swift`'e girer ki diğer planlar manifesti değiştirmesin.

**Spec:** `docs/superpowers/specs/2026-09-22-shotcue-design.md` (araştırma: `docs/research/01…05`)

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

## Dosya haritası (bu planın ürettikleri)

```
Package.swift                                  # tüm target'lar ve iki bağımlılık (Task 0)
Makefile, scripts/{bundle.sh,install.sh,shot.sh,make-cert.sh,make-fixture-png.swift}
Resources/{Info.plist,Shotcue.entitlements}
CLAUDE.md                                      # ajan kuralları
Sources/ShotcueCore/
  Models/Project.swift            Project, DailyTime
  Models/ShotTask.swift           ShotTask, TaskMode, TaskStatus (+ geçiş kuralları)
  Models/Capture.swift            Capture
  Models/VoiceNote.swift          VoiceNote, TranscriptState, Transcript
  Models/Run.swift                Run, RunState, ClaudeRunResult, RunEvent
  Models/KeyCombo.swift           KeyCombo (+ hazır kombinasyonlar)
  Models/GitSnapshot.swift        GitSnapshot
  Logic/SortIndex.swift           fractional sıralama
  Logic/PromptBuilder.swift       Claude prompt'u + sabit sistem talimatı
  Logic/StreamJSONParser.swift    stream-json satırı → RunEvent
  Logic/SchedulerRules.swift      dueActions(now:…)
  Logic/QueuePolicy.swift         nextRunnable(…)
  Logic/TitleMaker.swift          otomatik başlık
  Services/*.swift                protokoller (CaptureService, ThumbnailService, PermissionService,
                                  HotKeyService, AudioRecorder, Transcriber, ClaudeRunner, GitInspector,
                                  Clock, Repositories, Notifier, HandoffService, FileStore)
Sources/ShotcuePersistence/ShotcuePersistence.swift   # yer tutucu (Plan 01 doldurur)
Sources/ShotcueCapture/ShotcueCapture.swift           # yer tutucu (Plan 02)
Sources/ShotcueNotes/ShotcueNotes.swift               # yer tutucu (Plan 03)
Sources/ShotcueClaudeBridge/ShotcueClaudeBridge.swift # yer tutucu (Plan 04)
Sources/ShotcueUI/ShotcueUI.swift                     # yer tutucu (Plan 05)
Sources/ShotcueApp/ShotcueApp.swift                   # minimal @main (Plan 05 genişletir)
Tests/ShotcueCoreTests/*.swift
Tests/{Persistence,Capture,Notes,ClaudeBridge,UI}Tests/SmokeTests.swift   # yer tutucu testler
Tests/Fixtures/{fake-claude.sh,fake-screencapture.sh,sample-stream.jsonl,sample.png}
```

---

### Task 0: Paket iskeleti, build/bundle altyapısı, fixture'lar, CLAUDE.md

**Files:**
- Create: `Package.swift`, `Makefile`, `CLAUDE.md`, `.swift-format`
- Create: `Resources/Info.plist`, `Resources/Shotcue.entitlements`
- Create: `scripts/bundle.sh`, `scripts/install.sh`, `scripts/shot.sh`, `scripts/make-cert.sh`, `scripts/make-fixture-png.swift`
- Create: `Sources/ShotcueCore/ShotcueCore.swift` ve her modül için bir yer tutucu dosya, `Sources/ShotcueApp/ShotcueApp.swift`
- Create: `Tests/ShotcueCoreTests/SmokeTests.swift`, diğer beş test target'ında `SmokeTests.swift`
- Create: `Tests/Fixtures/fake-claude.sh`, `Tests/Fixtures/fake-screencapture.sh`, `Tests/Fixtures/sample-stream.jsonl`, `Tests/Fixtures/sample.png`

**Interfaces:**
- Produces: `Package.swift` target adları (`ShotcueCore`, `ShotcuePersistence`, `ShotcueCapture`, `ShotcueNotes`, `ShotcueClaudeBridge`, `ShotcueUI`, `ShotcueApp`) ve test target'ları; `Tests/Fixtures/` yolu (her test target'ı `#filePath`'ten `Tests/Fixtures`'a ulaşır); `FAKE_CLAUDE_SCENARIO` / `FAKE_CLAUDE_ARGS_FILE` / `FAKE_SCREENCAPTURE_SCENARIO` ortam değişkenleri; `make build|test|bundle|install|run|shot|reset-tcc|format|clean`.

- [ ] **Step 1: Package.swift'i yaz**

```swift
// swift-tools-version: 6.4
import PackageDescription

let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]
let uiSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)] + upcoming
let serviceSettings: [SwiftSetting] = [.defaultIsolation(nil)] + upcoming

let package = Package(
    name: "Shotcue",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Shotcue", targets: ["ShotcueApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "ShotcueCore", swiftSettings: serviceSettings),
        .target(
            name: "ShotcuePersistence",
            dependencies: ["ShotcueCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: serviceSettings),
        .target(name: "ShotcueCapture", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        .target(
            name: "ShotcueNotes",
            dependencies: ["ShotcueCore", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            swiftSettings: serviceSettings),
        .target(name: "ShotcueClaudeBridge", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        .target(name: "ShotcueUI", dependencies: ["ShotcueCore"], swiftSettings: uiSettings),
        // Fakes of every Core protocol, shared by all test targets (never linked into the app).
        .target(name: "ShotcueTestSupport", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        .executableTarget(
            name: "ShotcueApp",
            dependencies: [
                "ShotcueCore", "ShotcueUI", "ShotcuePersistence", "ShotcueCapture",
                "ShotcueNotes", "ShotcueClaudeBridge",
            ],
            swiftSettings: uiSettings),
        .testTarget(name: "ShotcueCoreTests", dependencies: ["ShotcueCore", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcuePersistenceTests", dependencies: ["ShotcuePersistence", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueCaptureTests", dependencies: ["ShotcueCapture", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueNotesTests", dependencies: ["ShotcueNotes", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueClaudeBridgeTests", dependencies: ["ShotcueClaudeBridge", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueUITests", dependencies: ["ShotcueUI", "ShotcueTestSupport"], swiftSettings: uiSettings),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: Yer tutucu kaynak dosyalarını yaz** (her target en az bir Swift dosyası içermeli)

`Sources/ShotcueCore/ShotcueCore.swift`:
```swift
/// ShotcueCore: pure-Swift domain layer (models, service protocols, rules). Imports Foundation only.
public enum ShotcueCoreInfo {
    public static let moduleName = "ShotcueCore"
}
```

`Sources/ShotcuePersistence/ShotcuePersistence.swift`, `Sources/ShotcueCapture/ShotcueCapture.swift`, `Sources/ShotcueNotes/ShotcueNotes.swift`, `Sources/ShotcueClaudeBridge/ShotcueClaudeBridge.swift`, `Sources/ShotcueUI/ShotcueUI.swift`, `Sources/ShotcueTestSupport/ShotcueTestSupport.swift` — her biri aynı kalıpla, modül adı değişir (`ShotcueUITests/SmokeTests.swift` de aynı kalıpla `ShotcueUIInfo`'yu test eder):
```swift
import ShotcueCore

public enum ShotcuePersistenceInfo {   // dosyaya göre: ShotcueCaptureInfo, ShotcueNotesInfo, ShotcueClaudeBridgeInfo, ShotcueUIInfo
    public static let moduleName = "ShotcuePersistence"
}
```

`Sources/ShotcueApp/ShotcueApp.swift` (menü çubuğunda ikon gösteren minimal uygulama; Plan 05 genişletir):
```swift
import SwiftUI
import ShotcueCore

@main
struct ShotcueApp: App {
    var body: some Scene {
        MenuBarExtra("Shotcue", systemImage: "camera.viewfinder") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shotcue").font(.headline)
                Text("Kurulum tamam. Kütüphane ve yakalama Plan 05 ile gelir.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Çık") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 260)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Yer tutucu smoke testlerini yaz**

`Tests/ShotcueCoreTests/SmokeTests.swift`:
```swift
import Testing
@testable import ShotcueCore

@Suite("Core smoke")
struct CoreSmokeTests {
    @Test func moduleLoads() {
        #expect(ShotcueCoreInfo.moduleName == "ShotcueCore")
    }
}
```

`Tests/ShotcueCoreTests/TestPaths.swift` (tüm test target'larına aynı dosya kopyalanır; fixture yolunu `#filePath`'ten türetir):
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

`Tests/ShotcuePersistenceTests/SmokeTests.swift` (Capture/Notes/ClaudeBridge için modül adı değiştirilerek aynı):
```swift
import Testing
@testable import ShotcuePersistence

@Suite("Persistence smoke")
struct PersistenceSmokeTests {
    @Test func moduleLoads() { #expect(ShotcuePersistenceInfo.moduleName == "ShotcuePersistence") }
}
```

- [ ] **Step 4: Derle ve testleri çalıştır (ilk çözümleme WhisperKit yüzünden birkaç dakika sürer)**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -8`
Expected: `Build complete!` ve `Test run with 6 tests … passed`. `ld: warning: search path … not found` uyarıları zararsızdır. Bir bağımlılık `PreviewsMacros`/`#Preview` hatası verirse o bağımlılık Global Constraints gereği kullanılamaz; durumu raporla, devam etme.

- [ ] **Step 5: Resources/Info.plist ve entitlements'ı yaz**

`Resources/Info.plist` (`__BUNDLE_ID__` ve `__APP_NAME__` yer tutucularını `bundle.sh` doldurur):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>tr</string>
    <key>CFBundleDisplayName</key><string>__APP_NAME__</string>
    <key>CFBundleExecutable</key><string>__APP_NAME__</string>
    <key>CFBundleIdentifier</key><string>__BUNDLE_ID__</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>__APP_NAME__</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Sesli not kaydetmek için mikrofon gerekir.</string>
    <key>NSHumanReadableCopyright</key><string>Shotcue</string>
</dict>
</plist>
```

`Resources/Shotcue.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><false/>
</dict>
</plist>
```

- [ ] **Step 6: scripts/bundle.sh, install.sh, shot.sh, make-cert.sh'ı yaz ve çalıştırılabilir yap**

`scripts/bundle.sh`:
```bash
#!/bin/bash
# Builds Shotcue.app under dist/ from the SwiftPM debug binary and signs it.
# Usage: scripts/bundle.sh [AppName] [BundleID] [SigningIdentity]
set -euo pipefail
APP_NAME="${1:-Shotcue}"
BUNDLE_ID="${2:-com.shotcue.app}"
IDENTITY="${3:-Shotcue Dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$(swift build --package-path "$ROOT" --show-bin-path)"
APP="$ROOT/dist/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundles (if any dependency ships one) live next to the binary.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && cp -R "$b" "$APP/Contents/MacOS/"
done
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Resources/Shotcue.entitlements" --sign "$IDENTITY" "$APP"
else
  echo "WARNING: signing identity '$IDENTITY' not found. Run scripts/make-cert.sh once." >&2
  echo "         Falling back to ad-hoc signing: TCC permissions will NOT survive rebuilds." >&2
  codesign --force --options runtime \
    --entitlements "$ROOT/Resources/Shotcue.entitlements" --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Bundled and signed: $APP"
```

`scripts/install.sh`:
```bash
#!/bin/bash
# Copies dist/<App>.app to ~/Applications (stable path keeps TCC grants), restarting a running instance.
set -euo pipefail
APP_NAME="${1:-Shotcue}"
INSTALL_DIR="${2:-$HOME/Applications}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/$APP_NAME.app"
[ -d "$SRC" ] || { echo "dist/$APP_NAME.app missing; run make bundle" >&2; exit 1; }
mkdir -p "$INSTALL_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$SRC" "$INSTALL_DIR/$APP_NAME.app"
echo "Installed: $INSTALL_DIR/$APP_NAME.app"
```

`scripts/shot.sh` (uygulamayı başlatır, pencerelerini `screencapture -l` ile PNG'ye alır; çalıştıran sürecin Ekran Kaydı izni gerekir):
```bash
#!/bin/bash
# Launches the installed app (asking it to open the library window) and screenshots each of its windows.
# Prints the PNG paths. Requires Screen Recording permission for the process running this script.
set -euo pipefail
APP_NAME="${1:-Shotcue}"
OUT_DIR="${2:-/tmp/shotcue-shots}"
APP="$HOME/Applications/$APP_NAME.app"
mkdir -p "$OUT_DIR"
open -a "$APP" --env SHOTCUE_OPEN_LIBRARY=1
sleep 2
WINDOW_IDS="$(swift - "$APP_NAME" <<'EOF'
import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    if let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
       (b["Height"] as? Double ?? 0) > 40 { print(id) }
}
EOF
)"
[ -n "$WINDOW_IDS" ] || { echo "No on-screen windows for $APP_NAME" >&2; exit 1; }
i=0
for id in $WINDOW_IDS; do
  i=$((i+1)); f="$OUT_DIR/window-$i.png"
  screencapture -x -o -l "$id" "$f" && echo "$f"
done
```

`scripts/make-cert.sh` (tek seferlik; sertifikayı üretir, login keychain'e alır, güven ayarını dener):
```bash
#!/bin/bash
# Creates a self-signed code-signing certificate "Shotcue Dev" so TCC grants survive rebuilds.
set -euo pipefail
NAME="${1:-Shotcue Dev}"
WORK="$(mktemp -d)"
cd "$WORK"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout dev.key -out dev.crt \
  -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=codeSigning"
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -in dev.crt -inkey dev.key -out dev.p12 -password pass:shotcue
security import dev.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P shotcue -T /usr/bin/codesign
# Trust for code signing (may show a system prompt). If it fails, do it manually:
# Keychain Access → login → Certificates → "Shotcue Dev" → Get Info → Trust → Code Signing: Always Trust.
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" dev.crt || \
  echo "Set trust manually in Keychain Access (see comment above)." >&2
rm -rf "$WORK"
security find-identity -v -p codesigning | grep "$NAME" && echo "Certificate ready: $NAME"
```

Run: `chmod +x scripts/*.sh`

- [ ] **Step 7: Makefile'ı yaz** (girinti sorunlarını önlemek için reçeteler `;` ile aynı satırda)

```make
APP_NAME     := Shotcue
BUNDLE_ID    := com.shotcue.app
SIGN_IDENTITY ?= Shotcue Dev
INSTALL_DIR  := $(HOME)/Applications

.PHONY: build test bundle install run shot reset-tcc format lint clean cert

build: ; swift build
test: ; swift test
bundle: build ; ./scripts/bundle.sh "$(APP_NAME)" "$(BUNDLE_ID)" "$(SIGN_IDENTITY)"
install: bundle ; ./scripts/install.sh "$(APP_NAME)" "$(INSTALL_DIR)"
run: install ; open "$(INSTALL_DIR)/$(APP_NAME).app"
shot: ; ./scripts/shot.sh "$(APP_NAME)"
cert: ; ./scripts/make-cert.sh "$(SIGN_IDENTITY)"
reset-tcc: ; tccutil reset ScreenCapture $(BUNDLE_ID); tccutil reset Microphone $(BUNDLE_ID)
format: ; swift-format format --in-place --recursive Sources Tests
lint: ; swift-format lint --strict --recursive Sources Tests
clean: ; rm -rf .build dist
```

`.swift-format`:
```json
{ "version": 1, "lineLength": 120, "indentation": { "spaces": 4 }, "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true, "lineBreakBeforeControlFlowKeywords": false }
```

- [ ] **Step 8: Bundle üret, kur, başlat**

Run: `make bundle && make install && open ~/Applications/Shotcue.app && sleep 2 && pgrep -x Shotcue`
Expected: `Bundled and signed: …/dist/Shotcue.app`, `Installed: …`, menü çubuğunda kamera ikonu, `pgrep` bir PID basar. Sertifika yoksa `WARNING … ad-hoc` görünür; bu Task 9 (spike) öncesi kullanıcıdan `make cert` istenerek giderilir.

- [ ] **Step 9: Test fixture'larını yaz**

`Tests/Fixtures/sample-stream.jsonl` (gerçek `claude -p --output-format stream-json --verbose` çıktısına uygun 7 satır):
```json
{"type":"system","subtype":"init","session_id":"3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73","model":"claude-sonnet-5","cwd":"/tmp/proj","tools":["Read","Edit","Bash"],"permissionMode":"bypassPermissions"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading the screenshot first."}]},"session_id":"3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/tmp/shots/a.png"}}]},"session_id":"3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"(image)"}]},"session_id":"3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"}
{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"error":"overloaded"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"/tmp/proj/src/Button.tsx","old_string":"red","new_string":"blue"}}]},"session_id":"3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":84213,"duration_api_ms":71904,"num_turns":11,"result":"Fixed the button color.\n\nFiles changed:\n- src/Button.tsx","session_id":"3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73","total_cost_usd":0.4137,"usage":{"input_tokens":41233,"output_tokens":6180},"permission_denials":[]}
```

`Tests/Fixtures/fake-claude.sh`:
```bash
#!/bin/bash
# Fake `claude` binary for tests.
#   FAKE_CLAUDE_ARGS_FILE   if set, argv + CWD + selected env vars are written there
#   FAKE_CLAUDE_SCENARIO    success (default) | max_turns | error | slow | hang
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = "--version" ]; then echo "2.1.278 (Claude Code)"; exit 0; fi
if [ -n "${FAKE_CLAUDE_ARGS_FILE:-}" ]; then
  { printf '%s\n' "$@"; printf 'CWD=%s\n' "$PWD"; env | grep -E '^(HOME|PATH|ANTHROPIC_API_KEY)=' || true; } > "$FAKE_CLAUDE_ARGS_FILE"
fi
SID="3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"
case "${FAKE_CLAUDE_SCENARIO:-success}" in
  success)   cat "$DIR/sample-stream.jsonl" ;;
  max_turns) head -n 3 "$DIR/sample-stream.jsonl"
             echo "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"duration_ms\":1000,\"num_turns\":30,\"session_id\":\"$SID\",\"total_cost_usd\":0.1,\"permission_denials\":[]}" ;;
  error)     echo "Error: not logged in. Run 'claude login'." >&2; exit 1 ;;
  slow)      head -n 2 "$DIR/sample-stream.jsonl"; sleep 1; tail -n +3 "$DIR/sample-stream.jsonl" ;;
  hang)      head -n 2 "$DIR/sample-stream.jsonl"; sleep 300 ;;
  *)         echo "unknown scenario" >&2; exit 2 ;;
esac
```

`Tests/Fixtures/fake-screencapture.sh`:
```bash
#!/bin/bash
# Fake /usr/sbin/screencapture. The last argument is the output path.
#   FAKE_SCREENCAPTURE_SCENARIO  success (default) | cancel | error
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${@: -1}"
case "${FAKE_SCREENCAPTURE_SCENARIO:-success}" in
  success) cp "$DIR/sample.png" "$OUT" ;;
  cancel)  exit 1 ;;                                  # real screencapture: ESC → exit 1, empty stderr
  error)   echo "screencapture: could not create image" >&2; exit 2 ;;
esac
```

`scripts/make-fixture-png.swift` (64×64, 2x ölçek metadata'lı PNG üretir; `sample.png` bundan çıkar):
```swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 64
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
precondition(CGImageDestinationFinalize(dest))
print("wrote \(out.path)")
```

Run: `chmod +x Tests/Fixtures/*.sh && swift scripts/make-fixture-png.swift Tests/Fixtures/sample.png && file Tests/Fixtures/sample.png && FAKE_CLAUDE_SCENARIO=max_turns Tests/Fixtures/fake-claude.sh -p x | tail -1 | head -c 60`
Expected: `PNG image data, 64 x 64`, ve son satır `{"type":"result","subtype":"error_max_turns"…`.

- [ ] **Step 10: CLAUDE.md'yi yaz**

```markdown
# Shotcue — rules for coding agents

Native macOS app (Swift 6.4, SwiftUI, macOS 26+), built WITHOUT Xcode: only Command Line Tools + SwiftPM.
Spec: docs/superpowers/specs/2026-09-22-shotcue-design.md · Plans: docs/superpowers/plans/

## Build & test (the only loop)
- `make test` — Swift Testing, run before every commit. Core tests take ~6 s; keep logic in ShotcueCore.
- `make build` / `make run` (bundle → ~/Applications → open) / `make shot` (screenshot app windows to /tmp/shotcue-shots).
- Never use `xcodebuild`, `actool`, `.xcassets`, Xcode projects, or `#Preview` (CLT has no PreviewsMacros; it breaks the build).
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
- Commit messages end with: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
```

- [ ] **Step 11: Format, test, commit**

Run: `make format && make test 2>&1 | tail -3 && git add -A && git status --short | head -30`
Expected: testler geçer; `.build/` ve `dist/` gitignore'da olduğu için listede yok.

```bash
git commit -m "chore: scaffold Shotcue package, build scripts, fixtures and agent rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 1: Core modelleri (Project, ShotTask, Capture, VoiceNote, Transcript, Run)

**Files:**
- Create: `Sources/ShotcueCore/Models/Project.swift`, `Sources/ShotcueCore/Models/ShotTask.swift`, `Sources/ShotcueCore/Models/Capture.swift`, `Sources/ShotcueCore/Models/VoiceNote.swift`, `Sources/ShotcueCore/Models/Run.swift`
- Test: `Tests/ShotcueCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces (diğer tüm planlar bunları kullanır): `Project`, `DailyTime`, `TaskMode`, `TaskStatus`, `ShotTask`, `Capture`, `VoiceNote`, `TranscriptState`, `Transcript`, `Run`, `RunState` — hepsi `Hashable, Sendable, Codable`, `Identifiable` olanların `id: UUID`. Tüm init'lerin varsayılan değerleri aşağıdaki gibidir.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueCoreTests/ModelsTests.swift`:
```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("Core models")
struct ModelsTests {
    @Test func dailyTimeParsesAndFormats() throws {
        let t = try #require(DailyTime(parsing: "09:05"))
        #expect(t.hour == 9 && t.minute == 5)
        #expect(t.formatted == "09:05")
        #expect(DailyTime(parsing: "25:00") == nil)
        #expect(DailyTime(parsing: "9") == nil)
    }

    @Test func projectDefaults() {
        let p = Project(name: "crm", path: "/tmp/crm")
        #expect(p.defaultMode == .implement)
        #expect(p.dailyEnabled == false && p.dailyTime == nil)
        #expect(p.runInBranch == false && p.stashBeforeRun == false)
    }

    @Test func shotTaskDefaultsToInboxWithoutProject() {
        let t = ShotTask(title: "x")
        #expect(t.status == .inbox)
        #expect(t.projectID == nil)
        #expect(t.mode == .implement)
        #expect(t.titleEditedByUser == false)
    }

    @Test func modelsRoundTripThroughJSON() throws {
        let now = Date(timeIntervalSince1970: 1_758_500_000)
        let task = ShotTask(id: UUID(), projectID: UUID(), title: "t", noteText: "n", status: .scheduled,
                            mode: .analyze, modelOverride: "opus", sortIndex: 2048, scheduledAt: now,
                            titleEditedByUser: true, createdAt: now, updatedAt: now)
        let run = Run(id: UUID(), taskID: task.id, state: .succeeded, startedAt: now, finishedAt: now,
                      numTurns: 3, costUSD: 0.12, resultText: "ok", subtype: "success", exitCode: 0, error: nil,
                      logRelPath: "runs/x.jsonl", gitHeadBefore: "abc", gitDirtyBefore: false,
                      gitHeadAfter: "def", gitBranch: "main")
        let transcript = Transcript(text: "merhaba", language: "tr", engine: "whisperkit/turbo",
                                    segments: [.init(start: 0, end: 1.5, text: "merhaba", confidence: 0.9)])
        let enc = JSONEncoder(); let dec = JSONDecoder()
        #expect(try dec.decode(ShotTask.self, from: enc.encode(task)) == task)
        #expect(try dec.decode(Run.self, from: enc.encode(run)) == run)
        #expect(try dec.decode(Transcript.self, from: enc.encode(transcript)) == transcript)
    }

    @Test func statusAndModeRawValuesAreStable() {
        #expect(TaskStatus.allCases.map(\.rawValue) ==
                ["inbox", "ready", "queued", "scheduled", "running", "done", "failed", "cancelled"])
        #expect(TaskMode.allCases.map(\.rawValue) == ["analyze", "implement"])
        #expect(RunState.allCases.map(\.rawValue) == ["starting", "running", "succeeded", "failed", "cancelled"])
        #expect(TranscriptState.allCases.map(\.rawValue) == ["pending", "done", "failed"])
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `swift test --filter ModelsTests 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'DailyTime' in scope` ve benzeri hatalar.

- [ ] **Step 3: Modelleri yaz**

`Sources/ShotcueCore/Models/Project.swift`:
```swift
import Foundation

/// Wall-clock time of day for the per-project daily queue (local time zone).
public struct DailyTime: Hashable, Sendable, Codable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses "HH:MM"; nil when malformed or out of range.
    public init?(parsing text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    public var formatted: String { String(format: "%02d:%02d", hour, minute) }
}

/// A project = a directory on disk where Claude Code runs. Groups in the library are projects.
public struct Project: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var path: String
    public var defaultMode: TaskMode
    public var defaultModel: String?
    public var defaultEffort: String?
    public var dailyTime: DailyTime?
    public var dailyEnabled: Bool
    public var dailyLastFiredAt: Date?
    public var runInBranch: Bool
    public var stashBeforeRun: Bool
    public var sortIndex: Double
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, path: String, defaultMode: TaskMode = .implement,
                defaultModel: String? = nil, defaultEffort: String? = nil, dailyTime: DailyTime? = nil,
                dailyEnabled: Bool = false, dailyLastFiredAt: Date? = nil, runInBranch: Bool = false,
                stashBeforeRun: Bool = false, sortIndex: Double = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.path = path; self.defaultMode = defaultMode
        self.defaultModel = defaultModel; self.defaultEffort = defaultEffort; self.dailyTime = dailyTime
        self.dailyEnabled = dailyEnabled; self.dailyLastFiredAt = dailyLastFiredAt
        self.runInBranch = runInBranch; self.stashBeforeRun = stashBeforeRun
        self.sortIndex = sortIndex; self.createdAt = createdAt
    }
}
```

`Sources/ShotcueCore/Models/ShotTask.swift`:
```swift
import Foundation

public enum TaskMode: String, Sendable, Codable, CaseIterable {
    case analyze, implement
}

public enum TaskStatus: String, Sendable, Codable, CaseIterable {
    case inbox, ready, queued, scheduled, running, done, failed, cancelled
}

/// A unit of work sent to Claude Code: one or more captures + note(s) targeting one project.
/// Named `ShotTask` to avoid clashing with Swift's `Task`.
public struct ShotTask: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var projectID: UUID?
    public var title: String
    public var noteText: String
    public var status: TaskStatus
    public var mode: TaskMode
    public var modelOverride: String?
    public var sortIndex: Double
    public var scheduledAt: Date?
    public var titleEditedByUser: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), projectID: UUID? = nil, title: String, noteText: String = "",
                status: TaskStatus = .inbox, mode: TaskMode = .implement, modelOverride: String? = nil,
                sortIndex: Double = 0, scheduledAt: Date? = nil, titleEditedByUser: Bool = false,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.title = title; self.noteText = noteText
        self.status = status; self.mode = mode; self.modelOverride = modelOverride
        self.sortIndex = sortIndex; self.scheduledAt = scheduledAt; self.titleEditedByUser = titleEditedByUser
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
```

`Sources/ShotcueCore/Models/Capture.swift`:
```swift
import Foundation

/// One screenshot file belonging to a task. Paths are relative to the FileStore root.
public struct Capture: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
    public var relPath: String
    public var thumbRelPath: String?
    public var width: Int
    public var height: Int
    public var scale: Double
    public var createdAt: Date

    public init(id: UUID = UUID(), taskID: UUID, relPath: String, thumbRelPath: String? = nil,
                width: Int, height: Int, scale: Double = 2, createdAt: Date = Date()) {
        self.id = id; self.taskID = taskID; self.relPath = relPath; self.thumbRelPath = thumbRelPath
        self.width = width; self.height = height; self.scale = scale; self.createdAt = createdAt
    }
}
```

`Sources/ShotcueCore/Models/VoiceNote.swift`:
```swift
import Foundation

public enum TranscriptState: String, Sendable, Codable, CaseIterable {
    case pending, done, failed
}

/// Transcription output; stored as JSON next to the plain text.
public struct Transcript: Hashable, Sendable, Codable {
    public struct Segment: Hashable, Sendable, Codable {
        public var start: Double
        public var end: Double
        public var text: String
        public var confidence: Double?
        public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
            self.start = start; self.end = end; self.text = text; self.confidence = confidence
        }
    }
    public var text: String
    public var language: String
    public var engine: String
    public var segments: [Segment]
    public init(text: String, language: String, engine: String, segments: [Segment] = []) {
        self.text = text; self.language = language; self.engine = engine; self.segments = segments
    }
}

public struct VoiceNote: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
    public var relPath: String
    public var durationSec: Double
    public var transcript: String?
    public var transcriptJSON: String?
    public var transcriptState: TranscriptState
    public var engine: String?
    public var editedByUser: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), taskID: UUID, relPath: String, durationSec: Double,
                transcript: String? = nil, transcriptJSON: String? = nil, transcriptState: TranscriptState = .pending,
                engine: String? = nil, editedByUser: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.taskID = taskID; self.relPath = relPath; self.durationSec = durationSec
        self.transcript = transcript; self.transcriptJSON = transcriptJSON; self.transcriptState = transcriptState
        self.engine = engine; self.editedByUser = editedByUser; self.createdAt = createdAt
    }
}
```

`Sources/ShotcueCore/Models/Run.swift`:
```swift
import Foundation

public enum RunState: String, Sendable, Codable, CaseIterable {
    case starting, running, succeeded, failed, cancelled
}

/// One headless Claude Code execution of a task. `id` doubles as the Claude session id (`--session-id`).
public struct Run: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
    public var state: RunState
    public var startedAt: Date
    public var finishedAt: Date?
    public var numTurns: Int?
    public var costUSD: Double?
    public var resultText: String?
    public var subtype: String?
    public var exitCode: Int32?
    public var error: String?
    public var logRelPath: String
    public var gitHeadBefore: String?
    public var gitDirtyBefore: Bool?
    public var gitHeadAfter: String?
    public var gitBranch: String?

    public init(id: UUID = UUID(), taskID: UUID, state: RunState = .starting, startedAt: Date = Date(),
                finishedAt: Date? = nil, numTurns: Int? = nil, costUSD: Double? = nil, resultText: String? = nil,
                subtype: String? = nil, exitCode: Int32? = nil, error: String? = nil, logRelPath: String,
                gitHeadBefore: String? = nil, gitDirtyBefore: Bool? = nil, gitHeadAfter: String? = nil,
                gitBranch: String? = nil) {
        self.id = id; self.taskID = taskID; self.state = state; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.numTurns = numTurns; self.costUSD = costUSD
        self.resultText = resultText; self.subtype = subtype; self.exitCode = exitCode; self.error = error
        self.logRelPath = logRelPath; self.gitHeadBefore = gitHeadBefore; self.gitDirtyBefore = gitDirtyBefore
        self.gitHeadAfter = gitHeadAfter; self.gitBranch = gitBranch
    }

    public var isFinished: Bool { state == .succeeded || state == .failed || state == .cancelled }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `swift test --filter ModelsTests 2>&1 | tail -3`
Expected: `Test run with 5 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Models Tests/ShotcueCoreTests/ModelsTests.swift
git commit -m "feat(core): add domain models

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Task durum makinesi

**Files:**
- Create: `Sources/ShotcueCore/Logic/TaskTransitions.swift`
- Test: `Tests/ShotcueCoreTests/TaskTransitionsTests.swift`

**Interfaces:**
- Produces: `TaskStateError` (`invalidTransition(from:to:)`, `missingProject`, `scheduledDateRequired`), `TaskStatus.allowedTransitions`, `TaskStatus.canTransition(to:)`, `TaskStatus.isEditable`, `ShotTask.transition(to:at:) throws(TaskStateError)`. Plan 04 (runner) ve Plan 05 (UI) her durum değişikliğini bu fonksiyonla yapar; doğrudan `status =` ataması yasaktır.

- [ ] **Step 1: Başarısız testi yaz**

```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("Task transitions")
struct TaskTransitionsTests {
    let now = Date(timeIntervalSince1970: 1_758_500_000)

    @Test func allowedMapMatchesSpec() {
        #expect(TaskStatus.allowedTransitions[.inbox] == [.ready])
        #expect(TaskStatus.allowedTransitions[.ready] == [.queued, .scheduled, .inbox])
        #expect(TaskStatus.allowedTransitions[.queued] == [.running, .ready, .scheduled])
        #expect(TaskStatus.allowedTransitions[.scheduled] == [.queued, .ready])
        #expect(TaskStatus.allowedTransitions[.running] == [.done, .failed, .cancelled])
        #expect(TaskStatus.allowedTransitions[.done] == [.queued, .scheduled])
        #expect(TaskStatus.allowedTransitions[.failed] == [.queued, .scheduled, .ready])
        #expect(TaskStatus.allowedTransitions[.cancelled] == [.queued, .scheduled, .ready])
        #expect(TaskStatus.allCases.allSatisfy { TaskStatus.allowedTransitions[$0] != nil })
    }

    @Test func inboxToReadyRequiresProject() {
        var t = ShotTask(title: "x", createdAt: now, updatedAt: now)
        #expect(throws: TaskStateError.missingProject) { try t.transition(to: .ready, at: now) }
        t.projectID = UUID()
        #expect(throws: Never.self) { try t.transition(to: .ready, at: now) }
        #expect(t.status == .ready)
    }

    @Test func invalidTransitionThrows() {
        var t = ShotTask(projectID: UUID(), title: "x", status: .inbox)
        #expect(throws: TaskStateError.invalidTransition(from: .inbox, to: .running)) {
            try t.transition(to: .running, at: now)
        }
        #expect(t.status == .inbox)
    }

    @Test func schedulingRequiresDateAndUnschedulingClearsIt() throws {
        var t = ShotTask(projectID: UUID(), title: "x", status: .ready)
        #expect(throws: TaskStateError.scheduledDateRequired) { try t.transition(to: .scheduled, at: now) }
        t.scheduledAt = now.addingTimeInterval(3600)
        try t.transition(to: .scheduled, at: now)
        #expect(t.status == .scheduled)
        try t.transition(to: .ready, at: now.addingTimeInterval(1))
        #expect(t.scheduledAt == nil)
        #expect(t.updatedAt == now.addingTimeInterval(1))
    }

    @Test func runningIsNotEditable() {
        #expect(TaskStatus.running.isEditable == false)
        #expect(TaskStatus.allCases.filter { $0 != .running }.allSatisfy(\.isEditable))
    }

    @Test func fullHappyPath() throws {
        var t = ShotTask(projectID: UUID(), title: "x", status: .inbox)
        for next in [TaskStatus.ready, .queued, .running, .done, .queued, .running, .failed, .queued, .running, .cancelled] {
            try t.transition(to: next, at: now)
        }
        #expect(t.status == .cancelled)
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter TaskTransitionsTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find type 'TaskStateError' in scope`.

- [ ] **Step 3: Geçiş kurallarını yaz**

`Sources/ShotcueCore/Logic/TaskTransitions.swift`:
```swift
import Foundation

public enum TaskStateError: Error, Equatable, Sendable {
    case invalidTransition(from: TaskStatus, to: TaskStatus)
    case missingProject
    case scheduledDateRequired
}

extension TaskStatus {
    /// Spec §7. Deleting/archiving is not a transition; it removes the row.
    public static let allowedTransitions: [TaskStatus: Set<TaskStatus>] = [
        .inbox: [.ready],
        .ready: [.queued, .scheduled, .inbox],
        .queued: [.running, .ready, .scheduled],
        .scheduled: [.queued, .ready],
        .running: [.done, .failed, .cancelled],
        .done: [.queued, .scheduled],
        .failed: [.queued, .scheduled, .ready],
        .cancelled: [.queued, .scheduled, .ready],
    ]

    public func canTransition(to next: TaskStatus) -> Bool {
        Self.allowedTransitions[self]?.contains(next) ?? false
    }

    /// A running task may only be cancelled, never edited.
    public var isEditable: Bool { self != .running }
}

extension ShotTask {
    /// The only sanctioned way to change `status`. Also maintains `scheduledAt` and `updatedAt`.
    public mutating func transition(to next: TaskStatus, at now: Date) throws(TaskStateError) {
        guard status.canTransition(to: next) else {
            throw .invalidTransition(from: status, to: next)
        }
        if [.ready, .queued, .scheduled, .running].contains(next), projectID == nil {
            throw .missingProject
        }
        if next == .scheduled, scheduledAt == nil {
            throw .scheduledDateRequired
        }
        if next == .ready || next == .inbox || next == .done {
            scheduledAt = nil
        }
        status = next
        updatedAt = now
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter TaskTransitionsTests 2>&1 | tail -3`
Expected: `Test run with 6 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Logic/TaskTransitions.swift Tests/ShotcueCoreTests/TaskTransitionsTests.swift
git commit -m "feat(core): add task status state machine

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: SortIndex ve KeyCombo

**Files:**
- Create: `Sources/ShotcueCore/Logic/SortIndex.swift`, `Sources/ShotcueCore/Models/KeyCombo.swift`
- Test: `Tests/ShotcueCoreTests/SortIndexTests.swift`, `Tests/ShotcueCoreTests/KeyComboTests.swift`

**Interfaces:**
- Produces: `SortIndex.step`, `SortIndex.between(_:_:)`, `SortIndex.needsRenumber(_:_:)`, `SortIndex.renumbered(count:)` (Plan 01 ve 05 sürükle-bırakta kullanır); `KeyCombo { keyCode: UInt32, modifiers: UInt32, label: String }`, `KeyCombo.presets`, `KeyCombo.defaultCombo`, modifier sabitleri `KeyCombo.controlKey/shiftKey/optionKey/commandKey` (Carbon maskeleriyle bire bir; Plan 02 `RegisterEventHotKey`'e doğrudan geçirir).

- [ ] **Step 1: Başarısız testleri yaz**

`Tests/ShotcueCoreTests/SortIndexTests.swift`:
```swift
import Testing
@testable import ShotcueCore

@Suite("SortIndex")
struct SortIndexTests {
    @Test func appendsAfterLast() { #expect(SortIndex.between(3072, nil) == 3072 + SortIndex.step) }
    @Test func prependsBeforeFirst() { #expect(SortIndex.between(nil, 1024) == 0) }
    @Test func emptyListStartsAtStep() { #expect(SortIndex.between(nil, nil) == SortIndex.step) }
    @Test func midpointBetweenNeighbors() { #expect(SortIndex.between(1024, 2048) == 1536) }
    @Test func detectsExhaustedGap() {
        #expect(SortIndex.needsRenumber(1.0, 1.0 + 1e-9) == true)
        #expect(SortIndex.needsRenumber(1024, 2048) == false)
    }
    @Test func renumberProducesEvenSteps() { #expect(SortIndex.renumbered(count: 3) == [1024, 2048, 3072]) }
}
```

`Tests/ShotcueCoreTests/KeyComboTests.swift`:
```swift
import Testing
@testable import ShotcueCore

@Suite("KeyCombo")
struct KeyComboTests {
    @Test func carbonMasksMatchHIToolbox() {
        #expect(KeyCombo.commandKey == 0x0100 && KeyCombo.shiftKey == 0x0200)
        #expect(KeyCombo.optionKey == 0x0800 && KeyCombo.controlKey == 0x1000)
    }
    @Test func defaultIsControlShiftTwo() {
        let d = KeyCombo.defaultCombo
        #expect(d.keyCode == 0x13)                                   // kVK_ANSI_2
        #expect(d.modifiers == KeyCombo.controlKey | KeyCombo.shiftKey)
        #expect(d.label == "⌃⇧2")
    }
    @Test func presetsAreUniqueAndLabeled() {
        #expect(KeyCombo.presets.count == 6)
        #expect(Set(KeyCombo.presets).count == 6)
        #expect(KeyCombo.presets.map(\.label) == ["⌃⇧2", "⌃⇧3", "⌃⇧4", "⌘⇧2", "⌥Space", "⌃⌥Space"])
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter "SortIndexTests|KeyComboTests" 2>&1 | grep -c "error:"`
Expected: 1'den büyük bir sayı.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Logic/SortIndex.swift`:
```swift
/// Fractional ordering: reordering touches one row. Renumber when a gap collapses.
public enum SortIndex {
    public static let step: Double = 1024
    private static let minimumGap: Double = 1e-6

    /// Index that sorts between `before` and `after`; pass nil for the list ends.
    public static func between(_ before: Double?, _ after: Double?) -> Double {
        switch (before, after) {
        case (nil, nil): return step
        case (let b?, nil): return b + step
        case (nil, let a?): return a - step
        case (let b?, let a?): return (b + a) / 2
        }
    }

    public static func needsRenumber(_ before: Double?, _ after: Double?) -> Bool {
        guard let b = before, let a = after else { return false }
        return (a - b) < minimumGap
    }

    public static func renumbered(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).map { Double($0) * step }
    }
}
```

`Sources/ShotcueCore/Models/KeyCombo.swift`:
```swift
/// Global hotkey definition using Carbon virtual key codes and modifier masks
/// (values copied from HIToolbox/Events.h so Core stays framework-free).
public struct KeyCombo: Hashable, Sendable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }

    public static let commandKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12

    static let vkANSI2: UInt32 = 0x13
    static let vkANSI3: UInt32 = 0x14
    static let vkANSI4: UInt32 = 0x15
    static let vkSpace: UInt32 = 0x31

    public static let presets: [KeyCombo] = [
        KeyCombo(keyCode: vkANSI2, modifiers: controlKey | shiftKey, label: "⌃⇧2"),
        KeyCombo(keyCode: vkANSI3, modifiers: controlKey | shiftKey, label: "⌃⇧3"),
        KeyCombo(keyCode: vkANSI4, modifiers: controlKey | shiftKey, label: "⌃⇧4"),
        KeyCombo(keyCode: vkANSI2, modifiers: commandKey | shiftKey, label: "⌘⇧2"),
        KeyCombo(keyCode: vkSpace, modifiers: optionKey, label: "⌥Space"),
        KeyCombo(keyCode: vkSpace, modifiers: controlKey | optionKey, label: "⌃⌥Space"),
    ]

    public static let defaultCombo = presets[0]
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter "SortIndexTests|KeyComboTests" 2>&1 | tail -3`
Expected: `Test run with 9 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Logic/SortIndex.swift Sources/ShotcueCore/Models/KeyCombo.swift Tests/ShotcueCoreTests/SortIndexTests.swift Tests/ShotcueCoreTests/KeyComboTests.swift
git commit -m "feat(core): add fractional sort index and hotkey combos

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: TitleMaker (otomatik başlık)

**Files:**
- Create: `Sources/ShotcueCore/Logic/TitleMaker.swift`
- Test: `Tests/ShotcueCoreTests/TitleMakerTests.swift`

**Interfaces:**
- Produces: `TitleMaker.title(noteText:transcript:createdAt:calendar:) -> String`, `TitleMaker.maxLength = 60`. Plan 01/05, `titleEditedByUser == false` iken not veya transkript değiştiğinde bunu çağırıp `title`'ı günceller.

- [ ] **Step 1: Başarısız testi yaz**

```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("TitleMaker")
struct TitleMakerTests {
    let created = Date(timeIntervalSince1970: 1_758_542_400)   // 2025-09-22 12:00:00 UTC (yıl başlıkta görünmez)
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func usesFirstSentenceOfNote() {
        let t = TitleMaker.title(noteText: "Butonun rengi yanlış. Ayrıca hizalama bozuk.", transcript: nil,
                                 createdAt: created, calendar: utc)
        #expect(t == "Butonun rengi yanlış")
    }

    @Test func fallsBackToTranscriptThenDate() {
        #expect(TitleMaker.title(noteText: "  ", transcript: "login ekranı açılmıyor!", createdAt: created, calendar: utc)
                == "login ekranı açılmıyor")
        #expect(TitleMaker.title(noteText: "", transcript: nil, createdAt: created, calendar: utc) == "Yakalama 22.09 12:00")
    }

    @Test func truncatesLongSentencesWithEllipsis() {
        let long = String(repeating: "kelime ", count: 20)
        let t = TitleMaker.title(noteText: long, transcript: nil, createdAt: created, calendar: utc)
        #expect(t.count <= TitleMaker.maxLength)
        #expect(t.hasSuffix("…"))
    }

    @Test func newlineEndsSentence() {
        #expect(TitleMaker.title(noteText: "ilk satır\nikinci satır", transcript: nil, createdAt: created, calendar: utc)
                == "ilk satır")
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter TitleMakerTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'TitleMaker' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Logic/TitleMaker.swift`:
```swift
import Foundation

public enum TitleMaker {
    public static let maxLength = 60

    /// Note first sentence → transcript first sentence → "Yakalama dd.MM HH:mm".
    public static func title(noteText: String, transcript: String?, createdAt: Date,
                             calendar: Calendar = .current) -> String {
        if let s = firstSentence(noteText) { return s }
        if let t = transcript, let s = firstSentence(t) { return s }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "dd.MM HH:mm"
        return "Yakalama \(f.string(from: createdAt))"
    }

    static func firstSentence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var sentence = ""
        for ch in trimmed {
            if terminators.contains(ch) { break }
            sentence.append(ch)
        }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }
        if sentence.count > maxLength {
            return String(sentence.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return sentence
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter TitleMakerTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Logic/TitleMaker.swift Tests/ShotcueCoreTests/TitleMakerTests.swift
git commit -m "feat(core): derive task titles from notes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 5: PromptBuilder (Claude'a giden metin)

**Files:**
- Create: `Sources/ShotcueCore/Logic/PromptBuilder.swift`
- Test: `Tests/ShotcueCoreTests/PromptBuilderTests.swift`

**Interfaces:**
- Produces: `ScreenshotRef(absolutePath:label:)`, `PromptInput(mode:title:projectPath:screenshots:noteText:transcripts:)`, `PromptBuilder.build(_:) -> String`, `PromptBuilder.systemPromptAppend: String`. Plan 04 `RunSpec.prompt`'u `build` ile, `RunSpec.systemPromptAppend`'i `systemPromptAppend` + kullanıcının ek talimatıyla doldurur. "Tek task olarak birleştir" akışı Plan 05'te önce capture'ları tek task'a taşır; prompt her zaman tek task içindir.

- [ ] **Step 1: Başarısız testi yaz**

```swift
import Testing
@testable import ShotcueCore

@Suite("PromptBuilder")
struct PromptBuilderTests {
    let base = PromptInput(
        mode: .implement, title: "Buton rengi yanlış", projectPath: "/Users/me/crm",
        screenshots: [ScreenshotRef(absolutePath: "/tmp/a.png", label: "login ekranı"),
                      ScreenshotRef(absolutePath: "/tmp/b.png")],
        noteText: "Kırmızı olmalı.", transcripts: ["butonun rengi mavi olmuş kırmızı olacak"])

    @Test func headerAndSections() {
        let p = PromptBuilder.build(base)
        let lines = p.components(separatedBy: "\n")
        #expect(lines[0] == "TASK TYPE: IMPLEMENT")
        #expect(lines[1] == "TITLE: Buton rengi yanlış")
        #expect(p.contains("SCREENSHOTS (read each of these with the Read tool BEFORE doing anything else):"))
        #expect(p.contains("- /tmp/a.png  (login ekranı)"))
        #expect(p.contains("- /tmp/b.png\n"))
        #expect(p.contains("NOTE (written by the user):\nKırmızı olmalı."))
        #expect(p.contains("VOICE NOTE (dictated by the user"))
        #expect(p.contains("\"butonun rengi mavi olmuş kırmızı olacak\""))
        #expect(p.contains("PROJECT: /Users/me/crm"))
        #expect(p.contains("Do NOT commit or push"))
    }

    @Test func analyzeModeForbidsEdits() {
        var i = base; i.mode = .analyze
        let p = PromptBuilder.build(i)
        #expect(p.hasPrefix("TASK TYPE: ANALYZE ONLY"))
        #expect(p.contains("Do NOT modify any file"))
        #expect(!p.contains("Do NOT commit or push"))
    }

    @Test func emptySectionsAreOmitted() {
        var i = base; i.noteText = "  \n"; i.transcripts = ["", "   "]; i.screenshots = []
        let p = PromptBuilder.build(i)
        #expect(p.contains("SCREENSHOTS: none"))
        #expect(!p.contains("NOTE (written by the user)"))
        #expect(!p.contains("VOICE NOTE"))
    }

    @Test func systemPromptMentionsShotcueAndTranscriptCaveat() {
        #expect(PromptBuilder.systemPromptAppend.contains("Shotcue"))
        #expect(PromptBuilder.systemPromptAppend.contains("ANALYZE ONLY"))
        #expect(PromptBuilder.systemPromptAppend.contains("transcription errors"))
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter PromptBuilderTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'PromptInput' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Logic/PromptBuilder.swift`:
```swift
import Foundation

public struct ScreenshotRef: Hashable, Sendable {
    public var absolutePath: String
    public var label: String?
    public init(absolutePath: String, label: String? = nil) {
        self.absolutePath = absolutePath; self.label = label
    }
}

public struct PromptInput: Hashable, Sendable {
    public var mode: TaskMode
    public var title: String
    public var projectPath: String
    public var screenshots: [ScreenshotRef]
    public var noteText: String
    public var transcripts: [String]
    public init(mode: TaskMode, title: String, projectPath: String, screenshots: [ScreenshotRef],
                noteText: String, transcripts: [String]) {
        self.mode = mode; self.title = title; self.projectPath = projectPath
        self.screenshots = screenshots; self.noteText = noteText; self.transcripts = transcripts
    }
}

/// Builds the user prompt for `claude -p` (spec §6.4). Screenshots first, then notes, then the contract.
public enum PromptBuilder {
    public static func build(_ input: PromptInput) -> String {
        var lines: [String] = []
        lines.append("TASK TYPE: \(input.mode == .analyze ? "ANALYZE ONLY" : "IMPLEMENT")")
        lines.append("TITLE: \(input.title)")
        lines.append("")
        if input.screenshots.isEmpty {
            lines.append("SCREENSHOTS: none")
        } else {
            lines.append("SCREENSHOTS (read each of these with the Read tool BEFORE doing anything else):")
            for shot in input.screenshots {
                if let label = shot.label, !label.isEmpty {
                    lines.append("- \(shot.absolutePath)  (\(label))")
                } else {
                    lines.append("- \(shot.absolutePath)")
                }
            }
        }
        let note = input.noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("")
            lines.append("NOTE (written by the user):")
            lines.append(note)
        }
        let transcripts = input.transcripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !transcripts.isEmpty {
            lines.append("")
            lines.append("VOICE NOTE (dictated by the user; verbatim transcript, may contain transcription errors, interpret the intent):")
            for t in transcripts { lines.append("\"\(t)\"") }
        }
        lines.append("")
        lines.append("PROJECT: \(input.projectPath)")
        lines.append("")
        lines.append("EXPECTED OUTCOME:")
        lines.append(contentsOf: input.mode == .analyze ? analyzeOutcome : implementOutcome)
        return lines.joined(separator: "\n")
    }

    static let implementOutcome = [
        "1. Do what the note asks; the screenshots are the source of truth for the current UI and behavior.",
        "2. Add or update tests that cover the change and run them.",
        "3. Do NOT commit or push. Do NOT touch unrelated modules.",
        "4. Finish with: a 3-line summary, the list of changed files, and anything you could not do and why.",
    ]

    static let analyzeOutcome = [
        "1. Investigate what the screenshots and note describe: root cause, affected files, relevant code paths.",
        "2. Propose a concrete plan with file paths and the order of changes.",
        "3. Do NOT modify any file. Do NOT run commands that change the working tree.",
        "4. Finish with: a 3-line summary and the list of files you examined.",
    ]

    /// Passed via `--append-system-prompt` on every run (user's own extra instructions are appended after it).
    public static let systemPromptAppend = """
        You are processing a task captured with Shotcue, a macOS screenshot + voice-note tool. \
        The screenshots are UI captures from the running application; read them with the Read tool before editing code. \
        The voice-note transcript is dictated speech: it may contain filler words, Turkish/English code-switching and \
        transcription errors (technical terms may be rendered phonetically). Interpret the intent; do not quote it literally. \
        Always finish with: (1) a 3-line summary, (2) the list of files you changed, (3) what you could NOT do and why. \
        If the task type is ANALYZE ONLY, do not modify any file.
        """
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Logic/PromptBuilder.swift Tests/ShotcueCoreTests/PromptBuilderTests.swift
git commit -m "feat(core): build Claude prompts from tasks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: RunEvent, ClaudeRunResult ve StreamJSONParser

**Files:**
- Create: `Sources/ShotcueCore/Models/RunEvent.swift`, `Sources/ShotcueCore/Logic/StreamJSONParser.swift`
- Test: `Tests/ShotcueCoreTests/StreamJSONParserTests.swift`

**Interfaces:**
- Produces: `ClaudeRunResult` (alanlar: `subtype, isError, sessionID, result, totalCostUSD, numTurns, durationMs, permissionDenials`; yardımcılar `isSuccess`, `hitLimit`, sabitler `successSubtype`, `maxTurnsSubtype`, `maxBudgetSubtype`, `executionErrorSubtype`), `RunEvent` (`initialized`, `assistantText`, `toolUse`, `apiRetry`, `result`, `other`), `StreamJSONParser.parse(line:) -> RunEvent?`, `StreamJSONParser.toolSummary(name:input:)`. Plan 04 stdout'un her satırını `parse(line:)`'a verir; Plan 05 `RunEvent`'leri canlı logda gösterir.

- [ ] **Step 1: Başarısız testi yaz**

```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("StreamJSONParser")
struct StreamJSONParserTests {
    var fixtureLines: [String] {
        let text = try! String(contentsOf: TestPaths.fixture("sample-stream.jsonl"), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    @Test func parsesEveryFixtureLineInOrder() throws {
        let events = fixtureLines.compactMap { StreamJSONParser.parse(line: $0) }
        #expect(events.count == 7)
        #expect(events[0] == .initialized(sessionID: "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73", model: "claude-sonnet-5"))
        #expect(events[1] == .assistantText("Reading the screenshot first."))
        #expect(events[2] == .toolUse(name: "Read", summary: "Read /tmp/shots/a.png"))
        #expect(events[3] == .other(type: "user"))
        #expect(events[4] == .apiRetry(attempt: 1))
        #expect(events[5] == .toolUse(name: "Edit", summary: "Edit /tmp/proj/src/Button.tsx"))
        guard case .result(let r) = events[6] else { Issue.record("last event must be result"); return }
        #expect(r.subtype == "success" && r.isError == false && r.isSuccess)
        #expect(r.sessionID == "3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73")
        #expect(r.numTurns == 11 && r.durationMs == 84213)
        #expect(r.totalCostUSD == 0.4137)
        #expect(r.result?.hasPrefix("Fixed the button color.") == true)
        #expect(r.permissionDenials.isEmpty)
    }

    @Test func blankAndGarbageLinesAreNil() {
        #expect(StreamJSONParser.parse(line: "") == nil)
        #expect(StreamJSONParser.parse(line: "   \n") == nil)
        #expect(StreamJSONParser.parse(line: "not json") == nil)
        #expect(StreamJSONParser.parse(line: "{\"no_type\":1}") == nil)
    }

    @Test func limitSubtypesAreDetected() {
        let line = "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"num_turns\":30,\"permission_denials\":[{\"tool_name\":\"Bash\"}]}"
        guard case .result(let r)? = StreamJSONParser.parse(line: line) else { Issue.record("expected result"); return }
        #expect(r.hitLimit && !r.isSuccess)
        #expect(r.permissionDenials == ["Bash"])
        #expect(ClaudeRunResult(subtype: "error_max_budget_usd", isError: true).hitLimit)
        #expect(!ClaudeRunResult(subtype: "error_during_execution", isError: true).hitLimit)
    }

    @Test func toolSummaryPicksMeaningfulField() {
        #expect(StreamJSONParser.toolSummary(name: "Bash", input: ["command": "git status"]) == "Bash git status")
        #expect(StreamJSONParser.toolSummary(name: "Grep", input: ["pattern": "TODO", "path": "src"]) == "Grep src")
        #expect(StreamJSONParser.toolSummary(name: "WebSearch", input: ["query": "swift 6"]) == "WebSearch swift 6")
        #expect(StreamJSONParser.toolSummary(name: "Custom", input: ["x": 1]) == "Custom")
        let long = String(repeating: "a", count: 200)
        #expect(StreamJSONParser.toolSummary(name: "Bash", input: ["command": long]).count == "Bash ".count + 120)
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter StreamJSONParserTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'StreamJSONParser' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Models/RunEvent.swift`:
```swift
import Foundation

/// The final `result` line of a headless run (`--output-format stream-json` and `json` share this shape).
public struct ClaudeRunResult: Hashable, Sendable, Codable {
    public var subtype: String
    public var isError: Bool
    public var sessionID: String?
    public var result: String?
    public var totalCostUSD: Double?
    public var numTurns: Int?
    public var durationMs: Int?
    public var permissionDenials: [String]

    public init(subtype: String, isError: Bool, sessionID: String? = nil, result: String? = nil,
                totalCostUSD: Double? = nil, numTurns: Int? = nil, durationMs: Int? = nil,
                permissionDenials: [String] = []) {
        self.subtype = subtype; self.isError = isError; self.sessionID = sessionID; self.result = result
        self.totalCostUSD = totalCostUSD; self.numTurns = numTurns; self.durationMs = durationMs
        self.permissionDenials = permissionDenials
    }

    public static let successSubtype = "success"
    public static let maxTurnsSubtype = "error_max_turns"
    public static let maxBudgetSubtype = "error_max_budget_usd"
    public static let executionErrorSubtype = "error_during_execution"

    public var isSuccess: Bool { subtype == Self.successSubtype && !isError }
    /// A limit was reached: never retry automatically, ask the user (spec §8).
    public var hitLimit: Bool { subtype == Self.maxTurnsSubtype || subtype == Self.maxBudgetSubtype }
}

/// One parsed line of the live stream.
public enum RunEvent: Hashable, Sendable {
    case initialized(sessionID: String?, model: String?)
    case assistantText(String)
    case toolUse(name: String, summary: String)
    case apiRetry(attempt: Int?)
    case result(ClaudeRunResult)
    case other(type: String)
}
```

`Sources/ShotcueCore/Logic/StreamJSONParser.swift`:
```swift
import Foundation

/// Tolerant NDJSON parser for `claude -p --output-format stream-json --verbose`.
/// Unknown shapes become `.other`; unparsable lines return nil so a log line never kills a run.
public enum StreamJSONParser {
    public static func parse(line: String) -> RunEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "system":
            let subtype = object["subtype"] as? String ?? ""
            switch subtype {
            case "init": return .initialized(sessionID: object["session_id"] as? String, model: object["model"] as? String)
            case "api_retry": return .apiRetry(attempt: object["attempt"] as? Int)
            default: return .other(type: "system/\(subtype)")
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return .other(type: type) }
            if let tool = content.first(where: { ($0["type"] as? String) == "tool_use" }) {
                let name = tool["name"] as? String ?? "?"
                let input = tool["input"] as? [String: Any] ?? [:]
                return .toolUse(name: name, summary: toolSummary(name: name, input: input))
            }
            let texts = content.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }
            return texts.isEmpty ? .other(type: type) : .assistantText(texts.joined(separator: "\n"))
        case "result":
            return .result(makeResult(object))
        default:
            return .other(type: type)
        }
    }

    /// "Read /tmp/a.png", "Bash git status"; falls back to the bare tool name. Values are capped at 120 chars.
    public static func toolSummary(name: String, input: [String: Any]) -> String {
        for key in ["file_path", "path", "command", "pattern", "query", "url", "notebook_path"] {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(name) \(value.prefix(120))"
            }
        }
        return name
    }

    static func makeResult(_ object: [String: Any]) -> ClaudeRunResult {
        let denials = (object["permission_denials"] as? [[String: Any]] ?? [])
            .compactMap { $0["tool_name"] as? String }
        return ClaudeRunResult(
            subtype: object["subtype"] as? String ?? "unknown",
            isError: object["is_error"] as? Bool ?? false,
            sessionID: object["session_id"] as? String,
            result: object["result"] as? String,
            totalCostUSD: object["total_cost_usd"] as? Double,
            numTurns: object["num_turns"] as? Int,
            durationMs: object["duration_ms"] as? Int,
            permissionDenials: denials)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter StreamJSONParserTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Models/RunEvent.swift Sources/ShotcueCore/Logic/StreamJSONParser.swift Tests/ShotcueCoreTests/StreamJSONParserTests.swift
git commit -m "feat(core): parse Claude stream-json events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: SchedulerRules ve QueuePolicy

**Files:**
- Create: `Sources/ShotcueCore/Logic/QueuePolicy.swift`, `Sources/ShotcueCore/Logic/SchedulerRules.swift`
- Test: `Tests/ShotcueCoreTests/QueuePolicyTests.swift`, `Tests/ShotcueCoreTests/SchedulerRulesTests.swift`

**Interfaces:**
- Produces: `QueuePolicy.ordered(_:)`, `QueuePolicy.nextRunnable(queued:runningProjectIDs:runningCount:maxConcurrent:) -> ShotTask?`; `ScheduledAction` (`enqueueTask(UUID)`, `fireDailyQueue(projectID:)`), `SchedulerRules.dueActions(now:calendar:tasks:projects:)`, `SchedulerRules.todaysFireDate(_:now:calendar:)`, `SchedulerRules.dailyCandidates(projectID:tasks:)`. Plan 04'teki `RunCoordinator` ve `SchedulerDriver` yalnızca bu fonksiyonları çağırır; zaman kararı burada, yan etkiler orada.

- [ ] **Step 1: Başarısız testleri yaz**

`Tests/ShotcueCoreTests/QueuePolicyTests.swift`:
```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("QueuePolicy")
struct QueuePolicyTests {
    let p1 = UUID(), p2 = UUID()
    let t0 = Date(timeIntervalSince1970: 1_758_500_000)

    func task(_ p: UUID?, sort: Double, created: TimeInterval = 0, status: TaskStatus = .queued) -> ShotTask {
        ShotTask(projectID: p, title: "t", status: status, sortIndex: sort, createdAt: t0.addingTimeInterval(created))
    }

    @Test func ordersBySortIndexThenCreatedAt() {
        let a = task(p1, sort: 2048, created: 0), b = task(p1, sort: 1024, created: 5), c = task(p1, sort: 1024, created: 1)
        #expect(QueuePolicy.ordered([a, b, c]).map(\.id) == [c, b, a].map(\.id))
    }

    @Test func skipsProjectsThatAlreadyRun() {
        let a = task(p1, sort: 1), b = task(p2, sort: 2)
        let next = QueuePolicy.nextRunnable(queued: [a, b], runningProjectIDs: [p1], runningCount: 1, maxConcurrent: 2)
        #expect(next?.id == b.id)
    }

    @Test func respectsGlobalLimit() {
        let a = task(p1, sort: 1)
        #expect(QueuePolicy.nextRunnable(queued: [a], runningProjectIDs: [p2], runningCount: 2, maxConcurrent: 2) == nil)
        #expect(QueuePolicy.nextRunnable(queued: [a], runningProjectIDs: [], runningCount: 0, maxConcurrent: 0)?.id == a.id)
    }

    @Test func ignoresNonQueuedAndProjectless() {
        let ready = task(p1, sort: 1, status: .ready), orphan = task(nil, sort: 0)
        #expect(QueuePolicy.nextRunnable(queued: [ready, orphan], runningProjectIDs: [], runningCount: 0, maxConcurrent: 2) == nil)
    }
}
```

`Tests/ShotcueCoreTests/SchedulerRulesTests.swift`:
```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("SchedulerRules")
struct SchedulerRulesTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    // 2025-09-22 10:00:00 UTC (yıl kuralları etkilemez)
    let now = Date(timeIntervalSince1970: 1_758_535_200)
    let pid = UUID()

    func project(time: String?, enabled: Bool = true, lastFired: Date? = nil) -> Project {
        Project(id: pid, name: "p", path: "/tmp/p", dailyTime: time.flatMap(DailyTime.init(parsing:)),
                dailyEnabled: enabled, dailyLastFiredAt: lastFired)
    }

    @Test func oneShotTasksDueWhenScheduledAtPassed() {
        let due = ShotTask(projectID: pid, title: "a", status: .scheduled, scheduledAt: now.addingTimeInterval(-1))
        let later = ShotTask(projectID: pid, title: "b", status: .scheduled, scheduledAt: now.addingTimeInterval(60))
        let notScheduled = ShotTask(projectID: pid, title: "c", status: .ready, scheduledAt: now.addingTimeInterval(-1))
        let actions = SchedulerRules.dueActions(now: now, calendar: cal, tasks: [due, later, notScheduled], projects: [])
        #expect(actions == [.enqueueTask(due.id)])
    }

    @Test func dailyFiresOncePerDayAfterItsTime() {
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: "09:30")])
                == [.fireDailyQueue(projectID: pid)])
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: "10:30")]) == [])
        let firedToday = project(time: "09:30", lastFired: now.addingTimeInterval(-600))
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [firedToday]) == [])
    }

    @Test func dailyCatchesUpAfterSleepButOnlyOnce() {
        let lateEvening = now.addingTimeInterval(13 * 3600)   // 23:00 same day
        let firedYesterday = project(time: "09:00", lastFired: now.addingTimeInterval(-24 * 3600))
        #expect(SchedulerRules.dueActions(now: lateEvening, calendar: cal, tasks: [], projects: [firedYesterday])
                == [.fireDailyQueue(projectID: pid)])
    }

    @Test func disabledOrMissingTimeNeverFires() {
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: "09:00", enabled: false)]) == [])
        #expect(SchedulerRules.dueActions(now: now, calendar: cal, tasks: [], projects: [project(time: nil)]) == [])
    }

    @Test func todaysFireDateUsesCalendarDay() {
        let fire = SchedulerRules.todaysFireDate(DailyTime(hour: 9, minute: 30), now: now, calendar: cal)
        #expect(fire == Date(timeIntervalSince1970: 1_758_533_400))   // 2025-09-22 09:30 UTC
    }

    @Test func dailyCandidatesAreReadyTasksOfProjectInOrder() {
        let other = UUID()
        let r2 = ShotTask(projectID: pid, title: "r2", status: .ready, sortIndex: 2)
        let r1 = ShotTask(projectID: pid, title: "r1", status: .ready, sortIndex: 1)
        let q = ShotTask(projectID: pid, title: "q", status: .queued, sortIndex: 0)
        let foreign = ShotTask(projectID: other, title: "f", status: .ready, sortIndex: 0)
        #expect(SchedulerRules.dailyCandidates(projectID: pid, tasks: [r2, q, foreign, r1]).map(\.id) == [r1.id, r2.id])
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter "QueuePolicyTests|SchedulerRulesTests" 2>&1 | grep -c "error:"`
Expected: 1'den büyük.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Logic/QueuePolicy.swift`:
```swift
import Foundation

/// Which queued task starts next (spec §5: manual order, one run per project, global limit).
public enum QueuePolicy {
    public static func ordered(_ tasks: [ShotTask]) -> [ShotTask] {
        tasks.sorted { a, b in
            a.sortIndex != b.sortIndex ? a.sortIndex < b.sortIndex : a.createdAt < b.createdAt
        }
    }

    public static func nextRunnable(queued: [ShotTask], runningProjectIDs: Set<UUID>,
                                    runningCount: Int, maxConcurrent: Int) -> ShotTask? {
        guard runningCount < max(1, maxConcurrent) else { return nil }
        return ordered(queued.filter { $0.status == .queued }).first { task in
            guard let projectID = task.projectID else { return false }
            return !runningProjectIDs.contains(projectID)
        }
    }
}
```

`Sources/ShotcueCore/Logic/SchedulerRules.swift`:
```swift
import Foundation

public enum ScheduledAction: Hashable, Sendable {
    case enqueueTask(UUID)
    case fireDailyQueue(projectID: UUID)
}

/// Pure time rules (spec §6.5). The driver applies actions: `enqueueTask` → `transition(to: .queued)`;
/// `fireDailyQueue` → enqueue `dailyCandidates` in order and set `project.dailyLastFiredAt = now`.
public enum SchedulerRules {
    public static func dueActions(now: Date, calendar: Calendar, tasks: [ShotTask], projects: [Project]) -> [ScheduledAction] {
        var actions: [ScheduledAction] = []
        for task in tasks where task.status == .scheduled {
            if let at = task.scheduledAt, at <= now { actions.append(.enqueueTask(task.id)) }
        }
        for project in projects where project.dailyEnabled {
            guard let time = project.dailyTime,
                  let fire = todaysFireDate(time, now: now, calendar: calendar),
                  fire <= now else { continue }
            if let last = project.dailyLastFiredAt, calendar.isDate(last, inSameDayAs: now) { continue }
            actions.append(.fireDailyQueue(projectID: project.id))
        }
        return actions
    }

    public static func todaysFireDate(_ time: DailyTime, now: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components)
    }

    /// Ready tasks of the project in manual order; queued ones are already in the queue.
    public static func dailyCandidates(projectID: UUID, tasks: [ShotTask]) -> [ShotTask] {
        QueuePolicy.ordered(tasks.filter { $0.projectID == projectID && $0.status == .ready })
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter "QueuePolicyTests|SchedulerRulesTests" 2>&1 | tail -3`
Expected: `Test run with 10 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Logic/QueuePolicy.swift Sources/ShotcueCore/Logic/SchedulerRules.swift Tests/ShotcueCoreTests/QueuePolicyTests.swift Tests/ShotcueCoreTests/SchedulerRulesTests.swift
git commit -m "feat(core): add queue policy and scheduler rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: GitSnapshot ve GitOutputParser

**Files:**
- Create: `Sources/ShotcueCore/Models/GitSnapshot.swift`
- Test: `Tests/ShotcueCoreTests/GitOutputParserTests.swift`

**Interfaces:**
- Produces: `GitSnapshot(head:isDirty:branch:)`, `GitOutputParser.snapshot(revParseHead:statusPorcelain:branchShowCurrent:) -> GitSnapshot?`, `GitOutputParser.branchName(for taskID:) -> String` (`shotcue/<ilk 8 hex>`). Plan 04 `git` komutlarının ham çıktısını buraya verir.

- [ ] **Step 1: Başarısız testi yaz**

```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("GitOutputParser")
struct GitOutputParserTests {
    let sha = "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"

    @Test func cleanRepoOnBranch() {
        let s = GitOutputParser.snapshot(revParseHead: sha + "\n", statusPorcelain: "", branchShowCurrent: "main\n")
        #expect(s == GitSnapshot(head: sha, isDirty: false, branch: "main"))
    }

    @Test func dirtyAndDetached() {
        let s = GitOutputParser.snapshot(revParseHead: sha.uppercased(), statusPorcelain: " M a.swift\n?? b\n", branchShowCurrent: "")
        #expect(s?.isDirty == true)
        #expect(s?.branch == nil)
        #expect(s?.head == sha)
    }

    @Test func invalidHeadReturnsNil() {
        #expect(GitOutputParser.snapshot(revParseHead: "fatal: not a git repository", statusPorcelain: "", branchShowCurrent: "") == nil)
        #expect(GitOutputParser.snapshot(revParseHead: "", statusPorcelain: "", branchShowCurrent: "") == nil)
    }

    @Test func branchNameUsesShortTaskID() {
        let id = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!
        #expect(GitOutputParser.branchName(for: id) == "shotcue/3f2a9c40")
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter GitOutputParserTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'GitOutputParser' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Models/GitSnapshot.swift`:
```swift
import Foundation

/// Working-tree state recorded before and after a run (spec §6.4 safety net).
public struct GitSnapshot: Hashable, Sendable, Codable {
    public var head: String
    public var isDirty: Bool
    public var branch: String?
    public init(head: String, isDirty: Bool, branch: String?) {
        self.head = head; self.isDirty = isDirty; self.branch = branch
    }
}

public enum GitOutputParser {
    /// Inputs are the raw stdout of `git rev-parse HEAD`, `git status --porcelain`, `git branch --show-current`.
    public static func snapshot(revParseHead: String, statusPorcelain: String, branchShowCurrent: String) -> GitSnapshot? {
        let head = revParseHead.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard head.count == 40, head.allSatisfy(\.isHexDigit) else { return nil }
        let dirty = !statusPorcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let branch = branchShowCurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitSnapshot(head: head, isDirty: dirty, branch: branch.isEmpty ? nil : branch)
    }

    public static func branchName(for taskID: UUID) -> String {
        "shotcue/" + taskID.uuidString.lowercased().prefix(8)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter GitOutputParserTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Models/GitSnapshot.swift Tests/ShotcueCoreTests/GitOutputParserTests.swift
git commit -m "feat(core): parse git state snapshots

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 9: FileStore (dosya düzeni ve göreli yollar)

**Files:**
- Create: `Sources/ShotcueCore/Services/FileStore.swift`
- Test: `Tests/ShotcueCoreTests/FileStoreTests.swift`

**Interfaces:**
- Produces: `FileStore(rootURL:)`, `FileStore.defaultRoot()`, `databaseURL`, `absoluteURL(for:)`, `relativePath(for:)`, `captureRelPath(id:date:calendar:)`, `thumbRelPath(id:)`, `audioRelPath(id:)`, `runLogRelPath(id:)`, `promptRelPath(id:)`, `ensureDirectories()`, `ensureParentDirectory(for:)`. Tüm modüller diske yalnızca bu yollarla dokunur; DB'ye yalnızca göreli yol yazılır.

- [ ] **Step 1: Başarısız testi yaz**

```swift
import Foundation
import Testing
@testable import ShotcueCore

@Suite("FileStore")
struct FileStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shotcue-fs-\(UUID().uuidString)", isDirectory: true)
    let id = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func relativePathsFollowSpecLayout() {
        let fs = FileStore(rootURL: root)
        let date = Date(timeIntervalSince1970: 1_790_078_400)   // 2026-09-22 12:00 UTC
        #expect(fs.captureRelPath(id: id, date: date, calendar: utc) == "captures/2026/09/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.png")
        #expect(fs.thumbRelPath(id: id) == "thumbs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.jpg")
        #expect(fs.audioRelPath(id: id) == "audio/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.m4a")
        #expect(fs.runLogRelPath(id: id) == "runs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.jsonl")
        #expect(fs.promptRelPath(id: id) == "runs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73-prompt.md")
        #expect(fs.databaseURL.lastPathComponent == "shotcue.sqlite")
    }

    @Test func absoluteAndRelativeRoundTrip() {
        let fs = FileStore(rootURL: root)
        let abs = fs.absoluteURL(for: "audio/x.m4a")
        #expect(abs.path.hasSuffix("/audio/x.m4a"))
        #expect(fs.relativePath(for: abs) == "audio/x.m4a")
        #expect(fs.relativePath(for: URL(fileURLWithPath: "/etc/hosts")) == nil)
    }

    @Test func ensureDirectoriesCreatesLayout() throws {
        let fs = FileStore(rootURL: root)
        try fs.ensureDirectories()
        for dir in ["captures", "thumbs", "audio", "runs"] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).path, isDirectory: &isDir) && isDir.boolValue)
        }
        let rel = fs.captureRelPath(id: id, date: Date(), calendar: utc)
        try fs.ensureParentDirectory(for: rel)
        #expect(FileManager.default.fileExists(atPath: fs.absoluteURL(for: rel).deletingLastPathComponent().path))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func defaultRootIsApplicationSupportShotcue() {
        #expect(FileStore.defaultRoot().path.hasSuffix("/Library/Application Support/Shotcue"))
    }
}
```

- [ ] **Step 2: Derlenmediğini gör**

Run: `swift test --filter FileStoreTests 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'FileStore' in scope`.

- [ ] **Step 3: Uygulamayı yaz**

`Sources/ShotcueCore/Services/FileStore.swift`:
```swift
import Foundation

/// On-disk layout (spec §6.3). The DB stores paths relative to `rootURL` so the folder can move.
public struct FileStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }

    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Shotcue", isDirectory: true)
    }

    public static let capturesDir = "captures"
    public static let thumbsDir = "thumbs"
    public static let audioDir = "audio"
    public static let runsDir = "runs"

    public var databaseURL: URL { rootURL.appendingPathComponent("shotcue.sqlite") }

    public func absoluteURL(for relPath: String) -> URL { rootURL.appendingPathComponent(relPath) }

    /// Inverse of `absoluteURL(for:)`; nil when the URL is outside the root.
    public func relativePath(for url: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    public func captureRelPath(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%@/%04d/%02d/%@.png", Self.capturesDir, c.year ?? 0, c.month ?? 0, id.uuidString.lowercased())
    }
    public func thumbRelPath(id: UUID) -> String { "\(Self.thumbsDir)/\(id.uuidString.lowercased()).jpg" }
    public func audioRelPath(id: UUID) -> String { "\(Self.audioDir)/\(id.uuidString.lowercased()).m4a" }
    public func runLogRelPath(id: UUID) -> String { "\(Self.runsDir)/\(id.uuidString.lowercased()).jsonl" }
    public func promptRelPath(id: UUID) -> String { "\(Self.runsDir)/\(id.uuidString.lowercased())-prompt.md" }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for dir in [Self.capturesDir, Self.thumbsDir, Self.audioDir, Self.runsDir] {
            try fileManager.createDirectory(at: rootURL.appendingPathComponent(dir, isDirectory: true),
                                            withIntermediateDirectories: true)
        }
    }

    public func ensureParentDirectory(for relPath: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: absoluteURL(for: relPath).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 4: Testleri çalıştır**

Run: `swift test --filter FileStoreTests 2>&1 | tail -3`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueCore/Services/FileStore.swift Tests/ShotcueCoreTests/FileStoreTests.swift
git commit -m "feat(core): add file store layout

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Servis protokolleri ve ShotcueTestSupport fake'leri

**Files:**
- Create: `Sources/ShotcueCore/Services/CaptureServices.swift`, `Sources/ShotcueCore/Services/NoteServices.swift`, `Sources/ShotcueCore/Services/ClaudeServices.swift`, `Sources/ShotcueCore/Services/Repositories.swift`, `Sources/ShotcueCore/Services/Infrastructure.swift`
- Create: `Sources/ShotcueTestSupport/Locked.swift`, `Sources/ShotcueTestSupport/FakeServices.swift`, `Sources/ShotcueTestSupport/InMemoryRepositories.swift`
- Delete: `Sources/ShotcueTestSupport/ShotcueTestSupport.swift` yer tutucusu (artık gerçek dosyalar var)
- Test: `Tests/ShotcueCoreTests/FakesTests.swift`

**Interfaces:**
- Produces (bütün planların sözleşmesi; imzalar birebir): aşağıdaki protokoller ve `ShotcueTestSupport` içindeki `Fake*` / `InMemory*` tipleri. Plan 01 `InMemory*`'nin GRDB karşılığını yazar; Plan 02 `CaptureService/ThumbnailService/PermissionService/HotKeyService`; Plan 03 `AudioRecorder/Transcriber/TranscriptionQueue`; Plan 04 `ClaudeRunner/GitInspector/HandoffService/Notifier/TaskDispatcher`; Plan 05 (UI) yalnızca bu protokolleri kullanır; Plan 06 (App) hepsini `AppEnvironment`'ta birleştirir.

- [ ] **Step 1: Protokolleri yaz**

`Sources/ShotcueCore/Services/CaptureServices.swift`:
```swift
import Foundation

public struct CaptureResult: Hashable, Sendable {
    public var fileURL: URL
    public var width: Int
    public var height: Int
    public var scale: Double
    public init(fileURL: URL, width: Int, height: Int, scale: Double) {
        self.fileURL = fileURL; self.width = width; self.height = height; self.scale = scale
    }
}

/// Region screenshot. v1 wraps `/usr/sbin/screencapture -i -s`; returns nil when the user cancels (ESC).
public protocol CaptureService: Sendable {
    func captureRegion(to destination: URL) async throws -> CaptureResult?
}

public protocol ThumbnailService: Sendable {
    /// Writes a JPEG whose longest side is `maxPixel`.
    func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws
}

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

/// Global hotkey (Carbon RegisterEventHotKey in Plan 02). One combo at a time.
public protocol HotKeyService: Sendable {
    func register(_ combo: KeyCombo, handler: @escaping @Sendable () -> Void) throws
    func unregister()
}
```

`Sources/ShotcueCore/Services/NoteServices.swift`:
```swift
import Foundation

public struct RecordingInfo: Hashable, Sendable {
    public var fileURL: URL
    public var duration: TimeInterval
    public init(fileURL: URL, duration: TimeInterval) { self.fileURL = fileURL; self.duration = duration }
}

/// Microphone recorder writing AAC .m4a. `levels` yields RMS 0…1 while recording (level meter).
public protocol AudioRecorder: Sendable {
    func start(writingTo url: URL) async throws
    func stop() async throws -> RecordingInfo
    var levels: AsyncStream<Float> { get }
}

public enum TranscriberModelState: Hashable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)
}

/// Speech-to-text on a finished audio file (WhisperKit in Plan 03). `language` is a BCP-47 base code ("tr", "en").
public protocol Transcriber: Sendable {
    var engineName: String { get }
    func modelState() async -> TranscriberModelState
    func downloadModel() async throws
    func transcribe(fileURL: URL, language: String) async throws -> Transcript
}

/// Background transcription of pending voice notes (implemented by `TranscriptionCoordinator` in ShotcueNotes).
/// UI calls `enqueue` after a recording is saved; the app calls `processPending` at launch and when the model becomes ready.
public protocol TranscriptionQueue: Sendable {
    func enqueue(voiceNoteID: UUID) async
    func processPending() async
}
```

`Sources/ShotcueCore/Services/ClaudeServices.swift`:
```swift
import Foundation

public enum ClaudePermissionMode: String, Sendable, Codable, CaseIterable {
    case bypassPermissions, acceptEdits, dontAsk
}

/// Everything the runner needs to build the `claude -p` command line (spec §6.4).
public struct RunSpec: Hashable, Sendable {
    public var runID: UUID
    public var prompt: String
    public var projectPath: String
    public var mode: TaskMode
    public var model: String?
    public var effort: String?
    public var maxTurns: Int
    public var maxBudgetUSD: Double
    public var timeout: TimeInterval
    public var permissionMode: ClaudePermissionMode
    public var addDirs: [String]
    public var systemPromptAppend: String

    public init(runID: UUID, prompt: String, projectPath: String, mode: TaskMode, model: String? = nil,
                effort: String? = nil, maxTurns: Int = 50, maxBudgetUSD: Double = 5, timeout: TimeInterval = 1800,
                permissionMode: ClaudePermissionMode = .bypassPermissions, addDirs: [String] = [],
                systemPromptAppend: String = PromptBuilder.systemPromptAppend) {
        self.runID = runID; self.prompt = prompt; self.projectPath = projectPath; self.mode = mode
        self.model = model; self.effort = effort; self.maxTurns = maxTurns; self.maxBudgetUSD = maxBudgetUSD
        self.timeout = timeout; self.permissionMode = permissionMode; self.addDirs = addDirs
        self.systemPromptAppend = systemPromptAppend
    }
}

public protocol ClaudeRunner: Sendable {
    /// Streams events while running; resolves with the final result. Throws when the process cannot start,
    /// exits non-zero without a result line, times out, or is cancelled.
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult
    func cancel(runID: UUID) async
    /// Output of `claude --version`, e.g. "2.1.278 (Claude Code)".
    func version() async throws -> String
}

public protocol GitInspector: Sendable {
    func snapshot(at path: String) async -> GitSnapshot?
    func createBranch(_ name: String, at path: String) async throws
    func stashAll(at path: String) async throws
}

/// Hands a finished (or pending) task to the terminal / Claude Desktop (spec §6.4).
public protocol HandoffService: Sendable {
    func openInTerminal(sessionID: String) throws
    func openInDesktop(sessionID: String) throws
    func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws
}

/// UI-facing façade over the run coordinator (implemented by `RunCoordinator` in ShotcueClaudeBridge).
/// UI never imports ShotcueClaudeBridge; it talks to this protocol.
public protocol TaskDispatcher: Sendable {
    /// Moves the task to `queued` (via `transition`) and pumps the queue.
    func enqueue(taskID: UUID) async throws
    /// Cancels the running run of the task (SIGINT) or removes it from the queue (→ `ready`).
    func cancel(taskID: UUID) async
    /// Enqueues every `ready` task of every project in manual order, then pumps.
    func runQueueNow() async
    func setPaused(_ paused: Bool) async
    func isPaused() async -> Bool
    /// Live events of a run in progress; finishes when the run ends. Empty stream for unknown ids.
    func liveEvents(runID: UUID) -> AsyncStream<RunEvent>
}
```

`Sources/ShotcueCore/Services/Repositories.swift`:
```swift
import Foundation

public protocol ProjectRepository: Sendable {
    func allProjects() async throws -> [Project]
    func project(id: UUID) async throws -> Project?
    func save(_ project: Project) async throws
    func deleteProject(id: UUID) async throws
    /// Emits the full list now and after every change.
    func observeProjects() -> AsyncStream<[Project]>
}

public protocol TaskRepository: Sendable {
    func allTasks() async throws -> [ShotTask]
    func task(id: UUID) async throws -> ShotTask?
    /// `projectID == nil` → inbox (tasks without a project).
    func tasks(projectID: UUID?) async throws -> [ShotTask]
    func tasks(status: TaskStatus) async throws -> [ShotTask]
    func save(_ task: ShotTask) async throws
    /// Deletes the task and its captures/voice notes rows (files are the caller's job).
    func deleteTask(id: UUID) async throws
    func captures(taskID: UUID) async throws -> [Capture]
    func save(_ capture: Capture) async throws
    func moveCaptures(ids: [UUID], toTaskID: UUID) async throws
    func voiceNotes(taskID: UUID) async throws -> [VoiceNote]
    func save(_ voiceNote: VoiceNote) async throws
    /// Case-insensitive substring search over title, noteText and voice transcripts.
    func search(_ query: String) async throws -> [ShotTask]
    func observeAllTasks() -> AsyncStream<[ShotTask]>
    func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]>
}

public protocol RunRepository: Sendable {
    func runs(taskID: UUID) async throws -> [Run]
    func run(id: UUID) async throws -> Run?
    func save(_ run: Run) async throws
    /// Runs in `starting` or `running` state.
    func activeRuns() async throws -> [Run]
    /// On launch: marks leftover active runs as failed("interrupted"); returns how many.
    func markInterruptedRuns(at now: Date) async throws -> Int
    func observeRuns(taskID: UUID) -> AsyncStream<[Run]>
}
```

`Sources/ShotcueCore/Services/Infrastructure.swift`:
```swift
import Foundation

public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public struct AppNotification: Hashable, Sendable {
    public enum Kind: String, Sendable { case runDone, runFailed }
    public var kind: Kind
    public var title: String
    public var body: String
    public var taskID: UUID?
    public var runID: UUID?
    public init(kind: Kind, title: String, body: String, taskID: UUID? = nil, runID: UUID? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.taskID = taskID; self.runID = runID
    }
}

public protocol Notifier: Sendable {
    func notify(_ notification: AppNotification) async
}
```

- [ ] **Step 2: Fake'leri yaz (ShotcueTestSupport)**

`Sources/ShotcueTestSupport/Locked.swift`:
```swift
import Foundation

/// Minimal lock box so fakes can be `Sendable` classes with mutable state.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
    public func set(_ newValue: Value) { withLock { $0 = newValue } }
}

public struct FakeError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
```

`Sources/ShotcueTestSupport/FakeServices.swift`:
```swift
import Foundation
import ShotcueCore

public final class FakeCaptureService: CaptureService, @unchecked Sendable {
    public enum Behavior: Sendable { case success(width: Int, height: Int, scale: Double), cancel, failure(String) }
    public let behavior: Locked<Behavior>
    public let calls = Locked<[URL]>([])
    public init(behavior: Behavior = .success(width: 128, height: 64, scale: 2)) { self.behavior = Locked(behavior) }
    public func captureRegion(to destination: URL) async throws -> CaptureResult? {
        calls.withLock { $0.append(destination) }
        switch behavior.current {
        case .cancel: return nil
        case .failure(let message): throw FakeError(message)
        case .success(let w, let h, let s):
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: destination)
            return CaptureResult(fileURL: destination, width: w, height: h, scale: s)
        }
    }
}

public final class FakeThumbnailService: ThumbnailService, @unchecked Sendable {
    public let calls = Locked<[(source: URL, destination: URL, maxPixel: Int)]>([])
    public init() {}
    public func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws {
        calls.withLock { $0.append((source, destination, maxPixel)) }
        try Data("thumb".utf8).write(to: destination)
    }
}

public final class FakePermissionService: PermissionService, @unchecked Sendable {
    public let states: Locked<[PermissionKind: PermissionState]>
    public let grantOnRequest: Locked<Bool>
    public let opened = Locked<[PermissionKind]>([])
    public init(states: [PermissionKind: PermissionState] = [:], grantOnRequest: Bool = true) {
        self.states = Locked(states); self.grantOnRequest = Locked(grantOnRequest)
    }
    public func state(of kind: PermissionKind) async -> PermissionState { states.current[kind] ?? .notDetermined }
    public func request(_ kind: PermissionKind) async -> PermissionState {
        let result: PermissionState = grantOnRequest.current ? .granted : .denied
        states.withLock { $0[kind] = result }
        return result
    }
    public func openSystemSettings(for kind: PermissionKind) { opened.withLock { $0.append(kind) } }
}

public final class FakeHotKeyService: HotKeyService, @unchecked Sendable {
    public let registered = Locked<KeyCombo?>(nil)
    private let handler = Locked<(@Sendable () -> Void)?>(nil)
    public init() {}
    public func register(_ combo: KeyCombo, handler: @escaping @Sendable () -> Void) throws {
        registered.set(combo); self.handler.set(handler)
    }
    public func unregister() { registered.set(nil); handler.set(nil) }
    /// Simulates the user pressing the hotkey.
    public func press() { handler.current?() }
}

public final class FakeAudioRecorder: AudioRecorder, @unchecked Sendable {
    public let startedURLs = Locked<[URL]>([])
    public let stopDuration: Locked<TimeInterval>
    public let levels: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation
    public init(stopDuration: TimeInterval = 3.5) {
        self.stopDuration = Locked(stopDuration)
        let (stream, cont) = AsyncStream<Float>.makeStream()
        levels = stream; continuation = cont
    }
    public func start(writingTo url: URL) async throws {
        startedURLs.withLock { $0.append(url) }
        try Data("m4a".utf8).write(to: url)
    }
    public func stop() async throws -> RecordingInfo {
        let url = startedURLs.current.last ?? URL(fileURLWithPath: "/dev/null")
        return RecordingInfo(fileURL: url, duration: stopDuration.current)
    }
    public func emitLevel(_ level: Float) { continuation.yield(level) }
}

public final class FakeTranscriber: Transcriber, @unchecked Sendable {
    public let engineName = "fake"
    public let state: Locked<TranscriberModelState>
    public let result: Locked<Result<Transcript, FakeError>>
    public let calls = Locked<[(fileURL: URL, language: String)]>([])
    public init(state: TranscriberModelState = .ready,
                result: Result<Transcript, FakeError> = .success(Transcript(text: "merhaba dünya", language: "tr", engine: "fake"))) {
        self.state = Locked(state); self.result = Locked(result)
    }
    public func modelState() async -> TranscriberModelState { state.current }
    public func downloadModel() async throws { state.set(.ready) }
    public func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        calls.withLock { $0.append((fileURL, language)) }
        return try result.current.get()
    }
}

/// Replays scripted events, then returns the scripted result (or throws). Records every spec it was given.
public final class FakeClaudeRunner: ClaudeRunner, @unchecked Sendable {
    public let events: Locked<[RunEvent]>
    public let outcome: Locked<Result<ClaudeRunResult, FakeError>>
    public let specs = Locked<[RunSpec]>([])
    public let cancelled = Locked<[UUID]>([])
    public let eventDelay: Locked<Duration>
    public let versionString: Locked<String>
    public init(events: [RunEvent] = [], outcome: Result<ClaudeRunResult, FakeError> = .success(ClaudeRunResult(subtype: "success", isError: false)),
                eventDelay: Duration = .zero, version: String = "2.1.278 (Claude Code)") {
        self.events = Locked(events); self.outcome = Locked(outcome); self.eventDelay = Locked(eventDelay); versionString = Locked(version)
    }
    public func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        specs.withLock { $0.append(spec) }
        for event in events.current {
            if eventDelay.current > .zero { try await Task.sleep(for: eventDelay.current) }
            try Task.checkCancellation()
            onEvent(event)
        }
        var result = try outcome.current.get()
        if result.sessionID == nil { result.sessionID = spec.runID.uuidString }
        return result
    }
    public func cancel(runID: UUID) async { cancelled.withLock { $0.append(runID) } }
    public func version() async throws -> String { versionString.current }
}

public final class FakeGitInspector: GitInspector, @unchecked Sendable {
    public let snapshots: Locked<[String: GitSnapshot]>
    public let branches = Locked<[(name: String, path: String)]>([])
    public let stashes = Locked<[String]>([])
    public init(snapshots: [String: GitSnapshot] = [:]) { self.snapshots = Locked(snapshots) }
    public func snapshot(at path: String) async -> GitSnapshot? { snapshots.current[path] }
    public func createBranch(_ name: String, at path: String) async throws {
        branches.withLock { $0.append((name, path)) }
        snapshots.withLock { $0[path]?.branch = name }
    }
    public func stashAll(at path: String) async throws {
        stashes.withLock { $0.append(path) }
        snapshots.withLock { $0[path]?.isDirty = false }
    }
}

public final class MutableClock: Clock, @unchecked Sendable {
    private let value: Locked<Date>
    public init(_ now: Date = Date(timeIntervalSince1970: 1_758_500_000)) { value = Locked(now) }
    public var now: Date { value.current }
    public func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    public func set(_ date: Date) { value.set(date) }
}

public final class FakeNotifier: Notifier, @unchecked Sendable {
    public let sent = Locked<[AppNotification]>([])
    public init() {}
    public func notify(_ notification: AppNotification) async { sent.withLock { $0.append(notification) } }
}

public final class FakeHandoffService: HandoffService, @unchecked Sendable {
    public let actions = Locked<[String]>([])
    public init() {}
    public func openInTerminal(sessionID: String) throws { actions.withLock { $0.append("terminal:\(sessionID)") } }
    public func openInDesktop(sessionID: String) throws { actions.withLock { $0.append("desktop:\(sessionID)") } }
    public func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws {
        actions.withLock { $0.append("composer:\(projectPath):\(files.count)") }
    }
}

/// Records dispatch calls; `emit(runID:event:)` feeds `liveEvents` subscribers (uses `Broadcaster` from InMemoryRepositories.swift).
public final class FakeTaskDispatcher: TaskDispatcher, @unchecked Sendable {
    public let enqueued = Locked<[UUID]>([])
    public let cancelledTasks = Locked<[UUID]>([])
    public let runQueueCalls = Locked(0)
    public let paused = Locked(false)
    private let broadcasters = Locked<[UUID: Broadcaster<RunEvent>]>([:])
    public init() {}
    public func enqueue(taskID: UUID) async throws { enqueued.withLock { $0.append(taskID) } }
    public func cancel(taskID: UUID) async { cancelledTasks.withLock { $0.append(taskID) } }
    public func runQueueNow() async { runQueueCalls.withLock { $0 += 1 } }
    public func setPaused(_ value: Bool) async { paused.set(value) }
    public func isPaused() async -> Bool { paused.current }
    public func liveEvents(runID: UUID) -> AsyncStream<RunEvent> {
        let b = broadcasters.withLock { dict -> Broadcaster<RunEvent> in
            if let existing = dict[runID] { return existing }
            let created = Broadcaster<RunEvent>(); dict[runID] = created; return created
        }
        return b.stream(initial: .other(type: "subscribed"))
    }
    public func emit(runID: UUID, event: RunEvent) { broadcasters.current[runID]?.send(event) }
}

public final class FakeTranscriptionQueue: TranscriptionQueue, @unchecked Sendable {
    public let enqueued = Locked<[UUID]>([])
    public let processPendingCalls = Locked(0)
    public init() {}
    public func enqueue(voiceNoteID: UUID) async { enqueued.withLock { $0.append(voiceNoteID) } }
    public func processPending() async { processPendingCalls.withLock { $0 += 1 } }
}
```

`Sources/ShotcueTestSupport/InMemoryRepositories.swift`:
```swift
import Foundation
import ShotcueCore

/// Broadcasts a value to any number of AsyncStream subscribers.
public final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private let continuations = Locked<[UUID: AsyncStream<Value>.Continuation]>([:])
    public init() {}
    public func stream(initial: Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.yield(initial)
            continuation.onTermination = { [continuations] _ in continuations.withLock { $0[id] = nil } }
        }
    }
    public func send(_ value: Value) { continuations.current.values.forEach { $0.yield(value) } }
}

public final class InMemoryProjectRepository: ProjectRepository, @unchecked Sendable {
    public let storage = Locked<[UUID: Project]>([:])
    private let broadcaster = Broadcaster<[Project]>()
    public init(_ projects: [Project] = []) { storage.set(Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })) }
    private var sorted: [Project] { storage.current.values.sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.createdAt < $1.createdAt } }
    public func allProjects() async throws -> [Project] { sorted }
    public func project(id: UUID) async throws -> Project? { storage.current[id] }
    public func save(_ project: Project) async throws { storage.withLock { $0[project.id] = project }; broadcaster.send(sorted) }
    public func deleteProject(id: UUID) async throws { storage.withLock { $0[id] = nil }; broadcaster.send(sorted) }
    public func observeProjects() -> AsyncStream<[Project]> { broadcaster.stream(initial: sorted) }
}

public final class InMemoryTaskRepository: TaskRepository, @unchecked Sendable {
    public let tasksStorage = Locked<[UUID: ShotTask]>([:])
    public let capturesStorage = Locked<[UUID: Capture]>([:])
    public let voiceStorage = Locked<[UUID: VoiceNote]>([:])
    private let broadcaster = Broadcaster<[ShotTask]>()
    public init(_ tasks: [ShotTask] = []) { tasksStorage.set(Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })) }

    private var all: [ShotTask] { QueuePolicy.ordered(Array(tasksStorage.current.values)) }
    private func notify() { broadcaster.send(all) }

    public func allTasks() async throws -> [ShotTask] { all }
    public func task(id: UUID) async throws -> ShotTask? { tasksStorage.current[id] }
    public func tasks(projectID: UUID?) async throws -> [ShotTask] { all.filter { $0.projectID == projectID } }
    public func tasks(status: TaskStatus) async throws -> [ShotTask] { all.filter { $0.status == status } }
    public func save(_ task: ShotTask) async throws { tasksStorage.withLock { $0[task.id] = task }; notify() }
    public func deleteTask(id: UUID) async throws {
        tasksStorage.withLock { $0[id] = nil }
        capturesStorage.withLock { $0 = $0.filter { $0.value.taskID != id } }
        voiceStorage.withLock { $0 = $0.filter { $0.value.taskID != id } }
        notify()
    }
    public func captures(taskID: UUID) async throws -> [Capture] {
        capturesStorage.current.values.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ capture: Capture) async throws { capturesStorage.withLock { $0[capture.id] = capture }; notify() }
    public func moveCaptures(ids: [UUID], toTaskID: UUID) async throws {
        capturesStorage.withLock { for id in ids { $0[id]?.taskID = toTaskID } }
        notify()
    }
    public func voiceNotes(taskID: UUID) async throws -> [VoiceNote] {
        voiceStorage.current.values.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ voiceNote: VoiceNote) async throws { voiceStorage.withLock { $0[voiceNote.id] = voiceNote }; notify() }
    public func search(_ query: String) async throws -> [ShotTask] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        let transcriptsByTask = Dictionary(grouping: voiceStorage.current.values, by: \.taskID)
        return all.filter { task in
            task.title.lowercased().contains(q) || task.noteText.lowercased().contains(q)
                || (transcriptsByTask[task.id] ?? []).contains { ($0.transcript ?? "").lowercased().contains(q) }
        }
    }
    public func observeAllTasks() -> AsyncStream<[ShotTask]> { broadcaster.stream(initial: all) }
    public func observeTasks(projectID: UUID?) -> AsyncStream<[ShotTask]> {
        let upstream = broadcaster.stream(initial: all)
        return AsyncStream { continuation in
            let task = Task {
                for await list in upstream { continuation.yield(list.filter { $0.projectID == projectID }) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public final class InMemoryRunRepository: RunRepository, @unchecked Sendable {
    public let storage = Locked<[UUID: Run]>([:])
    private let broadcaster = Broadcaster<[Run]>()
    public init(_ runs: [Run] = []) { storage.set(Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })) }
    private var all: [Run] { storage.current.values.sorted { $0.startedAt < $1.startedAt } }
    public func runs(taskID: UUID) async throws -> [Run] { all.filter { $0.taskID == taskID } }
    public func run(id: UUID) async throws -> Run? { storage.current[id] }
    public func save(_ run: Run) async throws { storage.withLock { $0[run.id] = run }; broadcaster.send(all) }
    public func activeRuns() async throws -> [Run] { all.filter { $0.state == .starting || $0.state == .running } }
    public func markInterruptedRuns(at now: Date) async throws -> Int {
        var count = 0
        storage.withLock { dict in
            for (id, var run) in dict where run.state == .starting || run.state == .running {
                run.state = .failed; run.error = "interrupted"; run.finishedAt = now
                dict[id] = run; count += 1
            }
        }
        broadcaster.send(all)
        return count
    }
    public func observeRuns(taskID: UUID) -> AsyncStream<[Run]> {
        let upstream = broadcaster.stream(initial: all)
        return AsyncStream { continuation in
            let task = Task {
                for await list in upstream { continuation.yield(list.filter { $0.taskID == taskID }) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 3: Fake'lerin davranışını doğrulayan testi yaz**

`Tests/ShotcueCoreTests/FakesTests.swift`:
```swift
import Foundation
import Testing
@testable import ShotcueCore
import ShotcueTestSupport

@Suite("TestSupport fakes")
struct FakesTests {
    @Test func fakeRunnerReplaysEventsAndFillsSessionID() async throws {
        let runner = FakeClaudeRunner(events: [.assistantText("hi"), .toolUse(name: "Read", summary: "Read a.png")])
        let spec = RunSpec(runID: UUID(), prompt: "p", projectPath: "/tmp", mode: .implement)
        let received = Locked<[RunEvent]>([])
        let result = try await runner.run(spec) { event in received.withLock { $0.append(event) } }
        #expect(received.current == [.assistantText("hi"), .toolUse(name: "Read", summary: "Read a.png")])
        #expect(result.sessionID == spec.runID.uuidString)
        #expect(runner.specs.current.count == 1)
    }

    @Test func inMemoryTaskRepositorySearchesTranscripts() async throws {
        let repo = InMemoryTaskRepository()
        let t = ShotTask(projectID: UUID(), title: "Login", noteText: "buton", status: .ready)
        try await repo.save(t)
        try await repo.save(VoiceNote(taskID: t.id, relPath: "audio/a.m4a", durationSec: 2, transcript: "cache temizle"))
        #expect(try await repo.search("CACHE").map(\.id) == [t.id])
        #expect(try await repo.search("yok").isEmpty)
        #expect(try await repo.tasks(projectID: nil).isEmpty)
    }

    @Test func inMemoryTaskRepositoryObservesChanges() async throws {
        let repo = InMemoryTaskRepository()
        let stream = repo.observeAllTasks()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await repo.save(ShotTask(title: "x"))
        #expect(await iterator.next()?.count == 1)
    }

    @Test func runRepositoryMarksInterrupted() async throws {
        let repo = InMemoryRunRepository([Run(taskID: UUID(), state: .running, logRelPath: "runs/a.jsonl"),
                                          Run(taskID: UUID(), state: .succeeded, logRelPath: "runs/b.jsonl")])
        let now = Date()
        #expect(try await repo.markInterruptedRuns(at: now) == 1)
        #expect(try await repo.activeRuns().isEmpty)
    }

    @Test func permissionAndHotKeyFakes() async {
        let perms = FakePermissionService(grantOnRequest: false)
        #expect(await perms.request(.microphone) == .denied)
        #expect(await perms.state(of: .microphone) == .denied)
        let hotkey = FakeHotKeyService()
        let fired = Locked(0)
        try? hotkey.register(.defaultCombo) { fired.withLock { $0 += 1 } }
        hotkey.press()
        #expect(fired.current == 1 && hotkey.registered.current == KeyCombo.defaultCombo)
    }
}
```

- [ ] **Step 4: Testleri çalıştır ve tüm paketi derle**

Run: `swift build 2>&1 | grep -E "error|warning: unused" ; swift test --filter FakesTests 2>&1 | tail -3`
Expected: derleme hatası yok; `Test run with 5 tests … passed`.

- [ ] **Step 5: Tüm Core testlerini çalıştır ve commit'le**

Run: `swift test --filter ShotcueCoreTests 2>&1 | tail -3`
Expected: Task 1–10'daki tüm testler geçer (toplam 55; Core smoke testiyle 56).

```bash
make format && git add Sources/ShotcueCore/Services Sources/ShotcueTestSupport Tests/ShotcueCoreTests/FakesTests.swift
git rm -q Sources/ShotcueTestSupport/ShotcueTestSupport.swift 2>/dev/null || true
git commit -m "feat(core): define service protocols and shared test fakes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Spike doğrulamaları (S1, S2, S3, S5) — kod yazmadan önce mimariyi kanıtla

**Files:**
- Modify: `Sources/ShotcueApp/ShotcueApp.swift` (geçici `SHOTCUE_SPIKE` ortam değişkeni işleyicisi; Plan 05 bunu "Tanılama" olarak Ayarlar'a taşır)
- Create: `docs/superpowers/plans/spike-results.md` (ölçüm sonuçları)

**Interfaces:**
- Produces: bir bundle'dan spawn edilen `claude`'un abonelik kimliğini görebildiği (S1), self-signed imzayla Ekran Kaydı izninin rebuild sonrası korunduğu (S2), `screencapture -i -s`'nin bundle'dan çalışıp iptalde exit 1 verdiği (S3) ve `claude://code/new?file=` deep link'inin görsel ekleyip eklemediği (S5) kayda geçmiş olur. **S4 (WhisperKit Türkçe kalitesi) Plan 03'ün ilk task'ında yapılır.**

- [ ] **Step 1: Sertifikayı üret (kullanıcı adımı, bir kez)**

Run: `make cert`
Expected: `Certificate ready: Shotcue Dev`. `security add-trusted-cert` başarısız olursa Keychain Access → login → Certificates → "Shotcue Dev" → Get Info → Trust → Code Signing: Always Trust yapılır, komut tekrar çalıştırılır.

- [ ] **Step 2: Spike işleyicisini ekle**

`Sources/ShotcueApp/ShotcueApp.swift` dosyasına `@main struct ShotcueApp` içinde bir `init()` ekle:
```swift
    init() {
        SpikeRunner.runIfRequested()
    }
```
ve aynı dosyaya (dosya sonuna) şunu ekle:
```swift
import Foundation

/// Temporary diagnostics used by Plan 00 Task 11. Triggered only by SHOTCUE_SPIKE=auth|capture.
enum SpikeRunner {
    static func runIfRequested() {
        guard let spike = ProcessInfo.processInfo.environment["SHOTCUE_SPIKE"] else { return }
        let output = URL(fileURLWithPath: "/tmp/shotcue-spike-\(spike).txt")
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        let process = Process()
        process.environment = env
        switch spike {
        case "auth":
            process.executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/claude")
            process.arguments = ["auth", "status"]
        case "capture":
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-x", "-t", "png", "/tmp/shotcue-spike-capture.png"]
        default:
            return
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        var text = "spike=\(spike)\n"
        do {
            try process.run()
            process.waitUntilExit()
            text += "exit=\(process.terminationStatus)\n"
            text += "stdout=\(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")\n"
            text += "stderr=\(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")\n"
        } catch {
            text += "launch-error=\(error)\n"
        }
        try? text.write(to: output, atomically: true, encoding: .utf8)
        exit(0)
    }
}
```

- [ ] **Step 3: S1 — bundle'dan `claude auth status`**

Run: `make install && open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=auth && sleep 5 && cat /tmp/shotcue-spike-auth.txt`
Expected: `exit=0` ve stdout'ta `"loggedIn": true` ile `"subscriptionType": "max"`. `loggedIn: false` veya keychain hatası görünürse Plan 04 başlamadan önce durulur ve kullanıcıya raporlanır (mimarinin temel varsayımı budur).

- [ ] **Step 4: S3 — bundle'dan `screencapture`, iptal ve başarı**

Run: `open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=capture` → ekranda seçim imleci çıkınca **Esc** bas → `cat /tmp/shotcue-spike-capture.txt`
Expected: ilk çalıştırmada macOS "Shotcue ekranınızı kaydetmek istiyor" izin diyaloğunu gösterir; izin verildikten sonra tekrar çalıştır. İptalde `exit=1` ve boş `stderr`. Bir kez daha çalıştırıp bölge seçince `exit=0` ve `/tmp/shotcue-spike-capture.png` oluşur (`file /tmp/shotcue-spike-capture.png` → PNG).

- [ ] **Step 5: S2 — izin rebuild sonrası korunuyor mu**

Run: `touch Sources/ShotcueApp/ShotcueApp.swift && make install && open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=capture` → bölge seç → `cat /tmp/shotcue-spike-capture.txt`
Expected: **yeni izin diyaloğu çıkmaz**, `exit=0`. Diyalog tekrar çıkarsa imza ad-hoc kalmıştır: `codesign -dv ~/Applications/Shotcue.app 2>&1 | grep -E "Authority|flags"` çıktısında `Authority=Shotcue Dev` görünmeli; görünmüyorsa Step 1 tekrarlanır.

- [ ] **Step 6: S5 — Claude Desktop deep link görsel ekliyor mu**

Run: `open "claude://code/new?q=Test%20from%20Shotcue&folder=/tmp&file=/tmp/shotcue-spike-capture.png"` ve ardından `open "claude://cowork/new?q=Test%20from%20Shotcue&file=/tmp/shotcue-spike-capture.png"`
Expected: Claude Desktop açılır, composer'a metin dolar; hangi rotada görselin gerçekten eklendiği gözlemlenip not edilir. Plan 04 `HandoffService.openDesktopComposer` bu sonuca göre `code/new` veya `cowork/new` kullanır (varsayılan `code/new`; görsel eklenmiyorsa `cowork/new`).

- [ ] **Step 7: Sonuçları yaz ve commit'le**

`docs/superpowers/plans/spike-results.md` içine tarih, S1/S2/S3/S5 için gözlemlenen çıktı satırlarını (loggedIn, exit kodları, diyalog davranışı, deep link gözlemi) ve kararları yaz.

```bash
git add Sources/ShotcueApp/ShotcueApp.swift docs/superpowers/plans/spike-results.md
git commit -m "chore: add spike diagnostics and record spike results

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Plan 00 tamamlanma ölçütü

- `make test` → ShotcueCoreTests'te 56 test (smoke dahil) ve diğer beş test target'ında birer smoke test yeşil.
- `make run` → menü çubuğunda Shotcue ikonu; `codesign -dv` → `Authority=Shotcue Dev`.
- `spike-results.md` → S1 `loggedIn: true`, S2 izin korunuyor, S3 iptal `exit=1`, S5 kararı yazılı.
- Bundan sonra Plan 01–04 paralel başlayabilir; Plan 05 onların bitmesini bekler.
