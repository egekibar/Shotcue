# Tasker — Ekran Yakalama, Bölge Seçimi, İzinler ve Global Kısayollar

**Tarih:** 2026-09-22 · **Kapsam:** capture API, region selection UX, TCC izinleri, global hotkey, post-capture panel, görsel işleme
**Doğrulama ortamı:** macOS 26.6.2 (build 25G83), Apple Silicon, Swift 6.4, Command Line Tools **MacOSX.sdk = 27.0**, Xcode kurulu değil.
Aşağıdaki API imzalarının bir kısmı web'den değil, doğrudan bu makinedeki SDK header'larından ve `codesign` çıktısından doğrulanmıştır.

---

## TL;DR

- **ScreenCaptureKit tek geçerli yol.** `CGWindowListCreateImage` ve `CGDisplayCreateImage` artık *deprecated* değil, **obsoleted**: SDK'da `SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0)` / `(10.6,14.4,15.0)` makrosuyla işaretli; deployment target macOS 15+ ise **derlenmiyor bile**.
- **macOS 26 ile ekran görüntüsü API'si baştan yazıldı:** `SCScreenshotConfiguration` + `SCScreenshotOutput` + `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)` / `captureScreenshot(rect:configuration:)`. HDR/SDR ayrı çıktı, doğrudan dosyaya yazma (`fileURL` + `contentType`: png/jpeg/heic) desteği var.
- **macOS 27 SDK'da screenshot tarafında yeni bir şey yok.** 27.0 işaretli tüm eklemeler stream/recording tarafında (`SCClipBufferingOutput`, `SCRecordingEditor`, `SCStream.isCapturing`, ...). Yani macOS 26 API'si bizim için son durum.
- **Çok monitörlü bölge yakalama için en kısa yol `SCScreenshotManager.captureImage(in:)`** (macOS 15.2+, "display agnostic"), ama kendi overlay'imizi hariç tutamıyor. Filtreli yol (`SCContentFilter` + `sourceRect`) daha kontrollü.
- **`/usr/sbin/screencapture -i -s` çağıran uygulamanın Screen Recording iznini ister.** Bunu tahmin etmedim: binary'de `com.apple.private.tcc.check-allow-on-responsible-process = [kTCCServiceMicrophone, kTCCServiceScreenCapture]` entitlement'ı var, yani TCC kontrolü **responsible process** (yani Tasker.app) üzerinden yapılıyor. İptal tespiti: `exit status 1` + boş stderr.
- **Global hotkey için `sindresorhus/KeyboardShortcuts` (v3.1.0, MIT).** Altında Carbon `RegisterEventHotKey` var, **hiçbir TCC izni istemiyor**, sandbox + MAS uyumlu, SwiftUI `Recorder` view'ı hazır. `NSEvent.addGlobalMonitorForEvents(.keyDown)` Accessibility, `CGEvent.tapCreate` Input Monitoring ister — ikisi de gereksiz.
- **Ad-hoc imza TCC'yi her build'de sıfırlar** (designated requirement = cdhash). Ayrıca macOS 26.1'de `.app` bundle'ı olmayan çıplak executable'lar Privacy panelinde **hiç görünmüyor** (Apple DTS: bug). Dev döngüsü için `.app` bundle + stabil self-signed sertifika şart.
- **Claude'a gönderirken 1568px artık tek doğru değil:** Claude 4.7 ve sonrası "high-resolution tier" (uzun kenar 2576px / 4784 visual token), diğerleri 1568px / 1568 token. Token maliyeti `⌈w/28⌉ × ⌈h/28⌉`.

---

## 1. Capture API: ScreenCaptureKit (macOS 26/27)

### 1.1 Mevcut yüzey (SDK'dan doğrulandı)

`SCScreenshotManager` (macOS 14.0+) sınıf metodları:

| Metot | Availability | Not |
|---|---|---|
| `captureImage(contentFilter:configuration:)` | macOS 14.0 | `SCStreamConfiguration` alır, `CGImage` döner |
| `captureSampleBuffer(contentFilter:configuration:)` | macOS 14.0 | `CMSampleBuffer` |
| `captureImage(in: CGRect)` | **macOS 15.2** | Header: *"display agnostic and supports multiple displays"* — filtre yok |
| `captureScreenshot(contentFilter:configuration:)` | **macOS 26.0** | `SCScreenshotConfiguration` → `SCScreenshotOutput` |
| `captureScreenshot(rect:configuration:)` | **macOS 26.0** | Rect + yeni config |

