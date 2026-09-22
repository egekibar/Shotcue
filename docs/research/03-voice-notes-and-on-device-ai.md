# Tasker — Ses Notları, Speech-to-Text ve Cihaz İçi AI Araştırması

> Kapsam: ses kaydı, konuşma tanıma (STT), cihaz içi LLM yardımcıları (başlık/etiket/özet).
> Tarih: 2026-09-22 · Hedef: Swift 6 / SwiftUI, macOS 26+ (macOS 27 yol haritasıyla).
>
> **Bu rapordaki Apple API bulguları tahmin değil, bu makinede çalıştırılarak doğrulandı.**
> Test ortamı: macOS 26.6.2 (build 25G83), Apple Silicon, Swift 6.4, MacOSX.sdk 27.0
> (Command Line Tools). Locale listeleri, `AssetInventory` durumları ve Türkçe
> transkripsiyon çıktıları gerçek çalıştırma sonuçlarıdır.

---

## TL;DR

- **`SpeechTranscriber` (macOS 26'nın yeni, iyi modeli) TÜRKÇE DESTEKLEMİYOR.** Bu makinede
  `SpeechTranscriber.supportedLocales` **30 locale** döndü ve `tr-TR` listede **yok**
  (de/en/es/fr/it/ja/ko/pt/yue/zh varyantları). `AssetInventory.status` → `unsupported`.
- **TUZAK:** `SpeechTranscriber.supportedLocale(equivalentTo: Locale("tr-TR"))` **`tr-TR` döndürüyor**
  — yani "destekleniyor" gibi görünüyor ama desteklenmiyor. Apple bunu forumda Arapça için
  kabul etti. **Asla bu fonksiyonu destek kontrolü olarak kullanmayın**; `supportedLocales`
  üyeliğine veya `AssetInventory.status` sonucuna bakın.
- **Türkçe, `DictationTranscriber` ile VAR.** `DictationTranscriber.supportedLocales` **54 locale**
  döndürdü ve `tr-TR` içinde. Model indirildi (~5 dk), çalıştı, **6.6 sn sesi 0.39 sn'de**
  (~17x realtime) yazıya çevirdi. Ama bu eski Siri dikte modeli.
- **KRİTİK KALİTE SORUNU:** Türkçe dikte modeli saf Türkçeyi neredeyse kusursuz yazıyor, ama
  **İngilizce teknik terimleri sistematik olarak mahvediyor** — bizim kullanım senaryomuzun tam
  kalbi. Ölçtüğümüz gerçek çıktılar: `API endpoint'i` → **"yapı en Pointti"**, `cache'i` →
  **"caddeyi"**, `modal component'inin` → **"model kampın"**, `deploy` → **"diplo"**,
  `state` → **"transit"**, `refactor` → **"refahtor"**.
- **Custom language model kısmi çözüm.** `SFCustomLanguageModelData` + `DictationTranscriber`
  `.customizedLanguage` ile `deploy`, `state`, `mobile` düzeldi; ama `API endpoint`, `cache`,
  `modal component`, `dropdown` hâlâ bozuk, `refactor` daha da kötüleşti. **Yeterli değil.**
- **Karşılaştırma:** aynı cümlelerin İngilizcesi `SpeechTranscriber` (en-US) ile neredeyse
  kusursuz çıktı (sadece `cache` → `cash`). Yani sorun API'de değil, Türkçe modelinde.
- **Foundation Models TÜRKÇE DESTEKLİYOR.** `SystemLanguageModel.default.supportedLanguages`
  **23 dil** döndürdü ve **`tr-Latn-TR` listede**. (Apple Intelligence'a Türkçe macOS 26.1 ile
  geldi.) Başlık/etiket üretimi ve transkript temizliği için Türkçe kullanılabilir.
- **Claude API ses kabul etmiyor (2026).** Messages API metin + görsel alıyor, ses almıyor.
  Yani transkripsiyon bizim tarafımızda çözülmek zorunda; Claude'a metin gidecek.
- **Öneri:** birincil motor **WhisperKit (large-v3-turbo)**, Türkçe için Apple dikte modeli
  yerine. Apple `SpeechTranscriber` sadece `en-*` dikte için hızlı yol olarak, bulut
  (AssemblyAI / ElevenLabs) opsiyonel fallback.

---

## 1. macOS 26/27'de Ses Kaydı

### AVAudioRecorder vs AVAudioEngine

**`AVAudioEngine` + `installTap` tek doğru seçim** — ama sebebi metering değil, streaming.

- `AVAudioRecorder` macOS'ta metering'i **tam destekliyor** (`isMeteringEnabled`,
  `updateMeters()`, `averagePower(forChannel:)`, `peakPower(forChannel:)`, macOS 10.7+).
  Yani seviye çubuğu tek başına `AVAudioEngine` gerektirmiyor. Gerektiren şey **ham PCM
  buffer'ı canlı transcriber'a beslemek** — `AVAudioRecorder` dosya ve skaler güç değeri
  verir, buffer vermez.
- **Tek bus'a yalnızca tek tap kurulabilir** (Apple dokümantasyonu: *"You can install only
  one tap on any bus"*). Dolayısıyla üç tüketiciyi **aynı tap bloğunun içinde** çalıştırın:

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buf, _ in
    try? file.write(from: buf)                      // arşiv (AVAudioFile)
    let converted = try? converter.convert(buf)     // -> transcriber
    inputBuilder.yield(AnalyzerInput(buffer: converted!))
    meter.update(rms(buf))                          // waveform
}
```
  Blok **main thread'de çalışmayabilir**. `AVAudioRecorder` ile engine tap'ini iki ayrı
  mikrofon istemcisi olarak paralel çalıştırmayın — macOS'ta arbitrasyon yok, sessiz
  hatalara yol açıyor.
- `AVAudioSession` **iOS'a özeldir, macOS'ta yoktur.**
- **Büyük kısayol:** `SpeechAnalyzer` dosyayı doğrudan tüketebiliyor —
  `SpeechAnalyzer(inputAudioFile:modules:options:...)` / `start(inputAudioFile:finishAfterFile:)`
  (macOS 26). Canlı transkript şart değilse `AVAudioRecorder` (metering'li) + dosya tabanlı
  `SpeechAnalyzer` çok daha az kod ve aşağıdaki tap/format/rota sorunlarının hiçbirine
  maruz kalmıyor. **Bizim akışımızda canlı geri bildirim istediğimiz için engine'i seçiyoruz.**
### Format: arşiv vs analiz

İki ayrı format, iki ayrı iş:

- **Analiz:** `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` — **bu makinede
  ölçüldü: 16000 Hz / 1 kanal / `.pcmFormatInt16`**. Apple bu değeri dokümante etmiyor, bu
  yüzden **sabit yazmayın, runtime'da okuyun**. `considering naturalFormat:` varyantı
  donanıma yakın bir format seçmenizi sağlar; `SpeechModule.availableCompatibleAudioFormats`
  tüm kabul edilen formatları listeler (liste boşsa model indirilmemiş demektir).
- **Dönüşüm zorunlu ve hatası SESSİZ.** Apple: *"the analyzer does not transparently upsample,
  downsample, or convert audio input"* — uyumsuz buffer verirseniz derleme temiz, transkript
  **boş**, hata **yok**. `AVAudioConverter(from:to:)` + blok formlu
  `convert(to:error:withInputFrom:)` kullanın (sample rate değiştiği için frame sayıları farklı).
- **Arşiv:** AAC-LC `.m4a`, mono, 48 kHz, 64–96 kbps (Voice Memos'un yaptığı).
  `AVFormatIDKey: kAudioFormatMPEG4AAC`, `AVEncoderBitRateKey`, `AVNumberOfChannelsKey`.
  1 dakikalık not ≈ 500 KB. LPCM `.wav`/`.caf` ~15x yer kaplar ve algısal kazanç yok —
  sadece ileride farklı ASR modellerini aynı arşiv üzerinde tekrar çalıştıracaksanız mantıklı
  (ki bizde Whisper'a geçiş senaryosu var, dolayısıyla AAC'yi 16 kHz yerine **48 kHz mono**
  tutmak daha güvenli).

### Menü çubuğu uygulaması için gecikme optimizasyonu

```swift
let analyzer = SpeechAnalyzer(modules: [transcriber],
                              options: .init(priority: .high, modelRetention: .processLifetime))
