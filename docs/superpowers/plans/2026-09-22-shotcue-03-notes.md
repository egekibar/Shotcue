# Shotcue v1 — Plan 03: Notes (ses kaydı + transkripsiyon)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ShotcueNotes` modülünü kurmak: mikrofondan AAC-LC `.m4a` arşivi yazan ve RMS seviye akıtan `AVAudioEngine` kaydedicisi, giriş cihazı listesi, WhisperKit 1.1 üzerinde Türkçe/İngilizce dosya transkripsiyonu ve `pending` sesli notları arka planda sırayla işleyen kuyruk — hepsi `ShotcueCore` protokollerinin arkasında, mikrofonsuz çalışan testlerle.

**Architecture:** Dört katman. (1) Saf DSP/dosya yardımcıları (`LevelMeter`, `AACWriter`) — sentetik buffer'larla test edilir, donanım gerektirmez. (2) `EngineAudioRecorder` aktörü: bus 0'a **tek** `installTap`, blok içinde hem AAC yazımı hem RMS ölçümü; `AVAudioEngineConfigurationChange` geldiğinde tap'i söküp formatı yeniden okuyup yeniden kurar ve `engine.start()`'ı tekrar çağırır. (3) `WhisperKitTranscriber` aktörü: mantığı `WhisperEngine` adlı küçük bir iç protokolün arkasında tutar, böylece 1.6 GB model olmadan test edilir; gerçek adaptör `WhisperKitEngine` yalnızca manuel spike'ta çalışır. (4) `TranscriptionCoordinator` aktörü: `TaskRepository` üzerinden `pending` notları bulur, sırayla transkribe eder, sonucu + JSON'u yazar, gerekirse başlığı doldurur.