`SCScreenshotConfiguration` (macOS 26.0, `NS_SWIFT_SENDABLE`) özellikleri: `width`/`height` (**piksel**), `showsCursor`, `sourceRect` (**nokta**, display'in logical koordinat sistemi), `destinationRect` (**piksel**), `ignoreShadows`, `ignoreClipping`, `includeChildWindows`, `displayIntent` (`.canonical` / `.local`), `dynamicRange` (`.sdr` / `.hdr` / `.bothSDRAndHDR`), `contentType: UTType`, `fileURL: URL?`, `static supportedContentTypes` (header: *"heic, jpeg, and png"*).

`SCScreenshotOutput`: `sdrImage` (display color space), `hdrImage` (extended sRGB), `fileURL`.

> **Swift köprüleme tuzağı (yerel derleyerek doğrulandı):** `contentType` header'da `UTType *` (Objective-C sınıf pointer'ı) olduğu için Swift'te `UTType` struct'ına değil **`UTTypeReference`**'a köprülenir. `config.contentType = .png` derlenmez; `config.contentType = UTType.png as UTTypeReference` yazmak gerekir.

**Neden önemli:** `fileURL` + `contentType` ile SCK dosyayı kendisi yazıyor — bizim `NSBitmapImageRep` → PNG encode adımımızı ortadan kaldırıyor.

### 1.2 macOS 27'de yeni ne var?

Yerel SDK 27.0 header'larında `API_AVAILABLE(macos(27.0))` işaretli 14 sembol var; **hiçbiri screenshot ile ilgili değil**: `SCClipBufferingOutput`, `SCRecordingEditor`, `SCStream.isCapturing`, `SCStreamFrameInfoVideoOrientation`, `SCContentFilter.isMicrophoneEnabled`, `SCContentSharingPicker.isAvailable`, `SCRecordingOutput.mixesAudioWithMicrophone`, `SCStreamErrorInsufficientStorage`, `SCStreamErrorNotSupported`. Tasker için çıkarım: **macOS 26 API'sini hedefleyin, 27 için ek iş yok.**

### 1.3 Retina / ölçek

SCK piksel cinsinden çalışır. Doğru kalıp (better-shot ve Capso ikisi de bunu kullanıyor):

```
config.width  = Int(contentRect.width  * CGFloat(filter.pointPixelScale))
config.height = Int(contentRect.height * CGFloat(filter.pointPixelScale))
config.captureResolution = .best
```

`SCContentFilter.pointPixelScale` (macOS 14+) ve `SCContentFilter.contentRect` bunun için var; `NSScreen.backingScaleFactor` yerine bunları kullanın — mixed-DPI setup'larda tek doğru kaynak.

### 1.4 Çok monitör + koordinatlar

- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` → `displays: [SCDisplay]`, her biri `displayID` ve `frame` (CoreGraphics global space, **sol-üst orijin**).
- `NSScreen` ↔ `SCDisplay` eşlemesi: `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID`.
- **Kritik tuzak:** `SCStreamConfiguration.sourceRect` / `SCScreenshotConfiguration.sourceRect`, content filter'ın **LOCAL** koordinat uzayındadır — display'in sol-üst köşesi `(0,0)`. Global rect'i display frame'inin origin'i kadar ötelemek gerekir. Capso'nun koduna bu tam olarak yorum satırı olarak düşülmüş.
- AppKit (sol-**alt** orijin, global origin = ana ekranın sol-alt köşesi) → CG (sol-üst): `cgY = primaryDisplayHeight - appKitRect.maxY`.

### 1.5 HDR / color space

- macOS 15+: `SCStreamConfiguration.captureDynamicRange`, `colorSpaceName`, `SCStreamConfigurationPreset`.
- macOS 26+: `SCScreenshotConfiguration.dynamicRange` ile SDR/HDR/ikisi birden; `displayIntent` `.canonical` (referans render) vs `.local` (o ekrana göre).
- **Tasker için öneri:** `.sdr` + display color space. Claude'a giden görselde HDR'ın faydası yok, dosya boyutunu ve uyumsuzluk riskini artırır.

### 1.6 Ölenler

| API | Durum (SDK 27.0) |
|---|---|
| `CGWindowListCreateImage`, `CGWindowListCreateImageFromArray` | introduced 10.5, **deprecated 14.0, obsoleted 15.0** |
| `CGDisplayCreateImage`, `CGDisplayCreateImageForRect` | introduced 10.6, **deprecated 14.4, obsoleted 15.0** |
| `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess` | macOS 10.15+, **hâlâ geçerli, deprecate edilmedi** |

Makro mesajı birebir: `"Please use ScreenCaptureKit instead."`

**Kaynaklar:** [SCScreenshotConfiguration](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration) · [SCScreenshotOutput](https://developer.apple.com/documentation/screencapturekit/scscreenshotoutput) · [captureImage(in:)](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(in:completionhandler:)) · [macOS 26 SCK API diff](https://github.com/dotnet/macios/wiki/ScreenCaptureKit-macOS-xcode26.0-b1) · [MacPorts #71136 (obsoleted)](https://trac.macports.org/ticket/71136) · [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos)

---

## 2. Alternatif: `/usr/sbin/screencapture`

### 2.1 İlgili bayraklar (yerel `screencapture` usage çıktısı)

`-i` interaktif seçim · `-s` sadece mouse selection (pencere modunu kapatır) · `-x` ses çalma · `-c` clipboard'a · `-t<format>` png/jpg/pdf/tiff · `-R<x,y,w,h>` rect ile doğrudan · `-D<n>` hedef display (1=main) · `-J selection|window|video` başlangıç modu · `-U` interaktif toolbar · `-o` pencere gölgesi yok · `-r` dpi metadata ekleme · `-T<sn>` gecikme · `-B<bundleid>` sonucu o uygulamada aç.

Interaktif modda kullanıcı: `space` = mouse/pencere modu, `control` = clipboard'a al, `escape` = iptal.

### 2.2 TCC davranışı — kesin cevap

`codesign -d --entitlements - /usr/sbin/screencapture` çıktısı:

```
[Key] com.apple.private.screencapturekit                       -> true
[Key] com.apple.private.tcc.check-allow-on-responsible-process -> [kTCCServiceMicrophone, kTCCServiceScreenCapture]
```

Yani **`screencapture` kendi izniyle çalışmıyor; TCC kontrolünü "responsible process" üzerinden yapıyor.** Tasker.app'ten `Process` ile spawn edildiğinde responsible process Tasker.app olur → **Tasker.app'in Screen & System Audio Recording izni gerekir**, prompt da Tasker.app adına çıkar. Terminal/LaunchAgent gibi izni olmayan bir parent'tan çağrıldığında sessizce başarısız olur ([openclaw#14138](https://github.com/openclaw/openclaw/issues/14138)).

Ad-hoc imzalı SwiftPM build'inden spawn etmek çalışır — **ama sadece o `.app` bundle'ına izin verilmişse ve cdhash değişmemişse** (bkz. §4).

### 2.3 İptal tespiti

Doğrulanmış kalıp (better-shot `ScreenCapture.validateCommandResult`):

- `status == 0` → başarı
- `status == 1` **ve stderr boş** → kullanıcı ESC'ledi (iptal, hata değil)
- diğer her şey → gerçek hata, kullanıcıya göster

### 2.4 Artı / eksi

| Artı | Eksi |
|---|---|
| Sistemin kendi seçim UI'ı: loupe/magnifier, piksel koordinat etiketi, space ile pencere modu, ok tuşlarıyla nudge, Option/Shift modifier'ları — hepsi bedava | Görünüm/branding kontrolü yok, CleanShot benzeri bir his vermiyor |
| Retina, HDR, dpi metadata, çok monitör davranışı zaten doğru | **Seçilen rect'i geri alamıyorsunuz** (sadece görüntü) → "son bölgeyi tekrarla" gibi özellikler için ayrı iş |
| Sıfır overlay kodu, sıfır koordinat bug'ı | Process spawn gecikmesi (~100-250 ms) |
| macOS 26'da en stabil yol | **App Sandbox'ta çalışmaz** (harici executable spawn edilemez) |
| | Yakalama anında kendi quick-action panelimizi araya sokamayız |

### 2.5 Karar: hibrit

**Faz 1 (MVP):** `screencapture -i -s -x -t png <path>` → kaydet → kendi quick-action panelimizi göster. Bir haftalık iş yerine bir günlük iş.
**Faz 2:** Kendi overlay'imiz + `SCScreenshotManager` (rect'i biliyoruz → "son bölgeyi tekrarla", magnifier, anlık boyut etiketi, doğrudan panel'e geçiş).

Bu tam olarak **better-shot**'ın (2.3k ★) yaptığı şey: fullscreen ve region için `screencapture`, pencere yakalama için SCK. Kodda şu yorum var: *"The command-line window path can fail to start its capture stream on macOS 26."*

---

## 3. Custom region-selection overlay

### 3.1 Doğrulanmış pencere reçetesi

Capso'nun `CaptureOverlayWindow.swift` dosyasından (birebir):

```swift
super.init(contentRect: screen.frame,
           styleMask: [.borderless, .nonactivatingPanel],
           backing: .buffered, defer: false)