try await analyzer.prepareToAnalyze(in: format)   // hotkey'e basılınca DEĞİL, açılışta
```

`prepareToAnalyze` *"reduce or eliminate delays in analyzing the first audio input"* diyor.
`ModelRetention` seçenekleri `.whileInUse` / `.lingering` / `.processLifetime` — sık sık
çağrılan bir menü çubuğu uygulamasında modeli sıcak tutmak için `.processLifetime`.
Ayrıca `SpeechDetector` (VAD, `SensitivityLevel`) modülünü ekleyip **sessizlikte otomatik
durdurma** yapabilirsiniz.

### Mikrofon izni (TCC)

| Gereken | Detay |
|---|---|
| `NSMicrophoneUsageDescription` | macOS 10.14+. Yoksa `requestAccess` **exception fırlatır**. |
| `com.apple.security.device.audio-input` | **Hardened Runtime** → Resource Access → Audio Input. |
| `com.apple.security.device.microphone` | **App Sandbox** kullanılıyorsa ayrıca gerekli. |
| `AVCaptureDevice.authorizationStatus(for: .audio)` / `requestAccess(for:)` | macOS 10.14+, async varyant var. |

**En sık yapılan hata:** Hardened Runtime altında `NSMicrophoneUsageDescription` **tek başına
yetmez**. İmzada `com.apple.security.device.audio-input` yoksa platform mikrofonu TCC'ye
sormadan reddeder — **hiç izin diyaloğu çıkmaz, sadece sıfır dolu sample gelir.** Kontrol:
`codesign -d --entitlements - /path/YourApp.app`. `NSSpeechRecognitionUsageDescription` **Apple sunucularına veri göndermeyi** kapsar ve
`SFSpeechRecognizer.requestAuthorization`'ı gate eder. `SpeechAnalyzer` cihaz içi olduğu için
gerekli olduğuna dair Apple dokümanı bulunamadı — **yalnızca `SFSpeechRecognizer` fallback'i
tutarsanız ekleyin.**

### Giriş cihazı seçimi

Sorun şu: `AVAudioEngine`'in `inputNode`'u *"communicate with the system's default input and
output devices."*

1. **Listele:** `AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
   mediaType: .audio, position: .unspecified).devices` → UI için `localizedName`,
   eşleme için `uniqueID` (= Core Audio UID). `devices` KVO ile izlenebilir (hot-plug).
2. **UID → `AudioDeviceID`:** `kAudioHardwarePropertyTranslateUIDToDevice`.
3. **Engine'e uygula** (`engine.start()` ÖNCESİ):

```swift
let inputNode = engine.inputNode              // önce buna dokunun, I/O unit lazy yaratılıyor
guard let au = inputNode.audioUnit else { return }
var devID: AudioDeviceID = selectedDeviceID
AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global, 0, &devID,
                     UInt32(MemoryLayout<AudioDeviceID>.size))