**Tech Stack:** Swift 6.4 (CLT 27.0, SDK 27.0), SwiftPM, Swift Testing, macOS 26.0. `AVFoundation` (AVAudioEngine, AVAudioFile, AVAudioConverter, AVCaptureDevice), `CoreAudio` (AudioUnitSetProperty, kAudioHardwarePropertyTranslateUIDToDevice), `Accelerate` (vDSP_rmsqv), `WhisperKit` 1.1.0 (`argmax-oss-swift`), `FoundationModels` (yalnızca availability okuma; `@Generable` CLT'de derlenmiyor — Task 7).

**Spec:** `docs/superpowers/specs/2026-09-22-shotcue-design.md` — §5.2 (sesli not akışı), §6.2 (Notes bileşeni), §8 (transkripsiyon hataları), §12 S4 (WhisperKit Türkçe spike'ı). Araştırma: `docs/research/03-voice-notes-and-on-device-ai.md` (tamamı).

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

## Bu plana özel kurallar

- **Bu plan yalnızca `Sources/ShotcueNotes/**` ve `Tests/ShotcueNotesTests/**` dosyalarını oluşturur/değiştirir.** `Package.swift`, `ShotcueCore`, `ShotcueTestSupport` ve diğer modüller Plan 00'ın ürünüdür ve **dokunulmaz**. Plan 00 Task 0'daki `ShotcueNotes` target'ı zaten `ShotcueCore` + `.product(name: "WhisperKit", package: "argmax-oss-swift")` bağımlılıklarıyla tanımlı.
- İzin verilen import'lar: `Foundation`, `AVFoundation`, `CoreAudio`, `Accelerate`, `WhisperKit`, `ShotcueCore` ve (yalnızca Task 7) `#if canImport(FoundationModels)` arkasında `FoundationModels`. AppKit/SwiftUI/GRDB/Speech **yok**.
- **`SFSpeechRecognizer`, `AVAudioSession`, `SpeechTranscriber.supportedLocale(equivalentTo:)` asla kullanılmaz** (araştırma 03 §2–§3: ilki dosyadan transkripsiyonda macOS 26'da hiç başlamıyor, ikincisi iOS'a özel ve macOS'ta yok, üçüncüsü Türkçe için yalan söylüyor). `#Preview` yok.
- **Her test dosyasına `import Testing` yazılır** — yardımcı dosyalar (`TestPaths.swift`, `AudioFixtures.swift`) dahil (hijyen; gerekçe aşağıda "Doğrulanmış toolchain tuzakları" #1).
- **`swift test` `plugin for module 'TestingMacros' not found` derse kaynağı DEĞİŞTİRME, komutu tekrar çalıştır.** Bu toolchain'in kararsız bir makro-eklenti hatası; ölçümler aşağıda tuzak #1'de. Bu plandaki her `Run: swift test …` adımı bu kurala tabidir.
- Sesli not testlerinde **mikrofon kullanılmaz**; her şey sentetik `AVAudioPCMBuffer` ile sürülür. Gerçek mikrofon ve gerçek WhisperKit modeli yalnızca Task 1 ve Task 3'ün manuel kontrol listelerinde çalışır.

## Doğrulanmış API'ler (bu makinede derlendi, 2026-09-22)

Aşağıdaki imzalar `scratchpad/spike-notes/` altındaki bir SwiftPM paketinde (`.defaultIsolation(nil)` + `NonisolatedNonsendingByDefault` + `InferIsolatedConformances`, WhisperKit 1.1.0) **derlenerek** ve büyük kısmı **çalıştırılarak** doğrulandı. Planda yalnızca bunlar kullanılır; tahmin yok.

**WhisperKit 1.1.0** (`.build/checkouts/argmax-oss-swift/Sources/WhisperKit/`):

| Sembol | İmza |
|---|---|
| `WhisperKitConfig` | `init(model:downloadBase:modelRepo:modelToken:modelEndpoint:modelFolder:tokenizerFolder:computeOptions:audioInputConfig:audioProcessor:featureExtractor:audioEncoder:textDecoder:logitsFilters:segmentSeeker:voiceActivityDetector:verbose:logLevel:prewarm:load:download:useBackgroundDownloadSession:)` |
| `WhisperKit` | `open class`, `init(_ config: WhisperKitConfig = WhisperKitConfig()) async throws` |
| `WhisperKit.download` | `static func download(variant: String, downloadBase: URL? = nil, useBackgroundSession: Bool = false, from repo: String = "argmaxinc/whisperkit-coreml", token: String? = nil, endpoint: String = Constants.defaultRemoteEndpoint, progressCallback: ProgressCallback? = nil) async throws -> URL` |
| `ProgressCallback` | `typealias ProgressCallback = @Sendable (Progress) -> Void` (`Foundation.Progress`, `fractionCompleted`) |
| `WhisperKit.transcribe` | `open func transcribe(audioPath: String, audioInputOptions: AudioInputOptions? = nil, decodeOptions: DecodingOptions? = nil, callback: TranscriptionCallback? = nil) async throws -> [TranscriptionResult]` |
| `DecodingOptions` | `init(verbose:task:language:temperature:temperatureIncrementOnFallback:temperatureFallbackCount:sampleLength:topK:usePrefillPrompt:detectLanguage:skipSpecialTokens:withoutTimestamps:wordTimestamps:maxInitialTimestamp:maxWindowSeek:clipTimestamps:windowClipTime:promptTokens:prefixTokens:suppressBlank:suppressTokens:compressionRatioThreshold:logProbThreshold:firstTokenLogProbThreshold:noSpeechThreshold:concurrentWorkerCount:chunkingStrategy:)` |
| `DecodingTask` / `ChunkingStrategy` | `.transcribe` / `.vad` |
| `TranscriptionResult` | `open class`, `var text: String`, `var segments: [TranscriptionSegment]`, `var language: String`, `var timings: TranscriptionTimings` |
| `TranscriptionSegment` | `start: Float`, `end: Float`, `text: String`, `avgLogprob: Float`, `noSpeechProb: Float`, `words: [WordTiming]?` |
| `WhisperKit.recommendedModels()` | `static func recommendedModels() -> ModelSupport`; `ModelSupport.default: String`, `.supported: [String]` |
| `Constants.defaultRemoteEndpoint` | `"https://huggingface.co"` |

Çalıştırma sonucu (bu makine, Apple Silicon): `recommendedModels().default == "openai_whisper-large-v3-v20240930"`, `supported` 22 model içeriyor ve **`openai_whisper-large-v3-v20240930_turbo` ile `openai_whisper-large-v3-v20240930_turbo_632MB` ikisi de listede** (spec §6.2 doğrulandı). Model klasörü yerleşimi `downloadBase/models/argmaxinc/whisperkit-coreml/<variant>` (HubApi `localRepoLocation` = `downloadBase/<repoType>/<repoId>`).

**AVFoundation / CoreAudio / Accelerate:**

| Sembol | Not |
|---|---|
| `AVAudioFile(forWriting:settings:)` | 2 argümanlı form yeterli; `processingFormat` = 48 kHz, 1 kanal, `pcmFormatFloat32` (ölçüldü) |
| AAC ayarları | `AVFormatIDKey: kAudioFormatMPEG4AAC`, `AVSampleRateKey: 48000.0`, `AVNumberOfChannelsKey: 1`, `AVEncoderBitRateKey: 64000` → 1 sn dosya 65 644 bayt |
| `AVAudioConverter(from:to:)` + `convert(to:error:withInputFrom:)` | Blok formu; `AVAudioConverterInputStatus.haveData` / `.noDataNow` / `.endOfStream`, dönüş `AVAudioConverterOutputStatus` (`.error` kontrol edilir) |
| `AVAudioEngine.inputNode.installTap(onBus:bufferSize:format:block:)` | Blok `@Sendable` değil; aktörden paylaşılan yazıcı kilitli referansla taşınır |
| `NSNotification.Name.AVAudioEngineConfigurationChange` | **`AVAudioEngineConfigurationChangeNotification` Swift 3'te obsolete edildi, derleme hatası veriyor** — `.AVAudioEngineConfigurationChange` kullanılır |
| `AVCaptureDevice.DiscoverySession(deviceTypes:mediaType:position:)` | `[.microphone, .external]`, `.audio`, `.unspecified` → `.devices`; bu makinede 2 cihaz (`BuiltInMicrophoneDevice`, iPhone mikrofonu) |
| `kAudioHardwarePropertyTranslateUIDToDevice` | `AudioObjectGetPropertyData(kAudioObjectSystemObject, …, CFString boyutu, &cfUID, &size, &deviceID)`; bilinmeyen UID → `kAudioObjectUnknown` |
| `kAudioOutputUnitProperty_CurrentDevice` | `AudioUnitSetProperty(inputNode.audioUnit!, …, kAudioUnitScope_Global, 0, &deviceID, …)`, `engine.start()`'tan **önce** |
| `vDSP_rmsqv` | `Accelerate`; tam ölçek sinüs → `0.70710677`, sessizlik → `0.0` (ölçüldü) |
| `AVAudioFormat(streamDescription:)` | 0 Hz / 0 kanal ASBD ile **nil dönmüyor**, geçerli bir format üretiyor → `isUsable(format:)` guard'ı şart |

**FoundationModels:** `import FoundationModels`, `SystemLanguageModel.default.availability` (`.available` / `.unavailable(.appleIntelligenceNotEnabled|.deviceNotEligible|.modelNotReady)`), `SystemLanguageModel.default.supportedLanguages` (`Locale.Language`, `maximalIdentifier`) ve `LanguageModelSession(instructions:)` + `respond(to:)` **derleniyor**. Bu makinede `availability == .unavailable(.appleIntelligenceNotEnabled)`, `supportedLanguages` 23 dil ve `tr-Latn-TR` listede (araştırma 03 §6 doğrulandı). **`@Generable` / `@Guide` derlenMİYOR** — Task 7.

### Doğrulanmış toolchain tuzakları

1. **`swift test` bu toolchain'de KARARSIZ bir şekilde `plugin for module 'TestingMacros' not found` hatası verir. Bu bir kod hatası değildir; komutu tekrar çalıştırın.** Hata şöyle görünür ve rastgele test dosyalarına dağılır:

   ```
   Tests/ShotcueNotesTests/FoundationModelsStatusTests.swift:6:8: error: external macro implementation
   type 'TestingMacros.SuiteDeclarationMacro' could not be found for macro 'Suite';
   plugin for module 'TestingMacros' not found
   ```

   Bu makinede **aynı kaynaklarla** ölçülen ardışık `swift test` çalıştırmaları (test target'ı her seferinde soğuk):

   | Çalıştırma | `-j 1` | Varsayılan paralellik |
   |---|---|---|
   | 1 | 0 hata, 36 test geçti | 20 hata |
   | 2 | 0 hata, 36 test geçti | 0 hata, 36 test geçti |
   | 3 | 28 hata | 107 hata |

   Sebep `swift-plugin-server`'ın paralel `swift-frontend` işleri altında bağlanamaması; `-j 1` oranı düşürüyor ama **tamamen engellemiyor**. Eklenti kuruludur (`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`), kaynak kodda sorun yoktur. **Kural: bu hatayı görürsen kaynağı değiştirmeden `swift test`'i tekrar çalıştır** (gerekirse `swift test -j 1`); iki üç denemede geçer. Hijyen olarak test target'ındaki her dosyaya (yardımcılar dahil) `import Testing` yazılır — bir deneyde ısrarcı görünen bir hatayı temizledi ve zararı yok.
2. **`AACWriter.finish()` dosyayı kapatmak zorunda.** `AVAudioFile` serbest bırakılmadan `.m4a` okunamıyor: `AVAudioFile(forReading:)` → `OSStatus 1685348671` (`'dta?'`, `kAudioFileInvalidFileError`). Ölçüldü.
3. **Dönüştürücünün kuyruğu boşaltılmalı.** Her tap buffer'ı için `.noDataNow` döndürülür; `finish()`'te bir kez `.endOfStream` ile boşaltılmazsa 1 sn'lik kayıt 0.928 sn olarak yazılıyor (~72 ms yeniden örnekleme gecikmesi kayboluyor). Ölçüldü.
4. **Aktörün `let`'i modül dışından okunamaz.** `Transcriber.engineName` protokol gereksinimi ve testler `ShotcueNotes` dışından okuduğu için `public nonisolated let engineName` yazılır; düz `public let` "actor-isolated property cannot be accessed from outside of the actor" hatası verir. Ölçüldü.
5. **`@Sendable` bir closure içinde `var` yakalanamaz.** `WhisperKit.download(progressCallback:)` `@Sendable (Progress) -> Void` alır; Task 1'in CLI'sinde ilerleme durumu bu yüzden kilitli bir referans kutusunda tutulur (`ProgressBucket`). Düz `var lastBucket` → "reference to captured var … in concurrently-executing code". Ölçüldü.

## Dosya haritası

```
Sources/ShotcueNotes/
  LevelMeter.swift              LevelMeter.rms(_:) -> Float (0…1, vDSP)
  AACWriter.swift               AACWriter (AAC-LC 48 kHz mono 64 kbps + AVAudioConverter)
  EngineAudioRecorder.swift     EngineAudioRecorder: AudioRecorder (tek tap, config-change kurtarma)
  AudioDeviceCatalog.swift      AudioDeviceCatalog.inputDevices() / deviceID(forUID:)
  WhisperEngine.swift           WhisperSegment, WhisperEngine protokolü, WhisperKitEngine adaptörü
  WhisperKitTranscriber.swift   WhisperKitTranscriber: Transcriber
  TranscriptionCoordinator.swift TranscriptionCoordinator: TranscriptionQueue
  FoundationModelsStatus.swift  FoundationModelsStatus (yalnızca availability; Task 7)

Tests/ShotcueNotesTests/
  TestPaths.swift                   Plan 00'dan kopya + `import Testing`
  AudioFixtures.swift               sentetik sinüs/sessizlik buffer'ları, geçici URL
  LevelMeterTests.swift             @Suite("LevelMeter")              4 test
  AACWriterTests.swift              @Suite("AACWriter")               4 test
  EngineAudioRecorderTests.swift    @Suite("EngineAudioRecorder")     4 test
  AudioDeviceCatalogTests.swift     @Suite("AudioDeviceCatalog")      3 test
  WhisperKitTranscriberTests.swift  @Suite("WhisperKitTranscriber")   7 test
  TranscriptionCoordinatorTests.swift @Suite("TranscriptionCoordinator") 11 test
  FoundationModelsStatusTests.swift @Suite("FoundationModelsStatus")   3 test

docs/superpowers/plans/spike-results.md   S4 bölümü (Task 1)
```

Plan 00'dan tüketilen (değiştirilmeyen) arayüzler: `AudioRecorder`, `RecordingInfo`, `Transcriber`, `TranscriberModelState`, `TranscriptionQueue`, `TaskRepository`, `FileStore`, `TitleMaker`, `VoiceNote`, `Transcript`, `TranscriptState`, `ShotTask`; test tarafında `ShotcueTestSupport`'tan `Locked`, `FakeError`, `FakeTranscriber`, `InMemoryTaskRepository`.

---

### Task 1: S4 spike — WhisperKit Türkçe kalite/hız ölçümü (manuel, ilk iş)

Spec §12 S4: "5 gerçek not, teknik terimler korunuyor, 30 sn not < 5 sn". Araştırma 03'ün son sözü: quantize edilmiş WhisperKit build'lerinin Türkçe WER'i **kimse tarafından yayınlanmamış**, yani 1.64 GB ile 632 MB arasında seçim yapmanın tek dürüst yolu kendi sesinizle ölçmek. Bu task kod üretmez, **karar üretir**: Task 5'in varsayılan model adı buradan çıkar.

**Files:**
- Create: `docs/superpowers/plans/spike-results.md` içinde `## S4 — WhisperKit Türkçe` bölümü (dosya Plan 00 Task 11'de oluşturuldu; yoksa oluştur)
- Create (repo DIŞINDA, scratchpad): `<scratchpad>/spike-notes/` SwiftPM paketi

**Interfaces:**
- Produces: `spike-results.md` içinde S4 tablosu ve tek satır karar cümlesi ("Varsayılan model: …"). Task 5 bu cümleyi okur.
- Consumes: hiçbir şey (Plan 00 bitmiş olmalı; `swift build` çalışıyor olmalı).

- [ ] **Step 1: Kullanıcıdan 5 gerçek Türkçe görev notu iste**

Kullanıcıya aynen şunu söyle ve bekle:

> Ses kayıtlarını senin yapman gerekiyor (sentetik `say` sesi bu ölçümü yanıltır — araştırma 03'te ölçülen bozulmalar temiz sentetik sesle alındı, gerçek mikrofon daha kötüdür).
>
> **QuickTime Player → Dosya → Yeni Ses Kaydı** (veya Voice Memos) ile **5 ayrı kayıt** yap, her biri **20–30 saniye**, normal konuşma hızında, kendi çalışma masanda (arka plan gürültüsü gerçekçi olsun). Her notta Türkçe cümle içinde en az 3 İngilizce teknik terim geçsin. Örnek konular:
> 1. "Login ekranındaki **modal** açıldığında **API endpoint**'ten gelen hata mesajı görünmüyor, önce **cache**'i temizleyip tekrar **deploy** etmeyi dene."
> 2. "Dashboard'daki **dropdown** **mobile** görünümde bozuluyor, **responsive** düzeltme lazım ve **state** yönetimini **refactor** etmemiz gerekiyor."
> 3. "**Migration** dosyasında **foreign key** eksik, **rollback** edip yeniden yaz; sonra **queue worker**'ı **restart** et."
> 4. "Ödeme sayfasındaki **webhook** **timeout** veriyor, **retry** mantığını **exponential backoff** ile değiştir."
> 5. Kendi gerçek bir işin — ne söylersen söyle, yeter ki içinde İngilizce terimler geçsin.
>
> Kayıtları `.m4a` veya `.wav` olarak şu klasöre koy ve bana yolu söyle: `~/Desktop/shotcue-s4/` (`note1.m4a` … `note5.m4a`). Her kaydın **gerçekte ne söylediğini** de bir metin dosyasına yaz (`~/Desktop/shotcue-s4/ground-truth.txt`, her satır bir not) — kalite karşılaştırması buna göre yapılacak.

Expected: kullanıcı 5 dosya + `ground-truth.txt` hazır olduğunu bildirir. Dosya sayısı 5'ten azsa devam et ama `spike-results.md`'de kaç notla ölçüldüğünü yaz.

- [ ] **Step 2: Scratchpad'de spike paketini kur**

Repo'ya hiçbir şey yazılmaz. Scratchpad dizinini `$SCRATCH` olarak alıp:

```bash
mkdir -p "$SCRATCH/spike-s4/Sources/SpikeCLI"
cat > "$SCRATCH/spike-s4/Package.swift" <<'EOF'
// swift-tools-version: 6.4
import PackageDescription

let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "SpikeS4",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpikeCLI",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            swiftSettings: [.defaultIsolation(nil)] + upcoming),
    ],
    swiftLanguageModes: [.v6]
)
EOF
```

- [ ] **Step 3: Spike CLI'yi yaz**

`$SCRATCH/spike-s4/Sources/SpikeCLI/main.swift`:

```swift
import Foundation
import WhisperKit

// S4: compares two WhisperKit variants on real Turkish task notes.
// Usage: SpikeCLI <models-dir> <audio1> [audio2 ...]

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: SpikeCLI <models-dir> <audio1> [audio2 ...]")
    exit(2)
}
let modelsDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
let audioFiles = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
let variants = [
    "openai_whisper-large-v3-v20240930_turbo",
    "openai_whisper-large-v3-v20240930_turbo_632MB",
]
let repo = "argmaxinc/whisperkit-coreml"

/// `ProgressCallback` is `@Sendable`, so a plain `var` cannot be captured and mutated there.
final class ProgressBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    /// True when the 10% bucket changed since the last call.
    func advanced(to bucket: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bucket != value else { return false }
        value = bucket
        return true
    }
}

func modelFolder(_ variant: String) -> URL {
    modelsDirectory
        .appendingPathComponent("models", isDirectory: true)
        .appendingPathComponent(repo, isDirectory: true)
        .appendingPathComponent(variant, isDirectory: true)
}

let support = WhisperKit.recommendedModels()
print("device default: \(support.default)")
for variant in variants {
    print("\(variant) supported: \(support.supported.contains(variant))")
}

for variant in variants {
    print("\n=================== \(variant) ===================")
    if FileManager.default.fileExists(atPath: modelFolder(variant).path) == false {
        print("downloading (1.6 GB / 632 MB)…")
        let start = Date()
        let bucket = ProgressBucket()
        _ = try await WhisperKit.download(variant: variant, downloadBase: modelsDirectory,
                                          useBackgroundSession: false, from: repo) { progress in
            if bucket.advanced(to: Int(progress.fractionCompleted * 10)) {
                print(String(format: "  %.0f%%", progress.fractionCompleted * 100))
            }
        }
        print(String(format: "download %.1f s", Date().timeIntervalSince(start)))
    }

    let loadStart = Date()
    let config = WhisperKitConfig(model: variant, downloadBase: modelsDirectory, modelRepo: repo,
                                  verbose: false, logLevel: .error, prewarm: false, load: true,
                                  download: false)
    let kit = try await WhisperKit(config)
    print(String(format: "load %.1f s (state: %@)", Date().timeIntervalSince(loadStart),
                 kit.modelState.description))

    for audio in audioFiles {
        let options = DecodingOptions(verbose: false, task: .transcribe, language: "tr",
                                      temperature: 0, temperatureFallbackCount: 3,
                                      usePrefillPrompt: true, detectLanguage: false,
                                      skipSpecialTokens: true, withoutTimestamps: false,
                                      wordTimestamps: false, chunkingStrategy: .vad)
        let start = Date()
        let results = try await kit.transcribe(audioPath: audio.path, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments)
        let audioSeconds = Double(segments.last?.end ?? 0)
        print("\n--- \(audio.lastPathComponent) ---")
        print(String(format: "audio %.1f s · transcribe %.2f s · %.1fx realtime",
                     audioSeconds, elapsed, elapsed > 0 ? audioSeconds / elapsed : 0))
        print("detected language: \(results.first?.language ?? "?")")
        print(text)
        for segment in segments {
            print(String(format: "  [%.2f–%.2f] conf=%.2f %@", Double(segment.start),
                         Double(segment.end), exp(Double(segment.avgLogprob)),
                         segment.text.trimmingCharacters(in: .whitespaces)))
        }
    }
}
```

- [ ] **Step 4: Derle**

Run: `cd "$SCRATCH/spike-s4" && swift build 2>&1 | tail -3`
Expected: `Build complete!` (ilk çözümleme WhisperKit yüzünden 1–2 dakika). `ld: warning: search path … not found` uyarıları zararsız. Derleme hatası olursa Plan 00'ın bağımlılık pinini kontrol et ve devam etmeden raporla.

- [ ] **Step 5: İki modeli de ölç**

Run: `cd "$SCRATCH/spike-s4" && ./.build/debug/SpikeCLI "$SCRATCH/s4-models" ~/Desktop/shotcue-s4/note*.m4a 2>&1 | tee "$SCRATCH/s4-output.txt"`
Expected: iki model için de `device default`/`supported: true` satırları, indirme yüzdeleri, `load … s`, ve her not için `audio … s · transcribe … s · …x realtime` + transkript + segment satırları. İlk indirme ~1.6 GB + ~632 MB; ağ yavaşsa uzun sürer, bu normaldir. `modelsUnavailable` hatası alırsan model adını `recommendedModels().supported` çıktısıyla karşılaştır.

- [ ] **Step 6: Sonuçları `spike-results.md`'ye yaz**

`docs/superpowers/plans/spike-results.md` sonuna aşağıdaki bölümü ekle ve **gerçek ölçümlerle doldur** (boş hücre bırakma; ölçülemeyen bir şey varsa "ölçülemedi: <sebep>" yaz):

```markdown
## S4 — WhisperKit Türkçe kalite/hız (Plan 03 Task 1)

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

Her not için tam transkriptler: `<scratchpad>/s4-output.txt` (özeti aşağıda)

1. note1: turbo → "…" · 632MB → "…"
2. note2: …
3. note3: …
4. note4: …
5. note5: …

### Başarı ölçütü kontrolü (spec §12)

- Teknik terimler korunuyor mu? turbo: <evet/kısmen/hayır> · 632MB: <evet/kısmen/hayır>
- 30 sn not < 5 sn mi? turbo: <ölçüm> · 632MB: <ölçüm>

### KARAR

Varsayılan model: `<openai_whisper-large-v3-v20240930_turbo | openai_whisper-large-v3-v20240930_turbo_632MB>`
Gerekçe: <bir cümle>
```

Karar kuralı: **632MB varyantı teknik terimlerde turbo ile eşitse ve hız ölçütünü geçiyorsa** onu varsayılan yap (1 GB disk tasarrufu); aksi halde varsayılan `openai_whisper-large-v3-v20240930_turbo` kalır. Her iki modelde de teknik terimler bozuluyorsa **durma noktası**: kullanıcıya rapor et, Task 5'e geçmeden spec §6.2'nin "tek motor" kararı gözden geçirilmeli (araştırma 03 §5'teki AssemblyAI fallback'i v1'e alınabilir).

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/plans/spike-results.md
git commit -m "docs: record S4 WhisperKit Turkish quality spike results

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: LevelMeter ve AACWriter (sentetik buffer'larla test)

Kayıt zincirinin donanımsız kısmı. Spec §5.2: ses `audio/<uuid>.m4a` olarak **AAC-LC, 48 kHz mono, 64 kbps** yazılır; panelde seviye çubuğu gösterilir. Araştırma 03 §1: 48 kHz'i koru (arşivi ileride farklı ASR modelleriyle tekrar işleyeceğiz), 16 kHz'e indirme.

**Files:**
- Create: `Tests/ShotcueNotesTests/TestPaths.swift`, `Tests/ShotcueNotesTests/AudioFixtures.swift`
- Create: `Tests/ShotcueNotesTests/LevelMeterTests.swift`, `Tests/ShotcueNotesTests/AACWriterTests.swift`
- Create: `Sources/ShotcueNotes/LevelMeter.swift`, `Sources/ShotcueNotes/AACWriter.swift`
- Delete: `Sources/ShotcueNotes/ShotcueNotes.swift` (Plan 00 yer tutucusu) ve `Tests/ShotcueNotesTests/SmokeTests.swift` — yerine gerçek testler geliyor

**Interfaces:**
- Consumes: yok (saf AVFoundation).
- Produces:
  - `public enum LevelMeter { public static func rms(_ buffer: AVAudioPCMBuffer) -> Float }` — 0…1
  - `public struct AACWriter: Sendable` — `public init(url: URL, inputFormat: AVAudioFormat) throws`, `public func write(_ buffer: AVAudioPCMBuffer) throws`, `public func finish() -> (duration: TimeInterval, frames: AVAudioFramePosition)`, `public static func settings() -> [String: Any]`, `public static func targetFormat() -> AVAudioFormat?`, `public static let sampleRate: Double`, `public static let channelCount: AVAudioChannelCount`, `public static let bitRate: Int`, `public enum Failure: Error, Equatable { case unsupportedTargetFormat, converterUnavailable, bufferAllocationFailed, conversionFailed }`
  - Test yardımcıları: `AudioFixtures.sine(sampleRate:channels:seconds:frequency:amplitude:)`, `AudioFixtures.silence(sampleRate:channels:seconds:)`, `AudioFixtures.temporaryURL(extension:)`, `TestPaths.fixtures` / `TestPaths.fixture(_:)`

- [ ] **Step 1: Test altyapı dosyalarını yaz**

`Tests/ShotcueNotesTests/TestPaths.swift` — Plan 00'daki dosyanın birebir kopyası, **`import Testing` satırı eklenmiş** (bu plana özel kurallar #1: import'suz bir dosya tüm test target'ının makro genişletmesini kırıyor):

```swift
import Testing
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

`Tests/ShotcueNotesTests/AudioFixtures.swift`:

```swift
import Testing
import AVFoundation
import Foundation

/// Synthetic audio so the tests never need a microphone.
enum AudioFixtures {
    static func sine(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double,
                     frequency: Double = 440, amplitude: Float = 1.0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            }
        }
        return buffer
    }

    static func silence(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
                        seconds: Double = 0.1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { data[channel][frame] = 0 }
        }
        return buffer
    }

    static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-notes-\(UUID().uuidString).\(ext)")
    }
}
```

- [ ] **Step 2: Başarısız LevelMeter testini yaz**

`Tests/ShotcueNotesTests/LevelMeterTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import ShotcueNotes

@Suite("LevelMeter")
struct LevelMeterTests {
    @Test func silenceReadsZero() {
        #expect(LevelMeter.rms(AudioFixtures.silence()) == 0)
    }

    @Test func fullScaleSineReadsAboutSevenOhSeven() {
        let level = LevelMeter.rms(AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.1))
        #expect(abs(level - 0.7071) < 0.01)
    }

    @Test func levelIsClampedToUnitRange() {
        let loud = AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.05, amplitude: 8)
        let level = LevelMeter.rms(loud)
        #expect(level == 1)
    }

    @Test func emptyBufferReadsZero() {
        let buffer = AudioFixtures.silence()
        buffer.frameLength = 0
        #expect(LevelMeter.rms(buffer) == 0)
    }
}
```

- [ ] **Step 3: Testin derlenmediğini gör**

Run: `make test FILTER=LevelMeter 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'LevelMeter' in scope`.

- [ ] **Step 4: LevelMeter'ı yaz**

`Sources/ShotcueNotes/LevelMeter.swift`:

```swift
import AVFoundation
import Accelerate
import Foundation

/// Root-mean-square level of a PCM buffer, normalised to 0…1 for the recording level bar.
/// A full-scale sine reads ~0.707; digital silence reads 0.
public enum LevelMeter {
    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = vDSP_Length(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            var value: Float = 0
            vDSP_rmsqv(channels[channel], 1, &value, frames)
            sum += value
        }
        let mean = sum / Float(max(1, channelCount))
        guard mean.isFinite else { return 0 }
        return min(1, max(0, mean))
    }
}
```

- [ ] **Step 5: LevelMeter testlerinin geçtiğini gör**

Run: `make test FILTER=LevelMeter 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 6: Başarısız AACWriter testini yaz**

`Tests/ShotcueNotesTests/AACWriterTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import ShotcueNotes

@Suite("AACWriter")
struct AACWriterTests {
    @Test func settingsMatchTheArchiveFormat() {
        let settings = AACWriter.settings()
        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(settings[AVSampleRateKey] as? Double == 48_000)
        #expect(settings[AVNumberOfChannelsKey] as? AVAudioChannelCount == 1)
        #expect(settings[AVEncoderBitRateKey] as? Int == 64_000)
    }

    @Test func convertsStereo44kToMono48kAAC() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let input = AudioFixtures.sine(sampleRate: 44_100, channels: 2, seconds: 1.0)
        let writer = try AACWriter(url: url, inputFormat: input.format)
        try writer.write(input)
        let finished = writer.finish()

        #expect(abs(finished.duration - 1.0) < 0.05)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.fileFormat.sampleRate == 48_000)
        #expect(readBack.fileFormat.channelCount == 1)
        #expect(abs(Double(readBack.length) / readBack.fileFormat.sampleRate - 1.0) < 0.05)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func passesThroughWhenInputIsAlready48kMono() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let input = AudioFixtures.sine(sampleRate: 48_000, channels: 1, seconds: 0.5)
        let writer = try AACWriter(url: url, inputFormat: input.format)
        try writer.write(input)
        let finished = writer.finish()
        #expect(finished.frames == 24_000)
        #expect(abs(finished.duration - 0.5) < 0.01)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func manyTapSizedBuffersAccumulate() throws {
        let url = AudioFixtures.temporaryURL(extension: "m4a")
        let chunk = AudioFixtures.sine(sampleRate: 44_100, channels: 1, seconds: 4096.0 / 44_100.0)
        let writer = try AACWriter(url: url, inputFormat: chunk.format)
        for _ in 0..<10 { try writer.write(chunk) }
        let finished = writer.finish()
        let expected = 10 * 4096.0 / 44_100.0
        #expect(abs(finished.duration - expected) < 0.05)
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 7: Testin derlenmediğini gör**

Run: `make test FILTER=AACWriter 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'AACWriter' in scope`.

- [ ] **Step 8: AACWriter'ı yaz**

`Sources/ShotcueNotes/AACWriter.swift`:

```swift
import AVFoundation
import Foundation

/// Writes AAC-LC `.m4a` (48 kHz mono, 64 kbps) from arbitrary input buffers (spec §5.2).
/// `AVAudioConverter` absorbs the microphone's sample-rate/channel mismatch.
///
/// The methods are non-mutating on purpose: the recorder's tap block runs on a realtime audio
/// thread and shares one writer with the actor that calls `finish()`, so the state lives in a
/// locked reference box instead of in the struct.
public struct AACWriter: Sendable {
    /// Archive format from spec §5.2 / research 03 §1 ("Arşiv: AAC-LC .m4a, mono, 48 kHz, 64 kbps").
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 1
    public static let bitRate = 64_000

    public static func settings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// 48 kHz mono float32 — what the converter targets and `AVAudioFile.write(from:)` accepts.
    public static func targetFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                      channels: channelCount, interleaved: false)
    }

    public enum Failure: Error, Equatable {
        case unsupportedTargetFormat
        case converterUnavailable
        case bufferAllocationFailed
        case conversionFailed
    }

    private let storage: Storage

    public init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let target = Self.targetFormat() else { throw Failure.unsupportedTargetFormat }
        let file = try AVAudioFile(forWriting: url, settings: Self.settings())
        var converter: AVAudioConverter?
        if inputFormat.sampleRate != target.sampleRate || inputFormat.channelCount != target.channelCount
            || inputFormat.commonFormat != target.commonFormat {
            guard let made = AVAudioConverter(from: inputFormat, to: target) else {
                throw Failure.converterUnavailable
            }
            converter = made
        }
        storage = Storage(file: file, target: target, converter: converter)
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        try storage.write(buffer)
    }

    /// Flushes the converter tail and closes the file — an `.m4a` stays unreadable
    /// (`kAudioFileInvalidFileError`, OSStatus 1685348671 = `'dta?'`) until the `AVAudioFile` is released.
    public func finish() -> (duration: TimeInterval, frames: AVAudioFramePosition) {
        storage.finish()
    }

    // MARK: - Locked state

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let target: AVAudioFormat
        private let converter: AVAudioConverter?
        private var file: AVAudioFile?
        private var framesWritten: AVAudioFramePosition = 0

        init(file: AVAudioFile, target: AVAudioFormat, converter: AVAudioConverter?) {
            self.file = file
            self.target = target
            self.converter = converter
        }

        func write(_ buffer: AVAudioPCMBuffer) throws {
            lock.lock()
            defer { lock.unlock() }
            guard let file else { return }
            guard let converter else {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                return
            }
            try pump(converter: converter, file: file, source: buffer, endOfStream: false)
        }

        func finish() -> (duration: TimeInterval, frames: AVAudioFramePosition) {
            lock.lock()
            defer { lock.unlock() }
            if let converter, let file {
                try? pump(converter: converter, file: file, source: nil, endOfStream: true)
            }
            file = nil
            return (TimeInterval(framesWritten) / target.sampleRate, framesWritten)
        }

        /// Block-based conversion: `.noDataNow` keeps the converter alive between tap buffers,
        /// `.endOfStream` drains the ~70 ms of input the resampler still holds.
        private func pump(converter: AVAudioConverter, file: AVAudioFile,
                          source: AVAudioPCMBuffer?, endOfStream: Bool) throws {
            let sourceFrames = source?.frameLength ?? 4096
            let sourceRate = source?.format.sampleRate ?? target.sampleRate
            let capacity = AVAudioFrameCount(Double(sourceFrames) * target.sampleRate / sourceRate) + 4096
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw Failure.bufferAllocationFailed
            }
            var conversionError: NSError?
            var supplied = source == nil
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            if let conversionError { throw conversionError }
            if status == .error { throw Failure.conversionFailed }
            guard output.frameLength > 0 else { return }
            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        }
    }
}
```

- [ ] **Step 9: Plan 00 yer tutucularını sil ve testleri çalıştır**

```bash
rm -f Sources/ShotcueNotes/ShotcueNotes.swift Tests/ShotcueNotesTests/SmokeTests.swift
```

Run: `make test FILTER='LevelMeter|AACWriter' 2>&1 | tail -3`
Expected: `Test run with 8 tests in 2 suites passed`. (Bu makinede ölçülen değerler: sinüs RMS `0.70710677`, 44.1 kHz stereo 1 sn → 48 000 frame / 1.0 sn / 65 644 bayt.)

- [ ] **Step 10: Commit**

```bash
make format && git add -A Sources/ShotcueNotes Tests/ShotcueNotesTests
git commit -m "feat(notes): add RMS level meter and AAC archive writer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: EngineAudioRecorder (tek tap, konfigürasyon değişikliği kurtarması)