self.level = .screenSaver
self.isOpaque = false
self.backgroundColor = .clear
self.hasShadow = false
self.ignoresMouseEvents = false
self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
self.isMovable = false
self.acceptsMouseMovedEvents = true
self.hidesOnDeactivate = false
override var canBecomeKey: Bool { true }
```

- **Her `NSScreen` için bir panel** (`screen.frame` ile), hepsi aynı seçim state'ini paylaşır.
- `acceptsMouseMovedEvents = true` olmadan crosshair + canlı boyut etiketi çalışmaz.
- `canBecomeKey` override'ı olmadan ESC/ok tuşları gelmez (borderless pencere varsayılanda key olamaz).
- Capso ayrıca `_setPreventsActivation:` private selector'ını `responds(to:)` ile korumalı çağırıyor — uygulamanın öne gelmesini engellemek için. **Private API, MAS'a gidecekseniz kullanmayın.**
- Cursor: `NSCursor.crosshair.set()` + `NSTrackingArea(.cursorUpdate)` ya da `window.invalidateCursorRects(for:)`.
- Dimming: tüm ekranı `NSColor.black.withAlphaComponent(0.35)` ile doldurup seçim rect'ini `NSGraphicsContext` içinde `.clear` compositing ile "delmek" (`rect.fill(using: .clear)`).

### 3.2 Overlay'i yakalamadan gizlemek — iki yöntem

1. **Filtre ile hariç tutma (tercih edilen):** overlay pencerelerine `window.sharingType = .none` verin, sonra
   `NSApp.windows.filter { $0.sharingType == .none }.map(\.windowNumber)` → `SCContentFilter(display:excludingWindows:)`. (better-shot'ta `excludedWindowIDs` olarak kullanılıyor.)
2. **Kapat + bekle:** `orderOut(nil)` → `try? await Task.sleep(for: .milliseconds(80...200))` → capture. better-shot fullscreen'de 200 ms, rect capture'da 80 ms bekliyor. Basit ama kullanıcı bir kare boyunca boş ekranı görür.

En sağlamı: **ikisini birden** (sharingType + kısa gecikme).

### 3.3 Klavye

ESC iptal: hem `keyDown` içinde `event.keyCode == 53`, hem de `NSEvent.addLocalMonitorForEvents` + `addGlobalMonitorForEvents(matching: .keyDown)`. Capso her iki monitörü de kuruyor çünkü overlay key window olamadığı durumlar var. **Not:** global `.keyDown` monitörü Accessibility ister; overlay senaryosunda local monitör + `canBecomeKey=true` genelde yeterli, global'i fallback olarak opsiyonel yapın.
Ok tuşlarıyla nudge: `NSEvent.ModifierFlags.shift` → 10 px, yalnız ok → 1 px.

### 3.4 Referans repo'lar (2026-09-22 itibarıyla doğrulandı)

| Repo | ★ | Lisans | Son push | Neye bakmalı |
|---|---|---|---|---|
| [sw33tLie/macshot](https://github.com/sw33tLie/macshot) | 3545 | GPL-3.0 | 2026-09-20 | `macshot/Capture/ScreenCaptureManager.swift`, `macshot/UI/Overlay/OverlayWindowController.swift`, `Services/HotkeyManager.swift`. En kapsamlısı; **GPL — lisans dikkat.** |
| [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy) | 3205 | BSD-3-Clause | 2026-09-21 | `Features/Annotate/InlineAreaAnnotateWindow.swift`, `Services/Capture/ScreenCaptureManager.swift`, `History/Managers/HistoryFloatingPanel.swift` (bizim quick-action paneline birebir örnek) |
| [KartikLabhshetwar/better-shot](https://github.com/KartikLabhshetwar/better-shot) | 2319 | (custom) | 2026-09-21 | `Sources/Capture/ScreenCapture.swift` (hibrit CLI+SCK), `Sources/Capture/RegionGeometry.swift` (koordinat flip), `RegionSelectionOverlay.swift` |
| [lzhgus/Capso](https://github.com/lzhgus/Capso) | 1347 | (custom) | 2026-09-03 | `App/Sources/Capture/CaptureOverlayWindow.swift` + `CaptureOverlayView.swift`, `Packages/CaptureKit/.../ScreenCaptureManager.swift` — **en temiz saf-SCK örneği** |

Apple'ın resmi örneği: [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos) (eski adıyla CaptureSample) — bölge seçim UI'ı **yok**, sadece filtre/stream kurulumu ve "kendi uygulamanı bundle id ile hariç tut" kalıbı var.

---

## 4. İzinler (TCC) — checklist

### 4.1 API'ler

- `CGPreflightScreenCaptureAccess() -> Bool` — prompt **çıkarmaz**, sadece durumu söyler.
- `CGRequestScreenCaptureAccess() -> Bool` — bir kez prompt çıkarır. SDK header'ı net: *"A previously denied process is not re-prompted; the user must enable access in System Settings > Privacy & Security > Screen Recording."*
- `SCShareableContent.current` / `.excludingDesktopWindows(...)` — izin yoksa `SCStreamError` fırlatır ve ilk çağrıda prompt tetikler.
- **İzin verildikten sonra uygulamayı yeniden başlatmak gerekir** (Apple'ın kendi örnek kodu da bunu söylüyor).

### 4.2 Periyodik yeniden onay

- Sequoia 15.0'da haftalık olarak geldi, beta 6'da **aylığa** indirildi; Tahoe 26'da **hâlâ var**, kapatılamıyor.
- macOS 15.1 ile MDM için `forceBypassScreenCaptureAlert` anahtarı eklendi — sadece kurumsal.
- **Tek seferlik screenshot'lar muaf değil.** Muaf olan tek şey macOS'un kendi `⌘⇧3/4/5` akışı. `SCScreenshotManager` kullanımı da "screen capture usage" sayılır. Bunu ürün kararı olarak kabul edin: kullanıcı ayda bir "Tasker ekranınızı kaydediyor" diyaloğu görecek.
- macOS 26'da panel adı **"Screen & System Audio Recording"**; eski "Screen Recording" grant'ı upgrade sonrası yeniden verilmek zorunda kalabiliyor.

### 4.3 Ad-hoc / imzasız dev build'leri — en kritik kısım

- Ad-hoc imzada designated requirement **cdhash'e pinlenir**. Her `swift build` yeni bir cdhash üretir → TCC grant'ı eşleşmez → izin **her rebuild'de kaybolur**.
- macOS 26.1'de `.app` bundle'ı olmayan çıplak executable'lar Privacy panelinde **listelenmiyor** (prompt çıkıyor, capture çalışıyor, ama kullanıcı yönetemiyor). Apple DTS (Quinn): *"IMO this is a bug"*; 26.3 beta'da düzelmiş olabilir.

**Sonuç: Tasker'ı dev'de bile mutlaka `.app` bundle olarak paketleyin** (`Tasker.app/Contents/MacOS/Tasker` + `Info.plist` içinde `CFBundleIdentifier`, `LSUIElement`, `NSCameraUsageDescription` gerekmez ama `CFBundleName`/`CFBundleIdentifier` şart).

### 4.4 Checklist

1. `.app` bundle üret (SwiftPM binary'yi elle bundle'la); `CFBundleIdentifier` sabit tut (ör. `com.tasker.app`).
2. Keychain Access'te **self-signed "Code Signing" sertifikası** oluştur; `codesign -s "Tasker Dev" --force --deep Tasker.app` ile imzala → designated requirement identity tabanlı olur, cdhash'e pinlenmez, grant rebuild'ler arası korunur. (Ad-hoc `-` kullanmayın.)
3. Açılışta `CGPreflightScreenCaptureAccess()`; false ise kendi onboarding ekranını göster, sonra `CGRequestScreenCaptureAccess()`.
4. Kullanıcıyı doğrudan panele yolla: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
5. İzin verildiğinde uygulamayı relaunch et (`NSWorkspace.openApplication` + `exit(0)`).
6. Dev sıfırlama: `tccutil reset ScreenCapture com.tasker.app` → uygulamayı yeniden başlat.
7. Aylık nag'i beklenen davranış olarak dokümante et; "Neden tekrar soruyor?" için FAQ yazısı koy.
8. Sandbox planlıyorsanız `screencapture` spawn yolunu şimdiden kapat.

**Kaynaklar:** [9to5Mac — aylık prompt](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/) · [Apple Forums 807898 — çıplak executable bug'ı](https://developer.apple.com/forums/thread/807898) · [Cap#1722 — imzasız build'lerde TCC](https://github.com/CapSoftware/Cap/issues/1722) · [ss64 tccutil](https://ss64.com/mac/tccutil.html)

---

## 5. Global kısayollar

| Yöntem | Gereken TCC izni | Sandbox | macOS 26/27 durumu |
|---|---|---|---|
| **Carbon `RegisterEventHotKey`** | **Yok** | ✅ | Çalışıyor. Swift 6.4 + SDK 27.0 ile `import Carbon.HIToolbox` üzerinden **deprecation uyarısı olmadan** type-check ediliyor (yerel doğrulama). |
| `NSEvent.addGlobalMonitorForEvents(.keyDown)` | **Accessibility** | ⚠️ sandbox'ta sorunlu | Çalışır ama *tüm* tuş vuruşlarını alır — gereksiz mahremiyet yükü, izin verilmezse sessizce hiç tetiklenmez |
| `CGEvent.tapCreate` | **Input Monitoring** (`CGPreflightListenEventAccess` / `CGRequestListenEventAccess`) | ✅ | Çalışır; sistem tap'ı timeout'ta devre dışı bırakabilir, imza değişince sessizce kapanabilir |

**Not:** Sadece *mouse* eventleri için global monitör (`.leftMouseDown`) hiçbir izin istemez — §6'daki "dışarı tıklayınca kapat" için bu yeterli.

### Öneri: `sindresorhus/KeyboardShortcuts`

- **v3.1.0** (2026-09-11), **MIT**, 2710 ★, bağımlılık yok, `swift-tools-version: 6.2`, min **macOS 10.15**.
- 3.1.0 release notları birebir: *"Improve macOS 27 compatibility"* → aktif bakımda ve yeni OS'a hazır.
- Altında Carbon var: `Sources/KeyboardShortcuts/HotKey.swift` → `import Carbon.HIToolbox`. Dolayısıyla **izin diyaloğu yok**, sandbox ve Mac App Store uyumlu.
- SwiftUI recorder hazır: `KeyboardShortcuts.Recorder("Capture region:", name: .captureRegion)` — sistem çakışmalarını da uyarıyor, `UserDefaults`'a kendisi yazıyor.
- Bilinen kısıt: Carbon tek bir kombinasyon için tek kayıt kabul eder; aynı kombinasyonu iki kez register edemezsiniz.

Tasker non-sandboxed olacak olsa da, KeyboardShortcuts hem sıfır izin hem de ileride sandbox'a geçiş seçeneğini açık bırakıyor. **Kendi Carbon wrapper'ınızı yazmayın.**

**Kaynaklar:** [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · [Swift Package Index](https://swiftpackageindex.com/sindresorhus/KeyboardShortcuts) · [quicopy — sandbox'ta global shortcut](https://www.quicopy.com/blog/macos-sandbox-keyboard-shortcuts) · [AeroSpace#1012 — CGEvent.tapCreate değerlendirmesi](https://github.com/nikitabobko/AeroSpace/issues/1012)

---

## 6. Post-capture quick-actions paneli (CleanShot X tarzı)

```swift
super.init(contentRect: …,
           styleMask: [.nonactivatingPanel, .fullSizeContentView],
           backing: .buffered, defer: false)