```

Tipli alternatif `inputNode.auAudioUnit.setDeviceID(_:)` (macOS'a özel) de var.

**Üç uyarı:** (1) `AVAudioEngine` giriş ve çıkış için **tek bir HAL cihazı** kullanır —
girişi değiştirmek çıkışı da taşır; ayrı tutmak için aggregate device gerekir.
(2) **Swift 6 notu:** thread-safe `withAudioUnit(_:)` / `withAUAudioUnit(_:)` erişimcileri
**macOS 27**'de geliyor; macOS 26'da çıplak `audioUnit` / `auAudioUnit` kullanmak zorundasınız.

### Bluetooth / AirPods

- **Bozulma hâlâ gerçek.** Bluetooth mikrofon devreye girince macOS cihazı çift yönlü
  düşük kaliteli moda (HFP) alır; **çıkış kalitesi de düşer**. AirPods giriş alt-cihazı
  16 kHz; girişe dokunulduğu an her şey 16 kHz mono'ya kilitlenir. H1/H2 çipin Core Audio
  katmanında ayrıcalığı yok.
- **WWDC25'in "studio-quality AirPods recording" özelliği native macOS'ta YOK.**
  `AVAudioSession.CategoryOptions.bluetoothHighQualityRecording` ve
  `AVCaptureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording`
  **iOS 26 / iPadOS 26 / Mac Catalyst 26** — macOS listede yok. Native SwiftUI macOS
  uygulamasının bu özelliğe **desteklenen bir API'si yok.** (Ayrıca AB'de kapalı.)
- **`AVAudioEngineConfigurationChange`** (macOS 10.10+). Apple'ın kendi metni:
  *"the audio engine **stops, uninitializes itself**, and issues this notification… The app
  must reestablish connections"* ve *"**Don't deallocate the engine from within the client's
  notification handler.** The callback happens on an internal dispatch queue and can deadlock."*

  Reçete: internal queue'dan çık → `removeTap(onBus: 0)` → `inputNode.inputFormat(forBus: 0)`'ı
  **yeniden oku** → `AVAudioConverter`'ı yeniden kur → tap'i yeniden kur →
  **`engine.start()`'ı tekrar çağır.** Restart'ı unutmak klasik hata: kayıt sessizce ölür,
  crash da hata da yok. Bildirim **neyin değiştiğini söylemez**.
- **0 Hz formatına karşı koruyun.** Cihaz değişince veya son giriş cihazı çıkarılınca
  `inputNode` formatı 0 Hz / 0 kanal dönebilir; bu formatla tap kurmak **çökertir**.
  `format.sampleRate > 0 && format.channelCount > 0` kontrolü şart.

### Push-to-talk vs toggle

| Uygulama | Varsayılan | Modlar |
|---|---|---|
| Wispr Flow | `Fn` | Basılı tut = PTT varsayılan; çift tık = hands-free |
| Superwhisper | kullanıcı seçer | Toggle + PTT; **"kısa dokunuş toggle gibi davranır"** |
| VoiceInk | kullanıcı seçer | **Dört mod:** Toggle, PTT, Hybrid, Double Tap |
| macOS Dictation | çift `Fn` | **Toggle** — basılı tutma Siri'ye ayrılmış |

VoiceInk'in gerçek sabitleri (`RecordingShortcutManager.swift`):
`hybridPressThreshold = 0.5` (≥500 ms basılı = PTT, kısa = toggle),
`doubleTapThreshold = 0.7`, `shortcutPressCooldown = 0.5`.
**Bizim için: hybrid mod, 500 ms eşik** — 400 ms değil.

**Hotkey API seçimi:** Carbon `RegisterEventHotKey` **hiç TCC izni istemez** ve
`kEventHotKeyReleased` verir (yani hold süresi ölçülebilir) — ama **çıplak modifier tuşu
(Fn) kaydedemez.** Fn gibi bir tuşu yakalamak için `CGEvent.tapCreate` ile `.flagsChanged`
gerekir; bu da **Input Monitoring** (`CGRequestListenEventAccess()`), olayı yutacaksanız
ayrıca **Accessibility** izni ister. Hazır paketler (ikisi de Carbon sarmalıyor, ikisi de
key-up veriyor): [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
(MIT, `onKeyUp(for:)` var, "izin diyaloğu yok") ve
[soffes/HotKey](https://github.com/soffes/HotKey) (MIT, `keyUpHandler`).
**Öneri: normal bir kısayol (örn. `⌥Space`) + KeyboardShortcuts ile başlayın**, Fn desteğini
sonraya bırakın. (Apple'ın `PushToTalk` framework'ü alakasız — iOS telsiz API'si.)

## 2. Yeni Speech API'leri (macOS 26+) ve Türkçe Durumu

### Mimari

`SpeechAnalyzer` bir oturum yöneticisi; içine **modüller** eklenir: `SpeechTranscriber`,
`DictationTranscriber`, `SpeechDetector` (VAD). Ses buffer'ları `AnalyzerInput` olarak
`AsyncSequence` üzerinden verilir, sonuçlar `transcriber.results` `AsyncSequence`'ından
`AttributedString` olarak döner. Her şey **ses zaman çizelgesindeki `CMTime`'lara** bağlıdır.

### Türkçe: ölçüm sonuçları

Bu makinede çalıştırılan kod ve tam çıktılar:

| API | Locale sayısı | `tr-TR` var mı? |
|---|---|---|
| `SpeechTranscriber.supportedLocales` | 30 | **HAYIR** |
| `SpeechTranscriber.installedLocales` | 9 (hepsi `en-*`) | hayır |
| `DictationTranscriber.supportedLocales` | 54 | **EVET** |
| `SFSpeechRecognizer.supportedLocales()` | 63 | **EVET** |

```
AssetInventory.status(SpeechTranscriber  tr-TR) → unsupported
AssetInventory.status(DictationTranscriber tr-TR) → supported → (indirildi) → installed
SpeechTranscriber.supportedLocale(equivalentTo: tr-TR) → tr-TR   ← YANILTICI
```

`supportedLocale(equivalentTo:)`'nin yalan söylemesi bilinen bir hata: Apple forum yanıtında
"`SpeechTranscriber` Arapçayı yanlışlıkla 'destekleniyor' olarak listeledi, aslında desteklemiyordu"
deniyor. Sonuç: `assetInstallationRequest` **non-nil** dönüyor, indirme deneniyor ve
*"asset not found after attempted download"* hatasıyla patlıyor. Bizim testimizde de
`assetInstallationRequest(supporting: [SpeechTranscriber(tr-TR)])` non-nil döndü — yani aynı tuzak.

**Doğru kontrol:**
```swift
let ok = await SpeechTranscriber.supportedLocales
    .contains { $0.identifier(.bcp47) == "tr-TR" }   // false