Spec §5.2 ve araştırma 03 §1. Üç kritik nokta: (a) **bus başına yalnızca tek tap kurulabilir**, dolayısıyla arşiv yazımı ve seviye ölçümü aynı blokta olur; (b) `AVAudioEngineConfigurationChange` geldiğinde motor kendini **durdurmuş ve deinitialize etmiştir**, bildirim neyin değiştiğini söylemez, callback iç dispatch queue'da gelir (orada motoru serbest bırakmak deadlock) — tap sökülür, format yeniden okunur, tap kurulur ve **`engine.start()` tekrar çağrılır**; (c) cihaz çıkarıldığında format **0 Hz / 0 kanal** dönebilir ve bu formatla tap kurmak çökertir.

Mikrofon gerçek donanım olduğu için otomatik test yalnızca saf parçaları kapsar (`isUsable(format:)`, hata yolları, seviye akışı); gerçek kayıt Step 6'nın manuel kontrol listesindedir.

> **Yürütme sırası:** bu task `AudioDeviceCatalog.deviceID(forUID:)`'i çağırır, yani **Task 4 bu task'tan ÖNCE tamamlanmalıdır.** Sıra: Task 1 → Task 2 → Task 4 → Task 3 → Task 5 → Task 6 → Task 7. (Numaralandırma isim sözleşmesine göredir, bağımlılık sırasına göre değil.)