isFloatingPanel = true
level = .floating
hidesOnDeactivate = false
becomesKeyOnlyIfNeeded = true          // metin alanı tıklanınca key olur
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
animationBehavior = .utilityWindow
isMovableByWindowBackground = true
contentView = NSHostingView(rootView: QuickActionsView())
override var canBecomeKey: Bool { true }   // TextField için ŞART
```

**Tuzaklar:**

1. `canBecomeKey` override edilmezse panel içindeki `TextField`/`TextEditor` **hiç yazı almaz** — `.nonactivatingPanel` + borderless kombinasyonunda varsayılan `false`.
2. `NSApp.activate(ignoringOtherApps: true)` **çağırmayın**; non-activating davranışı yok eder, kullanıcıyı bulunduğu uygulamadan koparır. Bunun yerine odak gerektiğinde `panel.makeKey()`.
3. SwiftUI `@FocusState` ilk frame'de çalışmaz; `.onAppear { DispatchQueue.main.async { isFocused = true } }` veya `.task { await Task.yield(); isFocused = true }`.
4. Klavye kısayolları: panel key değilken `.keyboardShortcut` tetiklenmez. `⌘↩` "gönder", `esc` "kapat" için `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` ile manuel eşleme daha güvenilir.
5. Dışarı tıklayınca kapatma: `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` — **mouse eventleri için Accessibility izni gerekmez**. Ek olarak `NSWindow.didResignKeyNotification` dinleyin.
6. Menü-bar uygulaması ise `NSApp.setActivationPolicy(.accessory)` + `Info.plist`'te `LSUIElement = true`.
7. `.canJoinAllSpaces` olmadan kullanıcı Space değiştirince panel kaybolur; `.fullScreenAuxiliary` olmadan tam ekran uygulamaların üstünde görünmez.

Referans implementasyon: Snapzy `Features/History/Managers/HistoryFloatingPanel.swift` (+ `HistoryFloatingPanelController.swift`).

**Kaynaklar:** [SwiftUI Floating Panel: NSPanel Patterns](https://fazm.ai/blog/swiftui-floating-panel) · [Mastering NSPanel](https://www.swiftyn.com/learn/macos/mastering-nspanel-macos-utility-windows) · [Ardent Swift — hotkey window](https://ardentswift.com/posts/hotkey-window/)

---

## 7. Görsel işleme

### 7.1 Depolama formatı

- **Master: PNG.** UI screenshot'larında metin kenarları keskin kalmalı; JPEG artifact'leri OCR ve Claude okunabilirliğini düşürür.
- HEIC ~%40-50 daha küçük ama her tüketici tarafında ek decode maliyeti; macOS 26'da `SCScreenshotConfiguration.contentType = UTType.heic` + `fileURL` ile SCK doğrudan yazabiliyor. **Öneri: v1'de PNG, boyut sorun olursa HEIC'i ayar olarak ekleyin.**

### 7.2 Thumbnail

`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceThumbnailMaxPixelSize: 512`, `kCGImageSourceCreateThumbnailWithTransform: true`. Naif `NSImage` resize'a göre ~**30x** hızlı (12 MP JPEG için ~26 ms). Mutlaka main thread dışında (`Task.detached(priority: .utility)`), sonucu `@MainActor`'a taşıyın. Library penceresinde 100+ küçük resim varken fark kritik.

### 7.3 Claude'a gönderim (güncel Anthropic dokümanı)

| Tier | Modeller | Max uzun kenar | Max visual token |
|---|---|---|---|
| High-resolution | **Claude 4.7 ve sonrası** | **2576 px** | 4784 |
| Standard | Diğer tüm modeller | **1568 px** | 1568 |

- Token formülü: `⌈width/28⌉ × ⌈height/28⌉`. Yani 4K screenshot high-res tier'da ~4784 token ≈ Opus 5 fiyatıyla 1000 görsel için ~$24.
- Limitler: tek görsel max **8000×8000 px**, **10 MB** base64 (Bedrock/Vertex 5 MB); **tek istekte 20'den fazla görsel** varsa her görselin her boyutu ≤ **2000 px** olmalı, yoksa `invalid_request_error`.
- Desteklenen: JPEG, PNG, GIF, WebP.
- **Tasker kuralı:** göndermeden önce uzun kenarı 1568'e (veya 4.7+ modelde 2576'ya) indir, `ImageIO` ile yeniden encode et. Doküman JPEG için uyarıyor: ağır sıkıştırma metni okunamaz hale getirebilir → **PNG veya q ≥ 0.85 JPEG** kullanın. Çok turlu akışta base64 yerine **Files API + `file_id`** tercih edin (her turda tüm görsel byte'ları yeniden gönderilmiyor).

**Kaynak:** [Claude Vision docs](https://platform.claude.com/docs/en/build-with-claude/vision)

### 7.4 Retina metadata

SCK **piksel** boyutunda `CGImage` döner. `NSImage(cgImage:size:)` çağrısında `size`'ı **nokta** cinsinden (`pixels / pointPixelScale`) verin; aksi halde SwiftUI'da 2x büyük görünür. Diskte PNG'ye dpi yazmak için `NSBitmapImageRep.size`'ı nokta cinsine set edip öyle encode edin. (`screencapture` bunu kendisi yapıyor; `-r` ile devre dışı bırakılabilir.)

### 7.5 Pano

```
let pb = NSPasteboard.general
pb.clearContents()
pb.setData(pngData, forType: .png)     // Slack, Notion, Figma bunu alır
pb.writeObjects([fileURL as NSURL])    // Finder, Mail dosya olarak alır
```
İkisini birden yazın; tüketici uygulama hangisini istiyorsa onu seçer.

### 7.6 Annotation (ok/dikdörtgen/metin)

**v1'de yapmayın.** Yapılacaksa: görüntünün üstüne SwiftUI `Canvas` + vektör katman modeli (`[Annotation]`), export için `ImageRenderer`. Metin kutuları için [blackbeltlabs/TextAnnotation](https://github.com/blackbeltlabs/TextAnnotation) (macOS, Swift) bakılabilir. Snapzy'nin `Features/Annotate/` klasörü tam bir referans implementasyon. Tasker'ın değer önerisi "not + Claude'a gönder" olduğu için annotation sonraki faz.

---

## Öneri

### Karar tablosu

| Konu | Karar | Gerekçe |
|---|---|---|
| **Capture yöntemi (v1)** | `/usr/sbin/screencapture -i -s -x -t png` | Sıfır overlay kodu, sistem seçim UI'ı, doğru Retina/multi-display; izin zaten Tasker.app'e sorulur |
| **Capture yöntemi (v2)** | Custom overlay + `SCScreenshotManager.captureScreenshot(rect:configuration:)` (macOS 26+), fallback `captureImage(contentFilter:configuration:)` | Rect'i biliriz → "son bölgeyi tekrarla", magnifier, panele akıcı geçiş |
| **Overlay** | `NSPanel` / `.borderless + .nonactivatingPanel`, `level = .screenSaver`, her `NSScreen` için bir panel, `canBecomeKey = true`, `sharingType = .none` | Capso'da üretimde doğrulanmış reçete |
| **Overlay'i gizleme** | `sharingType = .none` + filtre hariç tutma **ve** 80 ms `orderOut` gecikmesi | İki kemer, bir askı |
| **Hotkey** | `sindresorhus/KeyboardShortcuts` **3.1.0** (MIT) | Sıfır TCC izni, SwiftUI Recorder, macOS 27 uyumu release notlarında |
| **Post-capture panel** | `NSPanel` + `isFloatingPanel`, `becomesKeyOnlyIfNeeded`, `canBecomeKey` override, `NSHostingView` | Metin notu alanı için focus şart |
| **Format** | Master PNG; Claude'a gönderirken uzun kenar ≤1568 (4.7+ modelde ≤2576) | Metin okunabilirliği + token maliyeti |
| **Deprecated API** | `CGWindowListCreateImage` / `CGDisplayCreateImage` **kullanılmayacak** | macOS 15'te obsoleted, derlenmiyor |
| **Dev imzalama** | `.app` bundle + **self-signed sertifika** (ad-hoc `-` değil) | TCC grant'ı rebuild'ler arası korunsun |

### Çekirdek capture çağrısı

> Aşağıdaki blok bu makinede `swiftc -target arm64-apple-macosx26.0 -typecheck` ile **derlenerek doğrulandı** (SDK 27.0, Swift 6.4).

```swift
import ScreenCaptureKit
import AppKit
import UniformTypeIdentifiers