```

### Türkçe transkripsiyon kalitesi (gerçek çıktılar)

`say -v Yelda` ile üretilmiş temiz sentetik ses (gerçek mikrofon daha kötü olur):

| Girdi | `DictationTranscriber` tr-TR çıktısı |
|---|---|
| Login ekranındaki butonun rengini değiştir ve **modal** açıldığında **API'den** gelen hata mesajını göster | Login ekranındaki butonun rengini değiştir ve **moda** açıldığında **kapıdan** gelen hata mesajını göster |
| Dashboard sayfasındaki **API endpoint'i deploy** ettikten sonra **cache'i** temizle | Dashboard sayfasındaki **yapı en Pointti diplo** ettikten sonra **caddeyi** temizle |
| Bu **modal component'inin state** yönetimini **refactor** etmemiz lazım | Bu **model kampın transit** yönetimini **refahtor** etmemiz lazım |
| **Sidebar'daki dropdown** menüsü **mobile** görünümde bozuluyor, **responsive fix** gerekiyor | **Side bar'daki dropların** menüsü **mobil** görünümde bozuluyor **Responsive Fix** gerekiyor |

Saf Türkçe kısımlar **kusursuz**. İngilizce teknik terimler **sistematik olarak yanlış**.
Hız: 4–6 sn ses için 0.38–0.70 sn (≈10–17x realtime) — hız sorun değil, **kalite sorun**.

Kıyas için `SpeechTranscriber` (en-US, iyi model) aynı cümlenin İngilizcesinde:
> "Fix the drop-down menu in the sidebar. It breaks on mobile and clear the **cash** after
> deploying the API endpoint." — tek hata, üstelik noktalama otomatik eklendi.

### Custom language model denemesi

`SFCustomLanguageModelData` (tr-TR) + 13 dev-jargon kalıbı → `export(to:)` (15 KB) →
`SFSpeechLanguageModel.prepareCustomLanguageModel` (7.5 MB derlenmiş) →
`DictationTranscriber(contentHints: [.customizedLanguage(modelConfiguration: cfg)])`:

- **Düzeldi:** `diplo`→`deploy`, `transit`→`state`, `mobil`→`mobile`
- **Düzelmedi:** `API endpoint'i`→`yapı en Pointti`, `cache'i`→`caddeyi`,
  `modal component'inin`→`model kampın`, `dropdown`→`dropların`
- **Kötüleşti:** `refahtor etmemiz` → `Reface öğretmemiz`

**Sonuç: custom LM tek başına bu işi kurtarmıyor.** (macOS 26 ile gelen `weight` parametresi
0.0–1.0 arası ayarlanabilir, denenmeye değer ama beklentiyi yüksek tutmayın.)

### AssetInventory — API değişikliği uyarısı

WWDC25 oturumundaki ve birçok blog yazısındaki `AssetInventory.allocatedLocales` /
`deallocate(locale:)` **çıkan SDK'da yok.** Gerçek API:

```swift
AssetInventory.maximumReservedLocales        // bu makinede: 5
AssetInventory.reservedLocales               // [Locale]
try await AssetInventory.reserve(locale:)    // -> Bool
await AssetInventory.release(reservedLocale:) // -> Bool
```

Ayrıca `SpeechModels.endRetention()` var. Modeller **sistem deposunda** tutulur; uygulama
boyutunu ve RAM'ini artırmaz, güncellemeleri sistem yapar. İlk indirme testimizde **~5 dakika**
sürdü — ilk çalıştırma UX'inde bunu göz ardı etmeyin.