**Files:**
- Create: `Tests/ShotcueNotesTests/EngineAudioRecorderTests.swift`
- Create: `Sources/ShotcueNotes/EngineAudioRecorder.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10, birebir):
  ```swift
  public struct RecordingInfo: Hashable, Sendable {
      public var fileURL: URL
      public var duration: TimeInterval
      public init(fileURL: URL, duration: TimeInterval)
  }
  public protocol AudioRecorder: Sendable {
      func start(writingTo url: URL) async throws
      func stop() async throws -> RecordingInfo
      var levels: AsyncStream<Float> { get }
  }
  ```
  Task 2'den `AACWriter(url:inputFormat:)` / `AACWriter.write(_:)` / `AACWriter.finish()` ve `LevelMeter.rms(_:)`; Task 4'ten `AudioDeviceCatalog.deviceID(forUID:) -> AudioDeviceID?`.
- Produces:
  ```swift
  public actor EngineAudioRecorder: AudioRecorder {
      public enum Failure: Error, Equatable {
          case unusableInputFormat(sampleRate: Double, channels: UInt32)
          case notRecording
          case alreadyRecording
      }
      public init(inputDeviceUID: String? = nil)
      public static func isUsable(format: AVAudioFormat) -> Bool
      public nonisolated var levels: AsyncStream<Float> { get }
      public func start(writingTo url: URL) async throws
      public func stop() async throws -> RecordingInfo
  }
  ```

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueNotesTests/EngineAudioRecorderTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import ShotcueNotes

@Suite("EngineAudioRecorder")
struct EngineAudioRecorderTests {
    @Test func rejectsZeroHertzFormats() throws {
        // A removed input device makes `inputNode.inputFormat(forBus: 0)` report 0 Hz / 0 channels;
        // installing a tap with that format crashes (research 03 §1).
        var description = AudioStreamBasicDescription(
            mSampleRate: 0, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 0, mBitsPerChannel: 32, mReserved: 0)
        let zero = try #require(AVAudioFormat(streamDescription: &description))
        #expect(EngineAudioRecorder.isUsable(format: zero) == false)
    }

    @Test func acceptsUsableFormats() throws {
        let usable = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                                channels: 2, interleaved: false))
        #expect(EngineAudioRecorder.isUsable(format: usable))
        let mono = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false))
        #expect(EngineAudioRecorder.isUsable(format: mono))
    }

    @Test func stopWithoutStartThrows() async {
        let recorder = EngineAudioRecorder()
        await #expect(throws: EngineAudioRecorder.Failure.notRecording) {
            _ = try await recorder.stop()
        }
    }

    @Test func levelsStreamIsAvailableBeforeRecording() async {
        let recorder = EngineAudioRecorder()
        var iterator = recorder.levels.makeAsyncIterator()
        let task = Task { await iterator.next() }
        task.cancel()
        _ = await task.value
        #expect(Bool(true))
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=EngineAudioRecorder 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'EngineAudioRecorder' in scope`.

- [ ] **Step 3: EngineAudioRecorder'ı yaz**

`Sources/ShotcueNotes/EngineAudioRecorder.swift`:

```swift
import AVFoundation
import CoreAudio
import Foundation
import ShotcueCore

/// `AVAudioEngine` microphone recorder with a single tap on bus 0 (research 03 §1:
/// "Tek bus'a yalnızca tek tap kurulabilir"). The tap both archives AAC and meters RMS.
public actor EngineAudioRecorder: AudioRecorder {
    public enum Failure: Error, Equatable {
        case unusableInputFormat(sampleRate: Double, channels: UInt32)
        case notRecording
        case alreadyRecording
    }

    private let engine = AVAudioEngine()
    private let inputDeviceUID: String?
    private var writer: AACWriter?
    private var destination: URL?
    private var configurationObserver: NSObjectProtocol?

    private let levelStream: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    public nonisolated var levels: AsyncStream<Float> { levelStream }

    public init(inputDeviceUID: String? = nil) {
        self.inputDeviceUID = inputDeviceUID
        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        levelStream = stream
        levelContinuation = continuation
    }

    /// A removed or switching device reports 0 Hz / 0 channels; installing a tap with that format crashes.
    public static func isUsable(format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    public func start(writingTo url: URL) async throws {
        guard writer == nil else { throw Failure.alreadyRecording }
        destination = url
        try applyInputDevice()
        try installTapAndStart(creatingWriterAt: url)
        observeConfigurationChanges()
    }

    public func stop() async throws -> RecordingInfo {
        guard let writer, let destination else { throw Failure.notRecording }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let finished = writer.finish()
        self.writer = nil
        self.destination = nil
        levelContinuation.yield(0)
        return RecordingInfo(fileURL: destination, duration: finished.duration)
    }

    // MARK: - Engine plumbing

    /// Must run before `engine.start()`; touching `inputNode` first makes the I/O unit exist.
    /// `AVAudioEngine` uses ONE HAL device for input and output, so changing the input also
    /// moves the output (research 03 §1) — acceptable for a note recorder.
    private func applyInputDevice() throws {
        guard let inputDeviceUID, let deviceID = AudioDeviceCatalog.deviceID(forUID: inputDeviceUID) else { return }
        let input = engine.inputNode
        guard let unit = input.audioUnit else { return }
        var value = deviceID
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &value,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func installTapAndStart(creatingWriterAt url: URL) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard Self.isUsable(format: format) else {
            throw Failure.unusableInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        let writer = try self.writer ?? AACWriter(url: url, inputFormat: format)
        let continuation = levelContinuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Runs on a realtime audio thread, not the main actor: no allocation-heavy work here.
            // One tap, three jobs (archive + meter) — a bus accepts only one tap.
            continuation.yield(LevelMeter.rms(buffer))
            try? writer.write(buffer)
        }
        self.writer = writer
        engine.prepare()
        try engine.start()
    }

    /// Recovery sequence from research 03 §1: the engine has already stopped and uninitialised itself
    /// when this fires, the notification does not say what changed, and the callback arrives on an
    /// internal dispatch queue (never deallocate the engine there) — so we hop onto the actor, drop
    /// the tap, re-read `inputFormat(forBus: 0)`, reinstall the tap with the new format and
    /// call `engine.start()` again. Forgetting the restart kills the recording silently: no crash,
    /// no error, just no more audio.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.recoverFromConfigurationChange() }
        }
    }

    /// The existing `AACWriter` is reused so the already-written frames survive the switch;
    /// only the tap and the engine are rebuilt. A device that came back at 0 Hz leaves the
    /// recording stopped rather than crashing (the `isUsable` guard throws and we swallow it).
    private func recoverFromConfigurationChange() {
        guard let destination, writer != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        try? applyInputDevice()
        try? installTapAndStart(creatingWriterAt: destination)
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=EngineAudioRecorder 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueNotes/EngineAudioRecorder.swift Tests/ShotcueNotesTests/EngineAudioRecorderTests.swift
git commit -m "feat(notes): add AVAudioEngine recorder with configuration-change recovery

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Manuel kontrol listesi (gerçek mikrofon) — kullanıcıyla birlikte**

`ShotcueNotes` henüz UI'ya bağlı değil (Plan 05 bağlayacak), bu yüzden kaydı geçici bir tanılama yoluyla çalıştır. Plan 00 Task 11'de `SHOTCUE_SPIKE` işleyicisi var; oraya **geçici** bir `record` kolu ekle, ölç, sonra **geri al** (bu adım commit edilmez):

`Sources/ShotcueApp/ShotcueApp.swift` içindeki `SpikeRunner.runIfRequested()`'ın `switch spike` bloğuna geçici olarak ekle:

```swift
        case "record":
            let url = URL(fileURLWithPath: "/tmp/shotcue-spike-record.m4a")
            let recorder = EngineAudioRecorder()
            let semaphore = DispatchSemaphore(value: 0)
            var text = "spike=record\n"
            Task {
                do {
                    try await recorder.start(writingTo: url)
                    let levels = Task {
                        var peak: Float = 0
                        for await level in recorder.levels { peak = max(peak, level) }
                        return peak
                    }
                    try await Task.sleep(for: .seconds(3))
                    let info = try await recorder.stop()
                    levels.cancel()
                    text += "duration=\(info.duration)\nfile=\(info.fileURL.path)\npeak=\(await levels.value)\n"
                } catch {
                    text += "error=\(error)\n"
                }
                semaphore.signal()
            }
            semaphore.wait()
            try? text.write(to: output, atomically: true, encoding: .utf8)
            exit(0)