/// globalRectInPoints: CoreGraphics global koordinatlar (sol-ÜST orijin), nokta cinsinden.
@available(macOS 26.0, *)
func captureRegion(globalRectInPoints rect: CGRect,
                   on displayID: CGDirectDisplayID,
                   to fileURL: URL) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                       onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw CaptureError.noDisplayFound
    }

    // Kendi overlay pencerelerimizi hariç tut (sharingType = .none atanmış olanlar).
    let ourWindowNumbers = Set(NSApp.windows.filter { $0.sharingType == .none }.map(\.windowNumber))
    let excluded = content.windows.filter { ourWindowNumbers.contains(Int($0.windowID)) }
    let filter = SCContentFilter(display: display, excludingWindows: excluded)

    // sourceRect filtrenin LOCAL uzayında: display'in sol-üst köşesi (0,0).
    let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        .intersection(CGRect(origin: .zero, size: display.frame.size))
    guard !local.isEmpty else { throw CaptureError.emptyRect }

    let scale = CGFloat(filter.pointPixelScale)          // Retina: 2.0 (veya 1.0 / 3.0)
    let config = SCScreenshotConfiguration()
    config.sourceRect  = local                            // nokta
    config.width       = Int((local.width  * scale).rounded())   // piksel
    config.height      = Int((local.height * scale).rounded())
    config.showsCursor = false
    config.dynamicRange = .sdr
    config.displayIntent = .canonical
    // TUZAK: header'da `UTType *contentType` (ObjC pointer) olarak tanımlı,
    // Swift'e `UTTypeReference` olarak köprülenir — `.png` derlenmez.
    config.contentType = UTType.png as UTTypeReference
    config.fileURL     = fileURL                          // SCK dosyayı kendisi yazar

    let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter,
                                                                 configuration: config)
    guard let image = output.sdrImage else { throw CaptureError.captureFailed("no sdrImage") }
    return image
}

// macOS 15.x fallback (tek satır, çok monitör farkında, ama overlay hariç tutulamaz):
//   let image = try await SCScreenshotManager.captureImage(in: globalRectInPoints)
```

**AppKit → CoreGraphics rect dönüşümü** (overlay'den gelen rect için):

```swift
let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
let cgRect = CGRect(x: appKitGlobal.minX,
                    y: primaryHeight - appKitGlobal.maxY,
                    width: appKitGlobal.width,
                    height: appKitGlobal.height)
```