**Kaynaklar:** [WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/) ·
[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) ·
[Apple sample](https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app) ·
[Forum: asset not found](https://developer.apple.com/forums/thread/797835)

---

## 3. Legacy `SFSpeechRecognizer`

Ölçüm: `SFSpeechRecognizer(locale: "tr-TR")` oluşturuldu, **`isAvailable = true`**,
**`supportsOnDeviceRecognition = true`**. Yani Türkçe cihaz içi tanıma teknik olarak var —
ama bu **`DictationTranscriber` ile aynı model**, dolayısıyla yukarıdaki kalite sorunları aynen geçerli.

- **Deprecation:** macOS 27 SDK başlıklarında `SFSpeechRecognizer` **resmî olarak deprecate
  edilmemiş**. Sadece eski üyeler (`interactionIdentifier`, `SFSpeechLanguageModel`'in
  `clientIdentifier`'lı varyantı, `SFTranscription.speakingRate` vb.) deprecate.
- **Ama pratikte bozuk:** `SFSpeechURLRecognitionRequest`'in macOS 26'da **hata vermeden hiç
  başlamadığı** raporlanıyor — `recognitionTask(with:)` callback'i hiç tetiklenmiyor, 60 sn'lik
  ses için 120 sn sonunda %3 CPU'da sıfır sonuç. Dosyadan transkripsiyon için **kullanmayın**.
- **Limitler (server-based):** istek başına ~1 dk, günlük ~1000 istek. Cihaz içi modda yok.
- **Tek avantajı:** `contextualStrings` desteği — uzun formlu `SpeechTranscriber` modeli
  contextual strings almıyor. Ama bizde `DictationTranscriber` + custom LM aynı işi görüyor.

**Karar:** yeni kod yazmayın. macOS 26+ hedeflediğimiz için `DictationTranscriber` legacy
modele erişmenin desteklenen yoludur.

**Kaynak:** [transcribe-audio PR #1](https://github.com/djacobs/transcribe-audio/pull/1)

---

## 4. Whisper ve Diğer Alternatifler

### Claude API ses girişi — HAYIR (2026)

Anthropic Messages API **metin ve görsel** kabul ediyor, **ses kabul etmiyor**. OpenAI SDK
uyumluluk katmanında da ses girdisi yok sayılıp atılıyor. Açık feature request'ler mevcut
(anthropic-sdk-python #1198, claude-code #14444). Claude Code'un kendi dikte özelliği sesi
Anthropic sunucularına **transkripsiyon için** gönderiyor, ama bu API olarak dışarı açık değil.
**Tasarım sonucu: transkripsiyonu biz yapıp Claude'a metin göndereceğiz.** (İyi haber: metin
göndermek token açısından da ucuz ve transkripti kullanıcıya düzenletebiliyoruz.)

### Cihaz içi seçenekler

| Seçenek | Sürüm / Lisans | Türkçe | Not |
|---|---|---|---|
| **WhisperKit** (`argmaxinc/argmax-oss-swift`) | v1.1.0 (2026-08-06), MIT | **EVET** | Eski `argmaxinc/WhisperKit` URL'i buraya yönleniyor. Streaming, word timestamps, dil tespiti var. |
| whisper.cpp | v1.9.4 (2026-09-11), MIT | **EVET** | Core ML + Metal. **SPM paketi yok**; `whisper.spm` 2024'ten beri güncellenmemiş. Daha çok entegrasyon işi. |
| FluidAudio (Parakeet) | v0.16.1, Apache-2.0 | **HAYIR** | Parakeet TDT v3 = 25 Avrupa dili (bg,hr,cs,da,nl,en,et,fi,fr,de,el,hu,it,lv,lt,mt,pl,pt,ro,sk,sl,es,sv,ru,uk). **Türkçe yok.** Canary-1b-v2 de aynı liste. VAD/diarization parçaları yine de alınabilir. |
| mlx-swift Whisper | — | — | **Yok.** `mlx-swift-examples`'ta Whisper implementasyonu bulunmuyor; `mlx-audio` Python öncelikli ve SPM paketi değil. |
| Apple `DictationTranscriber` | sistem, ücretsiz | EVET ama zayıf | Bkz. bölüm 2. |
| sherpa-onnx | v1.13.8, Apache-2.0 | dolaylı | Swift API var ama Türkçe'ye özel model yok; Whisper çalıştırınca WhisperKit zaten daha iyi. |

**WhisperKit model boyutları** (HuggingFace tree API'den ölçülmüş):

| Model | Disk |
|---|---|
| `openai_whisper-base` | 147 MB |
| `openai_whisper-small` | 487 MB |
| `openai_whisper-large-v3-v20240930_626MB` | 627 MB (quantize) |
| `openai_whisper-large-v3-v20240930_turbo` | 1.64 GB |
| `distil-whisper_distil-large-v3_turbo` | 1.53 GB — **sadece İngilizce** |

**Whisper Türkçe WER** (Whisper makalesi arXiv 2212.04356, Tablo 11/13):

| Model | FLEURS tr | Common Voice 9 tr |
|---|---|---|
| small | 15.9 | 23.7 |
| medium | 10.4 | 17.7 |
| large-v2 | **8.4** | **14.5** |

large-v3 için Türkçe rakam yayınlanmadı; OpenAI genel olarak v2'ye göre %10–20 iyileşme
iddia ediyor. **Uyarı:** Argmax'ın kendi çok dilli benchmark setinde Türkçe yok, yani
**CoreML quantize edilmiş WhisperKit build'lerinin Türkçe WER'i ölçülmemiş.** 626 MB varyantı
kendi sesinizle large-v3-turbo'ya karşı test edin.

### Bulut seçenekleri (fallback)

| Sağlayıcı / model | Türkçe | Fiyat | Streaming | Not |
|---|---|---|---|---|
| **AssemblyAI Universal-3.5 Pro** | EVET + **native code-switching (18 dil, Türkçe dahil)** | $0.21/sa async, $0.45/sa realtime | evet (282 ms) | **Karışık dil için en iyisi.** Contextual prompting ile jargon verilebilir. |
| **ElevenLabs Scribe v2** | EVET (Scribe v1: FLEURS tr **%3.8**, CV tr %5.5) | $0.22/sa; realtime $0.39/sa (~150 ms) | evet | Keyterm prompting (+$0.05/sa) ile teknik terim sabitlenebilir. |
| **OpenAI `gpt-transcribe`** | EVET | **$0.0045/dk** (~$0.27/sa) | evet | LLM tabanlı çözümleme karışık dilde iyi; 25 MB dosya limiti. |
| Deepgram Nova-3 | EVET (tek dil) | ~$0.0043/dk | evet | **`multi` code-switch modunda Türkçe YOK** (10 dil: en,es,fr,de,hi,ru,pt,ja,it,nl). Bizim için elenir. |
| Groq whisper-large-v3-turbo | EVET | ~$0.04/sa | hayır | En ucuzu ama batch-only; fiyat birincil kaynaktan doğrulanamadı. |
| Google Chirp 3 | EVET (`tr-TR`) | $0.016/dk (log açık) / $0.024/dk (kapalı) | evet | Ucuz tarife veri loglamayı açıyor. |

Gizlilik notu: Deepgram'in listelenen fiyatları sizi **Model Improvement Program'a dahil
ediyor** (`mip_opt_out=true` gerekli); ElevenLabs Enterprise altı planlarda varsayılan olarak
eğitime açık. OpenAI'da varsayılan eğitim yok + ZDR mevcut.

---

## 5. Türkçe + İngilizce Karışık Dikte İçin Strateji

Ölçümlerin dayattığı sonuç net: **Apple'ın Türkçe dikte modeli bizim sözlüğümüz için yetersiz.**
Kullanıcı "modal", "API", "cache", "deploy", "dropdown" diyecek ve bunlar tam da bozulan kelimeler.

**Katmanlı plan:**

1. **Birincil: WhisperKit `large-v3-turbo`, `language: "tr"`.** Whisper web ölçeğinde
   kod-değiştirmeli (code-switched) metinle eğitildiği için Türkçe cümle içindeki İngilizce
   teknik terimleri Apple modelinden çok daha iyi tutuyor. Apple Silicon'da 1.64 GB, gerçek
   zamanlıdan 14–22x hızlı (üçüncü taraf ölçüm, doğrulanmadı).
2. **İngilizce notlar için hızlı yol:** kullanıcı dili `en` seçerse
   **`SpeechTranscriber` (en-US)** — bedava, sistem yönetimli, canlı volatile sonuç veriyor
   ve testimizde neredeyse kusursuzdu. Whisper'ı yüklemeye gerek yok.
3. **Fallback (opsiyonel, ayarlardan açılır):** **AssemblyAI Universal-3.5 Pro** — Türkçe'yi
   native code-switching listesinde tutan tek sağlayıcı; contextual prompting ile proje
   jargonu verilebilir. Alternatif: ElevenLabs Scribe v2.
4. **Acil durum fallback:** `DictationTranscriber` (tr-TR) — internet yok + Whisper modeli
   inmemişse. Kalite düşük ama "hiç yok"tan iyi, ve kullanıcı transkripti düzenleyebiliyor.

**Streaming vs batch.** Notlar 5–60 sn. Whisper **batch** çalışır (chunk'lı streaming
yapılabilir ama gecikme/kalite dengesi kötüleşir). Önerilen hibrit:

- Kayıt sırasında **`SpeechTranscriber` en-US veya `DictationTranscriber` tr-TR ile canlı
  volatile metin göster** — kullanıcı konuştuğunu görsün (psikolojik geri bildirim, "çalışıyor mu?"
  sorusunu öldürür). Bu metin **kaydedilmez**.
- Kayıt biter bitmez **WhisperKit'i tam ses dosyası üzerinde çalıştır**, sonucu gerçek transkript
  yap. 30 sn'lik not için beklenen süre ~2–4 sn.
- Whisper sonucu gelene kadar canlı metni "taslak" olarak göster, gelince **yumuşak geçişle
  değiştir**.

**İlk çalıştırma UX'i.** Whisper modeli 1.64 GB — uygulama ilk açılışta indirmemeli.
Onboarding'de "Türkçe ses notları için 1.6 GB model indirilecek" diye **açık onay** alın,
indirme arka planda ilerlesin, bu sırada `DictationTranscriber` ile çalışsın. Apple modelleri
için `AssetInventory` indirmesi bizim testte ~5 dk sürdü — progress bar şart
(`AssetInstallationRequest.progress` bir `Foundation.Progress`).

**Saklama şeması.** Transkripti sesin yanında, güven skoruyla birlikte tutun:

```
~/Library/Application Support/Tasker/notes/<uuid>/
  audio.m4a                 # AAC-LC 48 kHz mono, ~64 kbps
  transcript.json
```
```json
{
  "engine": "whisperkit/large-v3-turbo",
  "locale": "tr-TR",
  "text": "Login ekranındaki butonun rengini değiştir...",
  "editedByUser": false,
  "createdAt": "2026-09-22T17:40:00Z",
  "segments": [
    { "start": 0.0, "end": 2.4, "text": "Login ekranındaki butonun", "confidence": 0.91 }
  ]
}
```

`SpeechTranscriber`/`DictationTranscriber` kullanıldığında güven skoru için
`attributeOptions: [.transcriptionConfidence]`, zaman aralığı için `.audioTimeRange` ekleyin;
sonuçtaki `AttributedString`'in run'larından okunur. `editedByUser` alanı önemli: kullanıcı
düzelttiyse bir daha otomatik üzerine yazmayın.

---

## 6. Foundation Models (cihaz içi LLM)

### Türkçe: DESTEKLENİYOR

Bu makinede ölçüm — `SystemLanguageModel.default.supportedLanguages` **23 dil** döndürdü:

```
da-DK, de-DE, en-AU, en-GB, en-US, es-419, es-ES, es-US, fr-CA, fr-FR, it-IT,
ja-JP, ko-KR, nb-NO, nl-NL, pt-BR, pt-PT, sv-SE, tr-Latn-TR, vi-VN,
zh-Hans-CN, zh-Hant-HK, zh-Hant-TW
```

**`tr-Latn-TR` listede.** Apple Intelligence'a Türkçe macOS 26.1 ile eklendi. Yani
başlık üretme, etiket önerme ve transkript temizleme Türkçe yapılabilir.

**Ama:** bu makinede `SystemLanguageModel.default.availability` →
`unavailable(.appleIntelligenceNotEnabled)`. Yani **Apple Intelligence kapalıysa model yok.**
Uygulama bunu zarifçe karşılamalı:

```swift
switch SystemLanguageModel.default.availability {
case .available:                       // AI özelliklerini göster
case .unavailable(.appleIntelligenceNotEnabled):  // "Ayarlar'dan Apple Intelligence'ı açın"
case .unavailable(.deviceNotEligible):            // özelliği tamamen gizle
case .unavailable(.modelNotReady):                // "model indiriliyor", sonra tekrar dene
}
```

### Kapasite ve limitler

- **Context window: 4096 token** (macOS 26) — instructions + prompt + çıktı **toplamı**.
  Aşılırsa `GenerationError.exceededContextWindowSize`. 1 dakikalık bir not rahat sığar,
  ama çok turlu oturumda birikir; **her görev için yeni `LanguageModelSession` açın.**
- macOS **26.4**'ten itibaren `SystemLanguageModel.contextSize` ve `tokenCount(for:)` var —
  tahmin etmek yerine ölçün.
- `@Generable` + `@Guide` ile **yapılandırılmış çıktı** (guided generation) ve `Tool`
  protokolü ile araç çağırma destekleniyor. Bizim için `@Generable` tam isabet.

### Bizdeki kullanım alanları

```swift
@Generable
struct TaskDraft {
    @Guide(description: "En fazla 6 kelimelik, emir kipinde Türkçe başlık")
    var title: String
    @Guide(description: "Dikte metninden temizlenmiş, net görev tanımı")
    var summary: String
    @Guide(description: "1-3 adet kısa etiket", .count(1...3))
    var tags: [String]
}
```

1. **Otomatik başlık** — kütüphane penceresinde ekran görüntüsünü tanımlayan kısa başlık.
2. **Etiket/grup önerisi** — mevcut etiket listesini prompt'a verip sınıflandırma.
3. **Transkript temizleme** — "şey", "yani", tekrarları atma, noktalama düzeltme.
   **Dikkat:** modelden *teknik terimleri düzeltmesini* de isteyebilirsiniz
   ("caddeyi" → "cache'i"), ama bunu **yalnızca öneri** olarak gösterin; sessizce
   değiştirmek kullanıcının söylemediği bir şeyi yazmak demektir.

### macOS 27 / WWDC 2026 değişiklikleri (önemli)

SDK'da (MacOSX 27.0) ve WWDC26 oturumlarında doğrulandı:

- **`PrivateCloudComputeLanguageModel`** — yeni sunucu modeli, **32.000 token context**,
  `reasoningLevel` (light/deep) ayarlanabilir, `quotaUsage` ile kota takibi,
  `Availability.UnavailableReason` = `.deviceNotEligible` / `.systemNotReady`.
  **2M'den az ilk indirmesi olan geliştiriciler için ücretsiz.** API anahtarı yok, prompt'lar
  saklanmıyor.
- **Yeni cihaz içi model** — context **8192**'ye çıkıyor, görsel girdi (`Attachment`) desteği,
  daha iyi tool calling.
- **`LanguageModel` protokolü** — `LanguageModelSession`'ı herhangi bir model
  destekleyebiliyor. **Anthropic ve Google kendi frontier modelleri için Swift paketi
  yayınlıyor.** Yani `SystemLanguageModel` ↔ PCC ↔ **Claude** arasında tek argüman
  değiştirerek geçilebilecek. Bu, Tasker'ın Claude entegrasyonunu doğrudan ilgilendiriyor —
  ayrı bir HTTP katmanı yazmak yerine aynı Swift API'sinde kalınabilir.
- **Dynamic Profiles** — tek oturumda mod/araç/model değiştirme (agentic akışlar).
- Hazır sistem araçları: `OCRTool`, `BarcodeReaderTool`, **Spotlight tabanlı yerel RAG**.
- **`fm` CLI** (macOS 27) ve Python SDK; framework **açık kaynak** oluyor.

**Not:** macOS 27'nin `SpeechTranscriber`'a Türkçe eklediğine dair **hiçbir kanıt bulunamadı.**
Planı Türkçe gelecek varsayımına dayandırmayın; ama her açılışta `supportedLocales`'i runtime'da
kontrol edin ki geldiğinde otomatik kullanabilesiniz.

**Kaynaklar:** [WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/) ·
[WWDC26 319](https://developer.apple.com/videos/play/wwdc2026/319/) ·
[Apple Intelligence dilleri](https://support.apple.com/en-us/121115)

---

## 7. SwiftUI Canlı Transkripsiyon UI

### Preset kullanın, seçenekleri elle birleştirmeyin

Çoğu blog yazısında geçmiyor ama `SpeechTranscriber.Preset` tam bize göre:
**`.progressiveTranscription` = `.volatileResults` + `.fastResults`**, ve
**`.timeIndexedProgressiveTranscription`** buna `.audioTimeRange` ekliyor — yani dikte
konfigürasyonu hazır: `SpeechTranscriber(locale:preset:)`.

### Volatile vs finalized

```swift
for try await result in transcriber.results {
    let text = result.text          // AttributedString — DELTA DEĞİL, tam REPLACEMENT
    if result.isFinal {
        finalized += text
        volatile = AttributedString("")          // kuyruğu temizle, yoksa çiftlenir
    } else {
        volatile = text
        volatile.foregroundColor = .secondary    // veya italic
    }
}
```

`Text(finalized + volatile)` ile render edin — SwiftUI `Text` `AttributedString` alır,
kesinleşmiş ön ek sabit kalır, sadece kuyruk titrer.

İki ince nokta (Apple dokümantasyonundan):
- `result.text` **boş string** ise: o aralıkta tanınabilir konuşma yok **ve volatile aralıkta
  önceki sonuçlar geri alınmış** demektir. Bunu handle edin.
- `isFinal == false` için *"there is no guarantee that this result will be reissued with
  [isFinal] set to true"* — volatile metnin finalize olacağını **varsaymayın**.

Bitiriş: canlı akışta `finalizeAndFinishThroughEndOfInput()`, iptalde `cancelAndFinishNow()`.
`volatileRange` ve `setVolatileRangeChangedHandler(_:)` ile hangi zaman aralığının hâlâ
değişebileceğini okuyabilirsiniz.

### Waveform

**[dmrschmidt/DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage)** (MIT, macOS 12+,
aktif) — canlı kayıt için hazır SwiftUI API'si var:
`WaveformLiveCanvas(samples: [Float], shouldDrawSilencePadding: true)`. Tap içinde `vDSP_rmsqv` ile RMS hesaplayıp `[Float]`'a push edin.

### Klavye öncelikli akış

`Esc` iptal, `Enter` kaydet, `⌘Z` geri al. Kayıt bitince metin alanı `@FocusState` ile
otomatik odaklansın, imleç sonda olsun. Düzenlenen metni `editedByUser: true` işaretleyin.

### Açık kaynak örnekler (URL'ler doğrulandı)

| Proje | Lisans | Neden |
|---|---|---|
| [Apple — SwiftTranscriptionSampleApp](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app) | Apple sample | Kanonik referans: `SpeechAnalyzer` + `AVAudioEngine` + volatile/finalized + `AssetInventory`. **Buradan başlayın.** |
| [dayflower/LiveTranscriber](https://github.com/dayflower/LiveTranscriber) | MIT | **Bizim mimarimize en yakın: macOS menü çubuğu uygulaması.** `reportingOptions: [.volatileResults, .fastResults]`, volatile metni *italic + secondaryLabelColor* ile render ediyor. |
| [tornikegomareli/Talkify](https://github.com/tornikegomareli/Talkify) | MIT (555★) | En popüler macOS dikte referansı; actor tabanlı `ResultAccumulator` ve **birim testi** var. |
| [FluidInference/swift-scribe](https://github.com/FluidInference/swift-scribe) | MIT (316★) | `SpeechAnalyzer` + **Foundation Models ile özetleme** — bizim 2. ve 6. bölümün birleşimi çalışır halde. |
| [argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) | MIT | `AudioStreamTranscriber.swift` canlı Whisper akış deseni. |

**Dikkat:** `starmorph/swift-speech-analyzer` **mevcut değil** (404).
[Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) UI referansı olarak **uygun değil** —
Apple yolu `#if ENABLE_NATIVE_SPEECH_ANALYZER` arkasında kapalı ve dosya tabanlı (volatile yok);
ayrıca LICENSE dosyası GPLv3'ün sadece önsözü (GitHub `NOASSERTION` diyor). Ama **hotkey/PTT
mantığı için mükemmel referans** (bkz. bölüm 1).
`createwithswift.com` yazısının ses kurulumunu kopyalamayın — `AVAudioSession` kullanıyor, iOS'a özel.

## Öneri

### Karar tablosu

| Katman | Karar | Gerekçe |
|---|---|---|
| **Kayıt motoru** | `AVAudioEngine` + **tek** `installTap` | Bus başına tek tap; üç tüketici aynı blokta. `AVAudioRecorder` metering yapar ama PCM buffer vermez. |
| **Analiz formatı** | `bestAvailableAudioFormat` (ölçüldü: 16 kHz / mono / Int16) + `AVAudioConverter` | Analyzer **kendisi dönüştürmüyor**; uyumsuz buffer = sessizce boş transkript. Sabit yazmayın, runtime'da okuyun. |
| **Arşiv formatı** | AAC-LC `.m4a`, **48 kHz mono**, 64 kbps | Voice Memos deseni. 16 kHz'e indirmeyin: Whisper'a sonradan geçerken arşivi yeniden kullanacağız. 1 dk ≈ 500 KB. |
| **STT — Türkçe (birincil)** | **WhisperKit `large-v3-turbo`**, MIT | Apple'ın tr modeli İngilizce teknik terimleri bozuyor (ölçüldü). Whisper tr FLEURS ~%8.4 (large-v2). |
| **STT — İngilizce** | `SpeechTranscriber` (en-US) | Bedava, sistem yönetimli, canlı volatile, testte ~kusursuz. |
| **STT — fallback 1** | `DictationTranscriber` (tr-TR) | Offline, model inmemişken; kalite düşük ama anında. |
| **STT — fallback 2 (opsiyonel)** | AssemblyAI Universal-3.5 Pro | Türkçe'yi native code-switching listesinde tutan tek sağlayıcı; $0.21/sa. |
| **Kullanılmayacak** | Parakeet/FluidAudio ASR, Canary, distil-whisper, Deepgram `multi` | Hiçbiri Türkçe desteklemiyor (distil = sadece İngilizce). |
| **Cihaz içi LLM** | Foundation Models (`tr-Latn-TR` destekli) | Başlık, etiket, transkript temizliği. `availability` kontrolü şart. |
| **Claude'a gönderim** | Metin (ses değil) | Claude API 2026'da ses kabul etmiyor. |
| **Global hotkey** | `KeyboardShortcuts` (Carbon), hybrid mod **500 ms** eşik | TCC izni istemez ve key-up verir. Çıplak `Fn` istenirse `CGEventTap` + Input Monitoring gerekir. |
| **Waveform** | `DSWaveformImage` → `WaveformLiveCanvas` | MIT, macOS 12+, canlı `[Float]` akışı için hazır. |
| **Başlangıç kodu** | Apple `SwiftTranscriptionSampleApp` + `dayflower/LiveTranscriber` | İkincisi zaten macOS **menü çubuğu** uygulaması. |
| **macOS 27 hazırlığı** | `LanguageModel` protokolü | Anthropic Swift paketiyle aynı API'de on-device ↔ Claude geçişi. |

### Çekirdek transkripsiyon çağrısı

```swift
import Speech
import AVFoundation

@available(macOS 26.0, *)
actor LiveTranscriber {
    private let analyzer: SpeechAnalyzer
    private let transcriber: any SpeechModule & LocaleDependentSpeechModule
    private let format: AVAudioFormat
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Türkçe için SpeechTranscriber YOK — üyelik kontrolü şart.
    /// supportedLocale(equivalentTo:) YALAN SÖYLÜYOR, kullanmayın.
    static func module(for locale: Locale) async throws -> any SpeechModule {
        let tag = locale.identifier(.bcp47)
        if await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == tag }) {
            // .timeIndexedProgressiveTranscription = volatileResults + fastResults + audioTimeRange
            return SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        }
        // tr-TR buraya düşer
        return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }

    static func ensureModel(for module: any SpeechModule) async throws {
        guard await AssetInventory.status(forModules: [module]) != .unsupported else {
            throw TranscriptionError.localeUnsupported
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()   // request.progress -> UI
        }
    }

    /// Mikrofon tap'inden gelen her buffer'ı besleyin.
    func feed(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) throws {
        let out = AVAudioPCMBuffer(pcmFormat: format,
                                   frameCapacity: AVAudioFrameCount(buffer.frameLength))!
        var error: NSError?
        var sent = false
        converter.convert(to: out, error: &error) { _, status -> AVAudioBuffer? in
            if sent { status.pointee = .endOfStream; return nil }
            sent = true; status.pointee = .haveData; return buffer
        }
        if let error { throw error }
        continuation?.yield(AnalyzerInput(buffer: out))
    }

    /// Uygulama AÇILIŞINDA çağırın, hotkey'e basılınca değil.
    func warmUp() async throws {
        // SpeechAnalyzer(modules:options:) -> Options(priority:modelRetention:)
        // .processLifetime modeli menü çubuğu uygulaması boyunca sıcak tutar.
        try await analyzer.prepareToAnalyze(in: format)
    }

    func finish() async throws {
        continuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}
```

> **Uyarı (ölçüldü):** bir transcriber modülünü **ikinci bir `SpeechAnalyzer` oturumunda
> tekrar kullanmayın** — süreç `SIGTRAP` ile çöküyor. Her kayıt için yeni modül örneği yaratın.

### Sonraki adım

Karar vermeden önce **kendi sesinizle** 20–30 saniyelik 5 gerçek Türkçe görev notu kaydedip
WhisperKit `large-v3-turbo` ve `large-v3_626MB` varyantlarını karşılaştırın. Quantize edilmiş
build'in Türkçe WER'i kimse tarafından yayınlanmamış durumda ve bu, 1.64 GB ile 627 MB arasında
seçim yapmanın tek dürüst yolu.

---

## Doğrulama notu

Bu makinede derlenip çalıştırılan Swift probe'ları: locale listeleri (3 API),
`AssetInventory` durum/rezervasyon, `SystemLanguageModel.supportedLanguages`,
`bestAvailableAudioFormat`, tr-TR model indirmesi, `say -v Yelda` ile 4 Türkçe cümlenin
transkripsiyonu, custom LM derlenip karşılaştırılması, ve en-US kıyas testi.

**Yan etki:** test sırasında `tr-TR` dikte modeli sistem deposuna kuruldu ve `tr-TR`
locale rezervasyonu alındı (`AssetInventory.reservedLocales`). İstenirse
`AssetInventory.release(reservedLocale:)` ile bırakılabilir.