```

Ayrıca dosyanın başına `import ShotcueNotes` ekle.

Run: `make install && open -a ~/Applications/Shotcue.app --env SHOTCUE_SPIKE=record && sleep 8 && cat /tmp/shotcue-spike-record.txt && afinfo /tmp/shotcue-spike-record.m4a`

Expected ve kontrol listesi:
1. **İlk çalıştırmada macOS mikrofon izni diyaloğu Shotcue adına çıkar.** Çıkmıyorsa `codesign -d --entitlements - ~/Applications/Shotcue.app | grep audio-input` ile `com.apple.security.device.audio-input` var mı bak — yoksa Hardened Runtime mikrofonu TCC'ye sormadan reddeder ve **sadece sıfır dolu sample gelir** (araştırma 03 §1).
2. `duration` 3.0 ± 0.2 saniye.
3. `peak` > 0 (konuşarak test et; 0 geliyorsa yukarıdaki entitlement kontrolünü tekrarla).
4. `afinfo` çıktısında `AAC`, `48000 Hz`, `1 ch`, bit rate ~64 kbps.
5. **Cihaz değişikliği:** komutu tekrar çalıştır ve 3 saniye içinde AirPods'u bağla/çıkar. Dosya yine ~3 sn olmalı ve ses kesilmemeli (config-change kurtarması). Bluetooth devreye girince format 16 kHz'e düşer; `AACWriter` dönüştürüp 48 kHz mono yazmaya devam eder.
6. **Cihaz seçimi:** `EngineAudioRecorder(inputDeviceUID: <UID>)` ile Task 4'ün listelediği bir UID'yi ver ve `afinfo`'nun yine 48 kHz mono AAC gösterdiğini doğrula.

Sonra geçici kolu geri al: `git checkout -- Sources/ShotcueApp/ShotcueApp.swift`. Gözlemleri `docs/superpowers/plans/spike-results.md` içine `### Plan 03 manuel kayıt kontrolü` başlığıyla yaz ve commit'le:

```bash
git add docs/superpowers/plans/spike-results.md
git commit -m "docs: record manual microphone checklist results

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: AudioDeviceCatalog (giriş cihazı listesi ve UID çevirisi)

Spec §6.2: "Giriş cihazı seçimi: `AVCaptureDevice.DiscoverySession` listesi → `kAudioOutputUnitProperty_CurrentDevice`". Araştırma 03 §1: UI için `localizedName`, eşleme için `uniqueID` (= Core Audio UID); UID → `AudioDeviceID` çevirisi `kAudioHardwarePropertyTranslateUIDToDevice` ile yapılır.

CI'da ses cihazı olmayabilir, bu yüzden test "boş dizi de kabul, çökme yok" şeklinde yazılır.

**Files:**
- Create: `Tests/ShotcueNotesTests/AudioDeviceCatalogTests.swift`
- Create: `Sources/ShotcueNotes/AudioDeviceCatalog.swift`

**Interfaces:**
- Consumes: yok.
- Produces:
  ```swift
  public enum AudioDeviceCatalog {
      public static func inputDevices() -> [(uid: String, name: String)]
      public static func deviceID(forUID uid: String) -> AudioDeviceID?
  }
  ```
  Plan 05 (Ayarlar > Ses) `inputDevices()` ile picker doldurur ve seçilen `uid`'yi `EngineAudioRecorder(inputDeviceUID:)`'e geçirir.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueNotesTests/AudioDeviceCatalogTests.swift`:

```swift
import Foundation
import Testing
@testable import ShotcueNotes

@Suite("AudioDeviceCatalog")
struct AudioDeviceCatalogTests {
    @Test func listingInputDevicesDoesNotCrash() {
        let devices = AudioDeviceCatalog.inputDevices()
        #expect(devices.count >= 0)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }
    }

    @Test func unknownUIDTranslatesToNil() {
        #expect(AudioDeviceCatalog.deviceID(forUID: "shotcue-no-such-device") == nil)
    }

    @Test func listedDevicesTranslateToDeviceIDs() {
        for device in AudioDeviceCatalog.inputDevices() {
            #expect(AudioDeviceCatalog.deviceID(forUID: device.uid) != nil)
        }
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=AudioDeviceCatalog 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'AudioDeviceCatalog' in scope`.

- [ ] **Step 3: AudioDeviceCatalog'u yaz**

`Sources/ShotcueNotes/AudioDeviceCatalog.swift`:

```swift
import AVFoundation
import CoreAudio
import Foundation

/// Input devices for the Ses settings tab. `uid` is the Core Audio UID (`AVCaptureDevice.uniqueID`).
public enum AudioDeviceCatalog {
    public static func inputDevices() -> [(uid: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { (uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Translates a Core Audio UID to an `AudioDeviceID`; nil when the device is gone.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=AudioDeviceCatalog 2>&1 | tail -3`
Expected: `Test run with 3 tests in 1 suite passed`. (Bu makinede `inputDevices()` 2 cihaz döndü: `BuiltInMicrophoneDevice` ve bir iPhone mikrofonu; ikisinin de UID çevirisi başarılı, uydurma UID `nil`.)

- [ ] **Step 5: Commit**

```bash
make format && git add Sources/ShotcueNotes/AudioDeviceCatalog.swift Tests/ShotcueNotesTests/AudioDeviceCatalogTests.swift
git commit -m "feat(notes): list audio input devices and translate Core Audio UIDs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: WhisperKitTranscriber (WhisperEngine seam + gerçek WhisperKit adaptörü)

Spec §6.2: tek motor, varsayılan model Task 1'in kararı (öntanımlı `openai_whisper-large-v3-v20240930_turbo`), varsayılan dil `tr`, `auto` yok; model ilk kullanımda açık onayla indirilir; çıktı `Transcript { text, language, engine, segments[{start,end,text,confidence?}] }`.

Model 1.6 GB olduğu için `swift test` gerçek WhisperKit'i çalıştırmaz. Mantık (durum makinesi, dil geçişi, segment eşlemesi) küçük bir iç protokolün — `WhisperEngine` — arkasına alınır ve testte sahte motorla sürülür. Gerçek adaptör `WhisperKitEngine` yalnızca Task 1'in manuel spike'ında ve uygulamada çalışır.

**Files:**
- Create: `Tests/ShotcueNotesTests/WhisperKitTranscriberTests.swift`
- Create: `Sources/ShotcueNotes/WhisperEngine.swift`, `Sources/ShotcueNotes/WhisperKitTranscriber.swift`

**Interfaces:**
- Consumes (Plan 00 Task 10, birebir):
  ```swift
  public enum TranscriberModelState: Hashable, Sendable {
      case notDownloaded
      case downloading(progress: Double)
      case ready
      case failed(String)
  }
  public protocol Transcriber: Sendable {
      var engineName: String { get }
      func modelState() async -> TranscriberModelState
      func downloadModel() async throws
      func transcribe(fileURL: URL, language: String) async throws -> Transcript
  }
  ```
  ve Plan 00 Task 1'den:
  ```swift
  public struct Transcript: Hashable, Sendable, Codable {
      public struct Segment: Hashable, Sendable, Codable {
          public var start: Double
          public var end: Double
          public var text: String
          public var confidence: Double?
          public init(start: Double, end: Double, text: String, confidence: Double? = nil)
      }
      public var text: String
      public var language: String
      public var engine: String
      public var segments: [Segment]
      public init(text: String, language: String, engine: String, segments: [Segment] = [])
  }
  ```
  Testte `ShotcueTestSupport`'tan `Locked<Value>` ve `FakeError`.
- Produces:
  ```swift
  public struct WhisperSegment: Hashable, Sendable {
      public var start: Double
      public var end: Double
      public var text: String
      public var confidence: Double?
      public init(start: Double, end: Double, text: String, confidence: Double? = nil)
  }
  public protocol WhisperEngine: Sendable {
      func transcribe(url: URL, language: String) async throws -> [WhisperSegment]
  }
  public actor WhisperKitEngine: WhisperEngine {
      public static let repo: String
      public enum Failure: Error, Equatable { case modelNotLoaded }
      public init(modelName: String, modelsDirectory: URL)
      public static func modelFolderURL(modelsDirectory: URL, modelName: String) -> URL
      public func isDownloaded(fileManager: FileManager = .default) -> Bool
      public func download(onProgress: @escaping @Sendable (Double) -> Void) async throws
      public func load() async throws
      public func unload()
      public func transcribe(url: URL, language: String) async throws -> [WhisperSegment]
      public static func recommendedModelNames() -> [String]
  }
  public actor WhisperKitTranscriber: Transcriber {
      public static let defaultModelName: String    // "openai_whisper-large-v3-v20240930_turbo"
      public static let compactModelName: String    // "openai_whisper-large-v3-v20240930_turbo_632MB"
      public nonisolated let engineName: String     // "whisperkit/<modelName>"
      public nonisolated var modelFolderURL: URL { get }
      public init(modelName: String, modelsDirectory: URL)
      public init(modelName: String, modelsDirectory: URL, engine: any WhisperEngine,
                  initialState: TranscriberModelState = .notDownloaded)
      public func modelState() async -> TranscriberModelState
      public func downloadModel() async throws
      public func transcribe(fileURL: URL, language: String) async throws -> Transcript
  }
  ```
  Plan 05 (Ayarlar > Ses) `WhisperKitEngine.recommendedModelNames()` ile model listesini gösterir, `modelState()` ile indirme durumunu, `downloadModel()` ile indirmeyi başlatır.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueNotesTests/WhisperKitTranscriberTests.swift`:

```swift
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing
@testable import ShotcueNotes

/// Records the language it was called with and replays scripted segments.
final class RecordingWhisperEngine: WhisperEngine, @unchecked Sendable {
    let calls = Locked<[(url: URL, language: String)]>([])
    let segments: [WhisperSegment]
    let failure: FakeError?

    init(segments: [WhisperSegment] = [
        WhisperSegment(start: 0, end: 2.4, text: "login ekranındaki modal", confidence: 0.91),
        WhisperSegment(start: 2.4, end: 4.8, text: "API endpoint'i deploy et", confidence: 0.88),
    ], failure: FakeError? = nil) {
        self.segments = segments
        self.failure = failure
    }

    func transcribe(url: URL, language: String) async throws -> [WhisperSegment] {
        calls.withLock { $0.append((url, language)) }
        if let failure { throw failure }
        return segments
    }
}

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {
    private func emptyModelsDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-models-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func engineNameCarriesTheModelName() async {
        let transcriber = WhisperKitTranscriber(modelName: WhisperKitTranscriber.defaultModelName,
                                                modelsDirectory: emptyModelsDirectory())
        #expect(transcriber.engineName == "whisperkit/openai_whisper-large-v3-v20240930_turbo")
    }

    @Test func modelStateIsNotDownloadedForAnEmptyDirectory() async {
        let directory = emptyModelsDirectory()
        let transcriber = WhisperKitTranscriber(modelName: WhisperKitTranscriber.defaultModelName,
                                                modelsDirectory: directory)
        #expect(await transcriber.modelState() == .notDownloaded)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func modelStateIsReadyOnceTheModelFolderExists() async throws {
        let directory = emptyModelsDirectory()
        let transcriber = WhisperKitTranscriber(modelName: WhisperKitTranscriber.defaultModelName,
                                                modelsDirectory: directory)
        try FileManager.default.createDirectory(at: transcriber.modelFolderURL, withIntermediateDirectories: true)
        #expect(await transcriber.modelState() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func modelFolderFollowsTheHubCacheLayout() async {
        let root = URL(fileURLWithPath: "/tmp/shotcue-models")
        let folder = WhisperKitEngine.modelFolderURL(modelsDirectory: root,
                                                     modelName: WhisperKitTranscriber.defaultModelName)
        #expect(folder.path == "/tmp/shotcue-models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
    }

    @Test func passesLanguageThroughAndMapsSegments() async throws {
        let engine = RecordingWhisperEngine()
        let transcriber = WhisperKitTranscriber(modelName: WhisperKitTranscriber.defaultModelName,
                                                modelsDirectory: emptyModelsDirectory(),
                                                engine: engine, initialState: .ready)
        let audio = URL(fileURLWithPath: "/tmp/note.m4a")
        let transcript = try await transcriber.transcribe(fileURL: audio, language: "tr")

        #expect(engine.calls.current.count == 1)
        #expect(engine.calls.current.first?.language == "tr")
        #expect(engine.calls.current.first?.url == audio)
        #expect(transcript.text == "login ekranındaki modal API endpoint'i deploy et")
        #expect(transcript.language == "tr")
        #expect(transcript.engine == "whisperkit/openai_whisper-large-v3-v20240930_turbo")
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].start == 0)
        #expect(transcript.segments[1].end == 4.8)
        #expect(transcript.segments[0].confidence == 0.91)
    }

    @Test func englishLanguageIsPassedThroughUnchanged() async throws {
        let engine = RecordingWhisperEngine(segments: [WhisperSegment(start: 0, end: 1, text: "clear the cache")])
        let transcriber = WhisperKitTranscriber(modelName: WhisperKitTranscriber.compactModelName,
                                                modelsDirectory: emptyModelsDirectory(),
                                                engine: engine, initialState: .ready)
        let transcript = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: "/tmp/en.m4a"),
                                                          language: "en")
        #expect(engine.calls.current.first?.language == "en")
        #expect(transcript.engine == "whisperkit/openai_whisper-large-v3-v20240930_turbo_632MB")
        #expect(transcript.text == "clear the cache")
    }

    @Test func failureMovesTheStateToFailed() async {
        let engine = RecordingWhisperEngine(failure: FakeError("model missing"))
        let transcriber = WhisperKitTranscriber(modelName: WhisperKitTranscriber.defaultModelName,
                                                modelsDirectory: emptyModelsDirectory(),
                                                engine: engine, initialState: .ready)
        await #expect(throws: FakeError.self) {
            _ = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: "/tmp/x.m4a"), language: "tr")
        }
        if case .failed(let message) = await transcriber.modelState() {
            #expect(message.contains("model missing"))
        } else {
            Issue.record("state should be .failed")
        }
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=WhisperKitTranscriber 2>&1 | grep -m1 "error:"`
Expected: `cannot find type 'WhisperEngine' in scope`.

- [ ] **Step 3: WhisperEngine seam'ini ve gerçek adaptörü yaz**

`Sources/ShotcueNotes/WhisperEngine.swift`:

```swift
import Foundation
import WhisperKit

/// One transcribed span as WhisperKit reports it, converted to Double/seconds.
public struct WhisperSegment: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    /// `exp(avgLogprob)` — the closest thing WhisperKit gives us to a 0…1 confidence.
    public var confidence: Double?

    public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

/// Seam between `WhisperKitTranscriber`'s logic and the 1.6 GB model: tests inject a fake.
public protocol WhisperEngine: Sendable {
    func transcribe(url: URL, language: String) async throws -> [WhisperSegment]
}

/// Real adapter over WhisperKit 1.1 (`argmax-oss-swift`). Exercised manually in Task 1, never in `swift test`.
public actor WhisperKitEngine: WhisperEngine {
    public static let repo = "argmaxinc/whisperkit-coreml"

    public enum Failure: Error, Equatable {
        case modelNotLoaded
    }

    private let modelName: String
    private let modelsDirectory: URL
    private var kit: WhisperKit?

    public init(modelName: String, modelsDirectory: URL) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
    }

    /// HubApi caches a repo snapshot at `downloadBase/models/<repo>/`; `WhisperKit.download`
    /// returns that path with the variant folder appended.
    public static func modelFolderURL(modelsDirectory: URL, modelName: String) -> URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    public func isDownloaded(fileManager: FileManager = .default) -> Bool {
        let folder = Self.modelFolderURL(modelsDirectory: modelsDirectory, modelName: modelName)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let callback: ProgressCallback = { progress in onProgress(progress.fractionCompleted) }
        _ = try await WhisperKit.download(
            variant: modelName,
            downloadBase: modelsDirectory,
            useBackgroundSession: false,
            from: Self.repo,
            progressCallback: callback
        )
    }

    /// Loads the CoreML models from disk. `download: false` keeps this offline — the explicit
    /// download step (spec §6.2: "Model ilk kullanımda açık onayla indirilir") owns the network.
    public func load() async throws {
        guard kit == nil else { return }
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDirectory,
            modelRepo: Self.repo,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
    }

    public func unload() {
        kit = nil
    }

    public func transcribe(url: URL, language: String) async throws -> [WhisperSegment] {
        try await load()
        guard let kit else { throw Failure.modelNotLoaded }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: url.path,
                                                                     decodeOptions: options)
        return results.flatMap { result in
            result.segments.map { segment in
                WhisperSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: Double(exp(segment.avgLogprob))
                )
            }
        }
    }

    /// Names offered in Ayarlar > Ses; both models the spec mentions are in
    /// `recommendedModels().supported` on Apple Silicon (verified 2026-09-22).
    public static func recommendedModelNames() -> [String] {
        WhisperKit.recommendedModels().supported
    }
}
```

- [ ] **Step 4: WhisperKitTranscriber'ı yaz**

`Sources/ShotcueNotes/WhisperKitTranscriber.swift`:

```swift
import Foundation
import ShotcueCore

/// `Transcriber` on top of WhisperKit (spec §6.2: single engine in v1, default model
/// `openai_whisper-large-v3-v20240930_turbo`, default language `tr`).
public actor WhisperKitTranscriber: Transcriber {
    public static let defaultModelName = "openai_whisper-large-v3-v20240930_turbo"
    public static let compactModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    /// `nonisolated`: an actor's `let` is only cross-actor readable inside its own module,
    /// and both the protocol requirement and the tests read this from outside `ShotcueNotes`.
    public nonisolated let engineName: String
    private let modelName: String
    private let modelsDirectory: URL
    private let engine: any WhisperEngine
    private let whisperKitEngine: WhisperKitEngine?
    private var state: TranscriberModelState

    /// Production: builds its own `WhisperKitEngine`.
    public init(modelName: String, modelsDirectory: URL) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
        engineName = "whisperkit/\(modelName)"
        let kitEngine = WhisperKitEngine(modelName: modelName, modelsDirectory: modelsDirectory)
        whisperKitEngine = kitEngine
        engine = kitEngine
        state = .notDownloaded
    }

    /// Tests: inject a fake engine so the mapping/state logic runs without the 1.6 GB model.
    public init(modelName: String, modelsDirectory: URL, engine: any WhisperEngine,
                initialState: TranscriberModelState = .notDownloaded) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
        engineName = "whisperkit/\(modelName)"
        whisperKitEngine = nil
        self.engine = engine
        state = initialState
    }

    /// Where the CoreML bundle lands: `modelsDirectory/models/argmaxinc/whisperkit-coreml/<modelName>`.
    public nonisolated var modelFolderURL: URL {
        WhisperKitEngine.modelFolderURL(modelsDirectory: modelsDirectory, modelName: modelName)
    }

    public func modelState() async -> TranscriberModelState {
        switch state {
        case .downloading, .failed:
            return state
        case .ready:
            return .ready
        case .notDownloaded:
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: modelFolderURL.path,
                                                        isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? .ready : .notDownloaded
        }
    }

    public func downloadModel() async throws {
        guard let whisperKitEngine else {
            state = .ready
            return
        }
        state = .downloading(progress: 0)
        do {
            try await whisperKitEngine.download { [weak self] fraction in
                guard let self else { return }
                Task { await self.setProgress(fraction) }
            }
            try await whisperKitEngine.load()
            state = .ready
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    public func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        do {
            let segments = try await engine.transcribe(url: fileURL, language: language)
            state = .ready
            let text = segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            return Transcript(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: language,
                engine: engineName,
                segments: segments.map {
                    Transcript.Segment(start: $0.start, end: $0.end, text: $0.text,
                                       confidence: $0.confidence)
                }
            )
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    private func setProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: min(1, max(0, fraction)))
    }
}
```

- [ ] **Step 5: Testlerin geçtiğini gör**

Run: `make test FILTER=WhisperKitTranscriber 2>&1 | tail -3`
Expected: `Test run with 7 tests in 1 suite passed`.

- [ ] **Step 6: Task 1'in kararını uygula**

`docs/superpowers/plans/spike-results.md` içindeki S4 KARAR satırını oku. Karar `openai_whisper-large-v3-v20240930_turbo_632MB` ise `WhisperKitTranscriber.defaultModelName` ve `compactModelName` değerlerini **yer değiştir** (isimler aynı kalır, değerler değişir) ve `make test FILTER=WhisperKitTranscriber`'ı tekrar çalıştır: `engineNameCarriesTheModelName`, `modelFolderFollowsTheHubCacheLayout`, `passesLanguageThroughAndMapsSegments`, `englishLanguageIsPassedThroughUnchanged` testlerindeki beklenen string'leri de güncelle. Karar `turbo` ise (öntanımlı) hiçbir şey değişmez.

Run: `make test FILTER=WhisperKitTranscriber 2>&1 | tail -3`
Expected: `Test run with 7 tests in 1 suite passed`.

- [ ] **Step 7: Commit**

```bash
make format && git add Sources/ShotcueNotes/WhisperEngine.swift Sources/ShotcueNotes/WhisperKitTranscriber.swift Tests/ShotcueNotesTests/WhisperKitTranscriberTests.swift
git commit -m "feat(notes): transcribe voice notes with WhisperKit behind a testable engine seam

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: TranscriptionCoordinator (arka plan kuyruğu, başlık doldurma)

Spec §5.2: "`VoiceNote` kaydı `transcriptState = pending` ile oluşur; transkripsiyon arka planda başlar ve bitince transkript alanına dolar. Kullanıcı transkripti düzenlerse `editedByUser = true` olur ve bir daha otomatik üzerine yazılmaz. Panel kapansa da transkripsiyon devam eder." Spec §6.2: "Model hazır değilken sesli notlar kaydedilir, transkript `pending` kalır, model gelince kuyruk işlenir." Spec §8: "Whisper modeli inmedi / transkripsiyon hatası → `transcript_state = failed`, ses saklanır." Spec §5.4: başlık otomatik olarak not metninin ilk cümlesinden, not yoksa transkriptin ilk cümlesinden gelir ve kullanıcı düzenlerse bir daha değişmez.

WhisperKit batch çalışır ve tüm modeli bellekte tutar, bu yüzden notlar **sırayla** işlenir.

**Files:**
- Create: `Tests/ShotcueNotesTests/TranscriptionCoordinatorTests.swift`
- Create: `Sources/ShotcueNotes/TranscriptionCoordinator.swift`

**Interfaces:**
- Consumes (Plan 00, birebir):
  ```swift
  public protocol TranscriptionQueue: Sendable {
      func enqueue(voiceNoteID: UUID) async
      func processPending() async
  }
  public protocol TaskRepository: Sendable {
      func allTasks() async throws -> [ShotTask]
      func task(id: UUID) async throws -> ShotTask?
      func voiceNotes(taskID: UUID) async throws -> [VoiceNote]
      func save(_ voiceNote: VoiceNote) async throws
      func save(_ task: ShotTask) async throws
      // … (bu plan yalnızca bu beş üyeyi kullanır)
  }
  public struct FileStore: Sendable {
      public init(rootURL: URL)
      public func absoluteURL(for relPath: String) -> URL
      // …
  }
  public enum TitleMaker {
      public static let maxLength: Int
      public static func title(noteText: String, transcript: String?, createdAt: Date,
                               calendar: Calendar = .current) -> String
  }
  public struct VoiceNote: Identifiable, Hashable, Sendable, Codable {
      public var id: UUID
      public var taskID: UUID
      public var relPath: String
      public var durationSec: Double
      public var transcript: String?
      public var transcriptJSON: String?
      public var transcriptState: TranscriptState   // pending | done | failed
      public var engine: String?
      public var editedByUser: Bool
      public var createdAt: Date
  }
  ```
  Testte `ShotcueTestSupport`'tan `FakeTranscriber(state:result:)` (`calls: Locked<[(fileURL: URL, language: String)]>`, `state: Locked<TranscriberModelState>`), `InMemoryTaskRepository`, `FakeError`.
- Produces:
  ```swift
  public actor TranscriptionCoordinator: TranscriptionQueue {
      public init(transcriber: any Transcriber, taskRepository: any TaskRepository,
                  fileStore: FileStore, language: String, titleMaker: Bool = true)
      public var isProcessing: Bool { get }
      public func setLanguage(_ newLanguage: String)
      public func enqueue(voiceNoteID: UUID) async
      public func processPending() async
  }
  ```
  Plan 05 kayıt kaydedildiğinde `enqueue(voiceNoteID:)`, Plan 06 (App) açılışta ve model hazır olduğunda `processPending()` çağırır; Ayarlar dil değiştirince `setLanguage(_:)`.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueNotesTests/TranscriptionCoordinatorTests.swift`:

```swift
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing
@testable import ShotcueNotes

/// Fixture: one task with one pending voice note.
struct CoordinatorFixture {
    var repo: InMemoryTaskRepository
    var task: ShotTask
    var note: VoiceNote

    static func make(noteText: String = "", titleEditedByUser: Bool = false,
                     editedByUser: Bool = false) async throws -> CoordinatorFixture {
        let repo = InMemoryTaskRepository()
        let task = ShotTask(projectID: UUID(), title: "Yakalama 22.09 12:00", noteText: noteText,
                            status: .ready, titleEditedByUser: titleEditedByUser,
                            createdAt: Date(timeIntervalSince1970: 1_790_078_400))
        try await repo.save(task)
        let note = VoiceNote(taskID: task.id, relPath: "audio/one.m4a", durationSec: 22,
                             transcriptState: .pending, editedByUser: editedByUser)
        try await repo.save(note)
        return CoordinatorFixture(repo: repo, task: task, note: note)
    }

    func temporaryStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-coord-\(UUID().uuidString)", isDirectory: true))
    }
}

@Suite("TranscriptionCoordinator")
struct TranscriptionCoordinatorTests {
    // Async repository reads are hoisted into a `let` before `#expect` so a failing expectation
    // shows the value that was actually stored instead of the whole `try await` expression.

    @Test func pendingNoteIsTranscribedAndStored() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcript = Transcript(text: "modal açılınca API endpoint'i çağır", language: "tr",
                                    engine: "whisperkit/openai_whisper-large-v3-v20240930_turbo",
                                    segments: [.init(start: 0, end: 3.2,
                                                     text: "modal açılınca API endpoint'i çağır",
                                                     confidence: 0.9)])
        let transcriber = FakeTranscriber(state: .ready, result: .success(transcript))
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()

        let notes = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        let stored = try #require(notes.first { $0.id == fixture.note.id })
        #expect(stored.transcriptState == .done)
        #expect(stored.transcript == "modal açılınca API endpoint'i çağır")
        #expect(stored.engine == "whisperkit/openai_whisper-large-v3-v20240930_turbo")
        let json = try #require(stored.transcriptJSON)
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(decoded == transcript)
        #expect(transcriber.calls.current.first?.language == "tr")
        let processing = await coordinator.isProcessing
        #expect(processing == false)
    }

    @Test func transcribedFileURLComesFromTheFileStore() async throws {
        let fixture = try await CoordinatorFixture.make()
        let store = FileStore(rootURL: URL(fileURLWithPath: "/tmp/shotcue-root"))
        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: store, language: "tr")
        await coordinator.processPending()
        #expect(transcriber.calls.current.first?.fileURL.path == "/tmp/shotcue-root/audio/one.m4a")
    }

    @Test func transcriptionFailureMarksTheNoteFailed() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(state: .ready, result: .failure(FakeError("model missing")))
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()

        let notes = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        let stored = try #require(notes.first { $0.id == fixture.note.id })
        #expect(stored.transcriptState == .failed)
        #expect(stored.transcript == nil)
        #expect(stored.engine == "fake")
    }

    @Test func userEditedNotesAreNeverOverwritten() async throws {
        let repo = InMemoryTaskRepository()
        let task = ShotTask(projectID: UUID(), title: "t", status: .ready)
        try await repo.save(task)
        let note = VoiceNote(taskID: task.id, relPath: "audio/edited.m4a", durationSec: 5,
                             transcript: "kullanıcının yazdığı metin", transcriptState: .pending,
                             editedByUser: true)
        try await repo.save(note)

        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: repo,
                                                   fileStore: FileStore(rootURL: URL(fileURLWithPath: "/tmp")),
                                                   language: "tr")
        await coordinator.processPending()

        let notes = try await repo.voiceNotes(taskID: task.id)
        let stored = try #require(notes.first)
        #expect(stored.transcript == "kullanıcının yazdığı metin")
        #expect(stored.transcriptState == .pending)
        #expect(transcriber.calls.current.isEmpty)
    }

    @Test func titleIsFilledFromTheTranscriptWhenTheNoteIsBlank() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "Login ekranındaki modal bozuk. Düzelt.",
                                        language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Login ekranındaki modal bozuk")
    }

    @Test func titleIsKeptWhenTheUserEditedIt() async throws {
        let fixture = try await CoordinatorFixture.make(titleEditedByUser: true)
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "başka bir başlık", language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Yakalama 22.09 12:00")
    }

    @Test func titleIsKeptWhenTheNoteHasText() async throws {
        let fixture = try await CoordinatorFixture.make(noteText: "butonun rengi yanlış")
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "başka bir başlık", language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Yakalama 22.09 12:00")
    }

    @Test func titleAutoFillCanBeDisabled() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(
            state: .ready,
            result: .success(Transcript(text: "yeni başlık olmalı", language: "tr", engine: "fake")))
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr",
                                                   titleMaker: false)
        await coordinator.processPending()
        let stored = try #require(try await fixture.repo.task(id: fixture.task.id))
        #expect(stored.title == "Yakalama 22.09 12:00")
    }

    @Test func modelNotReadyLeavesTheNotePending() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(state: .notDownloaded)
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.enqueue(voiceNoteID: fixture.note.id)
        await coordinator.processPending()

        let pending = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        #expect(pending.first?.transcriptState == .pending)
        #expect(transcriber.calls.current.isEmpty)

        transcriber.state.set(.ready)
        await coordinator.enqueue(voiceNoteID: fixture.note.id)
        let done = try await fixture.repo.voiceNotes(taskID: fixture.task.id)
        #expect(done.first?.transcriptState == .done)
        #expect(transcriber.calls.current.count == 1)
    }

    @Test func threeNotesAreProcessedSequentiallyInManualOrder() async throws {
        let repo = InMemoryTaskRepository()
        for index in 0..<3 {
            let task = ShotTask(projectID: UUID(), title: "task \(index)", status: .ready,
                                sortIndex: Double(index),
                                createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
            try await repo.save(task)
            let note = VoiceNote(taskID: task.id, relPath: "audio/n\(index).m4a", durationSec: 20,
                                 transcriptState: .pending)
            try await repo.save(note)
        }
        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(
            transcriber: transcriber, taskRepository: repo,
            fileStore: FileStore(rootURL: URL(fileURLWithPath: "/tmp/shotcue-seq")), language: "tr")
        await coordinator.processPending()

        let names = transcriber.calls.current.map { $0.fileURL.lastPathComponent }
        #expect(names == ["n0.m4a", "n1.m4a", "n2.m4a"])

        var states: [TranscriptState] = []
        for task in try await repo.allTasks() {
            for note in try await repo.voiceNotes(taskID: task.id) { states.append(note.transcriptState) }
        }
        #expect(states == [.done, .done, .done])
    }

    @Test func languageCanBeChangedAtRuntime() async throws {
        let fixture = try await CoordinatorFixture.make()
        let transcriber = FakeTranscriber(state: .ready)
        let coordinator = TranscriptionCoordinator(transcriber: transcriber, taskRepository: fixture.repo,
                                                   fileStore: fixture.temporaryStore(), language: "tr")
        await coordinator.setLanguage("en")
        await coordinator.processPending()
        #expect(transcriber.calls.current.first?.language == "en")
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=TranscriptionCoordinator 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'TranscriptionCoordinator' in scope`.

- [ ] **Step 3: TranscriptionCoordinator'ı yaz**

`Sources/ShotcueNotes/TranscriptionCoordinator.swift`:

```swift
import Foundation
import ShotcueCore

/// Background transcription queue (spec §5.2: "Panel kapansa da transkripsiyon devam eder").
/// Runs notes one at a time — WhisperKit is batch and holds the whole model in memory.
public actor TranscriptionCoordinator: TranscriptionQueue {
    private let transcriber: any Transcriber
    private let taskRepository: any TaskRepository
    private let fileStore: FileStore
    private let titleMaker: Bool
    private var language: String
    private var processing = false

    public init(transcriber: any Transcriber, taskRepository: any TaskRepository, fileStore: FileStore,
                language: String, titleMaker: Bool = true) {
        self.transcriber = transcriber
        self.taskRepository = taskRepository
        self.fileStore = fileStore
        self.language = language
        self.titleMaker = titleMaker
    }

    public var isProcessing: Bool { processing }

    public func setLanguage(_ newLanguage: String) {
        language = newLanguage
    }

    /// Called right after a recording is saved. When the model is not ready the note simply stays
    /// `pending`; `processPending()` picks it up once the download finishes.
    public func enqueue(voiceNoteID: UUID) async {
        guard await transcriber.modelState() == .ready else { return }
        await processPending()
    }

    /// Transcribes every `pending` voice note, oldest task first. Errors mark that one note
    /// `.failed` (audio is kept, spec §8) and never stop the queue.
    public func processPending() async {
        guard !processing else { return }
        guard await transcriber.modelState() == .ready else { return }
        processing = true
        defer { processing = false }

        for pending in await pendingNotes() {
            await transcribe(note: pending.note, in: pending.task)
        }
    }

    // MARK: - Internals

    private struct PendingNote {
        var note: VoiceNote
        var task: ShotTask
    }

    /// `TaskRepository` has no "all voice notes" query, so walk tasks → notes (spec §6.3 schema).
    /// `allTasks()` already returns manual order (`QueuePolicy.ordered`).
    private func pendingNotes() async -> [PendingNote] {
        guard let tasks = try? await taskRepository.allTasks() else { return [] }
        var result: [PendingNote] = []
        for task in tasks {
            guard let notes = try? await taskRepository.voiceNotes(taskID: task.id) else { continue }
            for note in notes where note.transcriptState == .pending && !note.editedByUser {
                result.append(PendingNote(note: note, task: task))
            }
        }
        return result
    }

    private func transcribe(note: VoiceNote, in task: ShotTask) async {
        // Re-read: the user may have edited the transcript while an earlier note was running.
        let current = (try? await taskRepository.voiceNotes(taskID: task.id))?
            .first { $0.id == note.id } ?? note
        guard current.transcriptState == .pending, !current.editedByUser else { return }

        let fileURL = fileStore.absoluteURL(for: current.relPath)
        var updated = current
        do {
            let transcript = try await transcriber.transcribe(fileURL: fileURL, language: language)
            updated.transcript = transcript.text
            updated.transcriptJSON = Self.encode(transcript)
            updated.transcriptState = .done
            updated.engine = transcript.engine
            try? await taskRepository.save(updated)
            await autoFillTitle(for: task, transcript: transcript.text)
        } catch {
            updated.transcriptState = .failed
            updated.engine = transcriber.engineName
            try? await taskRepository.save(updated)
        }
    }

    /// Spec §5.4: the title follows the note, then the transcript, and stops once the user edits it.
    private func autoFillTitle(for task: ShotTask, transcript: String) async {
        guard titleMaker else { return }
        let current = (try? await taskRepository.task(id: task.id)) ?? task
        guard current.titleEditedByUser == false,
              current.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        var updated = current
        updated.title = TitleMaker.title(noteText: current.noteText, transcript: transcript,
                                         createdAt: current.createdAt)
        updated.updatedAt = Date()
        try? await taskRepository.save(updated)
    }

    static func encode(_ transcript: Transcript) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(transcript) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=TranscriptionCoordinator 2>&1 | tail -3`
Expected: `Test run with 11 tests in 1 suite passed`.

- [ ] **Step 5: Tüm Notes testlerini çalıştır**

Run: `make test FILTER=ShotcueNotesTests 2>&1 | tail -3`
Expected: `Test run with 33 tests in 6 suites passed` (LevelMeter 4 + AACWriter 4 + EngineAudioRecorder 4 + AudioDeviceCatalog 3 + WhisperKitTranscriber 7 + TranscriptionCoordinator 11).

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcueNotes/TranscriptionCoordinator.swift Tests/ShotcueNotesTests/TranscriptionCoordinatorTests.swift
git commit -m "feat(notes): process pending voice notes sequentially and auto-fill titles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Foundation Models — `@Generable` başlık önerisi ERTELENDİ, yerine availability raporu

Spec §6.2 opsiyonel özelliği: "`SystemLanguageModel.default.availability == .available` ise `@Generable TaskDraft { title, summary, tags }` ile başlık ve temiz görev metni **önerisi**." Bu task bu özelliğin **neden v1'de yazılamadığını** kanıtla kayda geçirir ve ölçülebilir olan kısmını (availability raporu, Ayarlar > İzinler'deki "Foundation Models durumu" satırı — spec §6.6) teslim eder.

**Derleme kanıtı.** Scratchpad'de bu dosya derlenmeye çalışıldı (aynı `.defaultIsolation(nil)` + upcoming feature ayarlarıyla, CLT 27.0 / SDK MacOSX27.0):

```swift
import FoundationModels

@available(macOS 26, *)
@Generable
public struct ProbeTaskDraft: Sendable {
    @Guide(description: "En fazla 6 kelimelik, emir kipinde Türkçe başlık")
    public var title: String
    @Guide(description: "Dikte metninden temizlenmiş, net görev tanımı")
    public var summary: String
    @Guide(description: "1-3 adet kısa etiket", .count(1...3))
    public var tags: [String]
}
```

Sonuç:

```
error: external macro implementation type 'FoundationModelsMacros.GenerableMacro' could not be found
       for macro 'Generable(description:)'; plugin for module 'FoundationModelsMacros' not found
error: external macro implementation type 'FoundationModelsMacros.GuideMacro' could not be found
       for macro 'Guide(description:)'; plugin for module 'FoundationModelsMacros' not found
```

Sebep, `#Preview`/`KeyboardShortcuts` ile aynı: Command Line Tools makro eklentisi olarak yalnızca `libObservationMacros.dylib` ve `libSwiftMacros.dylib`'i getiriyor (`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/` içinde `FoundationModelsMacros` **yok**), framework ise SDK'da mevcut. Yani `@Generable`/`@Guide` **Xcode olmadan derlenemez** ve Global Constraints "Xcode yok" maddesi bu özelliği v1 dışına atar.

Makro olmayan kısım **derleniyor** (aynı scratchpad'de doğrulandı): `import FoundationModels`, `SystemLanguageModel.default.availability`, `SystemLanguageModel.default.supportedLanguages`, `LanguageModelSession(instructions:)` ve `respond(to:)` (düz `String` dönüşü). Bu makinede `availability == .unavailable(.appleIntelligenceNotEnabled)` ve `supportedLanguages` 23 dil içinde `tr-Latn-TR` var (araştırma 03 §6 ile birebir).

**v1.1 planı (bu plana dahil değil):** Xcode kurulursa ya da Apple `FoundationModelsMacros`'ı CLT'ye eklerse, `FoundationModelsTitleSuggester` (`@Generable struct TaskDraft { title, summary, tags }`, `public static var isAvailable: Bool`, `public func suggest(noteText:transcript:) async throws -> TaskDraft`) bu modüle `#if canImport(FoundationModels)` + `@available(macOS 26, *)` arkasında eklenir ve `FoundationModelsStatus.isAvailable` kapısını kullanır. Alternatif, makro istemeyen yol: `LanguageModelSession.respond(to:)` ile düz metin isteyip JSON'u elle ayrıştırmak — guided generation'ın şema garantisi olmadığı için v1'e alınmadı.

**Files:**
- Create: `Tests/ShotcueNotesTests/FoundationModelsStatusTests.swift`
- Create: `Sources/ShotcueNotes/FoundationModelsStatus.swift`

**Interfaces:**
- Consumes: yok.
- Produces:
  ```swift
  public enum FoundationModelsStatus: String, Sendable, CaseIterable {
      case unsupportedOS, available, appleIntelligenceNotEnabled, deviceNotEligible,
           modelNotReady, unavailableOther
      public static var current: FoundationModelsStatus { get }
      public static var isAvailable: Bool { get }
      public static var supportsTurkish: Bool { get }
      public var localizedDescription: String { get }
  }
  ```
  Plan 05 (Ayarlar > İzinler) `FoundationModelsStatus.current.localizedDescription` satırını gösterir; `isAvailable == false` iken AI önerileri gizlenir.

- [ ] **Step 1: Başarısız testi yaz**

`Tests/ShotcueNotesTests/FoundationModelsStatusTests.swift`:

```swift
import Foundation
import Testing
@testable import ShotcueNotes

@Suite("FoundationModelsStatus")
struct FoundationModelsStatusTests {
    @Test func currentStatusIsOneOfTheKnownCases() {
        #expect(FoundationModelsStatus.allCases.contains(FoundationModelsStatus.current))
    }

    @Test func availabilityFlagAgreesWithTheStatus() {
        #expect(FoundationModelsStatus.isAvailable == (FoundationModelsStatus.current == .available))
    }

    @Test func everyCaseHasTurkishCopy() {
        for status in FoundationModelsStatus.allCases {
            #expect(!status.localizedDescription.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Testin derlenmediğini gör**

Run: `make test FILTER=FoundationModelsStatus 2>&1 | grep -m1 "error:"`
Expected: `cannot find 'FoundationModelsStatus' in scope`.

- [ ] **Step 3: FoundationModelsStatus'u yaz**

`Sources/ShotcueNotes/FoundationModelsStatus.swift`:

```swift
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability of Apple's on-device LLM, for Ayarlar > İzinler (spec §6.6).
/// The `@Generable` title suggester itself is deferred: `FoundationModelsMacros` is not shipped
/// with Command Line Tools, so `@Generable`/`@Guide` cannot be compiled without Xcode.
public enum FoundationModelsStatus: String, Sendable, CaseIterable {
    case unsupportedOS
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unavailableOther

    public static var current: FoundationModelsStatus {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unavailableOther
        }
        #else
        return .unsupportedOS
        #endif
    }

    public static var isAvailable: Bool { current == .available }

    /// Turkish (`tr-Latn-TR`) arrived with Apple Intelligence in macOS 26.1.
    public static var supportsTurkish: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.supportedLanguages.contains {
            $0.maximalIdentifier.hasPrefix("tr")
        }
        #else
        return false
        #endif
    }

    /// Turkish copy for the settings row.
    public var localizedDescription: String {
        switch self {
        case .unsupportedOS: return "Bu macOS sürümünde yok"
        case .available: return "Hazır"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence kapalı"
        case .deviceNotEligible: return "Bu cihaz desteklemiyor"
        case .modelNotReady: return "Model indiriliyor"
        case .unavailableOther: return "Kullanılamıyor"
        }
    }
}
```

- [ ] **Step 4: Testlerin geçtiğini gör**

Run: `make test FILTER=FoundationModelsStatus 2>&1 | tail -3`
Expected: `Test run with 3 tests in 1 suite passed`. (Bu makinede `current == .appleIntelligenceNotEnabled`, `supportsTurkish == true`.)

- [ ] **Step 5: Erteleme kararını CLAUDE.md'ye ekle**

`CLAUDE.md` içindeki `## Forbidden APIs / patterns` bölümüne tek satır ekle (Plan 00'ın yazdığı listeye ilave; başka satıra dokunma):

```
- FoundationModels `@Generable` / `@Guide`: CLT has no FoundationModelsMacros plugin — availability reads only (ShotcueNotes/FoundationModelsStatus.swift).
```

- [ ] **Step 6: Commit**

```bash
make format && git add Sources/ShotcueNotes/FoundationModelsStatus.swift Tests/ShotcueNotesTests/FoundationModelsStatusTests.swift CLAUDE.md
git commit -m "feat(notes): report Foundation Models availability, defer @Generable suggester

@Generable/@Guide cannot compile with Command Line Tools: the FoundationModelsMacros
plugin is not shipped there (same class of failure as #Preview/PreviewsMacros).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Plan 03 tamamlanma ölçütü

- `make test FILTER=ShotcueNotesTests` → **36 test, 7 suite, hepsi yeşil**: `LevelMeter` 4, `AACWriter` 4, `EngineAudioRecorder` 4, `AudioDeviceCatalog` 3, `WhisperKitTranscriber` 7, `TranscriptionCoordinator` 11, `FoundationModelsStatus` 3. (`plugin for module 'TestingMacros' not found` çıkarsa tuzak #1: kaynağı değiştirmeden tekrar çalıştır.)
- `make test` → tüm paket yeşil; `Sources/ShotcueNotes/ShotcueNotes.swift` ve `Tests/ShotcueNotesTests/SmokeTests.swift` yer tutucuları silinmiş.
- `swift build 2>&1 | grep -c warning:` → `ShotcueNotes` kaynaklı uyarı yok (yalnızca `ld: warning: search path … not found` kabul edilir).
- `docs/superpowers/plans/spike-results.md` → `## S4 — WhisperKit Türkçe` bölümü doldurulmuş, iki modelin hız/kalite tablosu ve tek satır "Varsayılan model: …" kararı yazılı; `WhisperKitTranscriber.defaultModelName` bu karara eşit.
- `docs/superpowers/plans/spike-results.md` → `### Plan 03 manuel kayıt kontrolü` bölümünde 3 sn'lik gerçek kayıt (`afinfo`: AAC, 48000 Hz, 1 ch), `peak > 0`, cihaz değiştirme testi ve cihaz seçimi sonuçları yazılı.
- Üretilen public API, isim sözleşmesine birebir uyuyor: `EngineAudioRecorder(inputDeviceUID:)`, `AudioDeviceCatalog.inputDevices()`, `AACWriter(url:inputFormat:)`, `LevelMeter.rms(_:)`, `WhisperKitTranscriber(modelName:modelsDirectory:)`, `TranscriptionCoordinator(transcriber:taskRepository:fileStore:language:titleMaker:)`.
- `ShotcueNotes` yalnızca `Foundation`, `AVFoundation`, `CoreAudio`, `Accelerate`, `WhisperKit`, `ShotcueCore` ve `#if canImport(FoundationModels)` arkasında `FoundationModels` import ediyor: `grep -rhE '^import ' Sources/ShotcueNotes | sort -u` bu listeyi vermeli. `SFSpeechRecognizer`, `AVAudioSession`, `SpeechTranscriber`, `#Preview` geçmiyor: `grep -rE 'SFSpeechRecognizer|AVAudioSession|SpeechTranscriber|#Preview' Sources/ShotcueNotes` boş.
- `Package.swift` bu planda **değişmedi**: `git log --oneline -- Package.swift` son commit'i Plan 00'ın.
- Bundan sonra Plan 05 (UI) `AudioRecorder` + `Transcriber` + `TranscriptionQueue` protokolleri üzerinden hızlı paneli ve Ayarlar > Ses sekmesini bağlayabilir; Plan 06 (App) `AppEnvironment`'ta `EngineAudioRecorder`, `WhisperKitTranscriber` ve `TranscriptionCoordinator`'ı üretip açılışta `processPending()` çağırır.
