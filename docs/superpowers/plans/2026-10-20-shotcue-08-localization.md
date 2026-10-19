# Shotcue — Plan 08: Çoklu dil (İngilizce + Türkçe) ve bölgeye uygun biçimler

**Hedef:** Arayüz sistem dilini takip etsin (desteklenmeyen dilde İngilizce), Ayarlar'dan dil seçilebilsin, tarih/saat/sayı
biçimleri dile ve bölgeye uysun. Sesli not dili listesi genişlesin; Claude'un özeti arayüz dilinde yazılsın.

**Kapsam dışı (şimdilik):** Ayrı saat dilimi seçimi. Zamanlama ve günlük kuyruk sistem saat dilimini kullanmaya devam eder
(günlük kuyruk `HH:mm` saklar; saat dilimi değişirse anlamı kayar).

## Spike sonuçları (2026-10-20, CLT 27.0 / Swift 6.4)

- **String Catalog (`.xcstrings`) kullanılamaz:** SwiftPM onu `xcstringstool` ile derler, o da yalnızca Xcode'da var
  (`… xcstringstool is not an executable file`). Klasik **`.strings`** tabloları çalışıyor, `%@`/`%lld` interpolasyonu dahil.
- **Dil seçimi ana paketin dillerine bağlı:** Komut satırı aracı `-AppleLanguages '(tr)'` ile bile İngilizce kaldı; aynı
  ikili `CFBundleLocalizations = [en, tr]` olan bir `.app` içinde Türkçeye geçti, desteklenmeyen `de` için İngilizceye düştü.
- `scripts/bundle.sh` SwiftPM kaynak paketlerini (`Shotcue_<Modül>.bundle`) zaten `Contents/Resources`'a kopyalıyor; imza
  `codesign --verify --deep --strict` ile geçiyor.
- Bu Mac'in dil tercihi `en-TR`: "sistem dilini takip et" İngilizce açar.

## Altyapı (feat/l10n-foundation — hazır)

- `Package.swift`: `defaultLocalization: "en"`; `ShotcueCore`, `ShotcueUI`, `ShotcueApp` → `resources: [.process("Resources")]`.
- Her modülde `Resources/en.lproj/Localizable.strings` ve `Resources/tr.lproj/Localizable.strings`, ayrıca
  `nonisolated enum L10n { static let bundle = Bundle.module }`.
- `LocalizationTablesTests` (Core): her dilde her anahtar var mı, fazladan anahtar var mı, yer tutucular (`%@`, `%lld`,
  `%1$@`…) eşleşiyor mu. `L10nBundleTests` (UI): derlenen paket iki dili taşıyor ve Türkçe tabloyu okuyor.
- **`Info.plist` henüz değişmedi** (`CFBundleDevelopmentRegion = tr`, `CFBundleLocalizations` yok). Metinler taşınmadan
  eklenirse macOS'un kendi menüleri İngilizce sistemde İngilizceye döner, arayüz karışık kalır. Son PR'da eklenecek.

## Kurallar

- **Anahtar = İngilizce kaynak metin.** `en` tablosu anahtarı aynen tekrarlar; `tr` çeviriyi tutar. Bağlam gerekirse
  tabloya `/* … */` yorumu yazılır.
- SwiftUI: `Text("Save", bundle: L10n.bundle)`, `Button("Save", bundle: …)` yoksa `Button { … } label: { Text(…, bundle:) }`.
  `Label`, `Toggle`, `Section`, `Picker` başlıkları için de aynı yol (`LocalizedStringKey` + `bundle`).
- Diğer kod: `String(localized: "Save", bundle: L10n.bundle)`. İnterpolasyon `String(localized: "\(count) items", …)`
  → anahtar `%lld items`.
- Saf `label` hesaplayan enum'lar (`SortOrder.label`, `StatusPresentation.label`, `RunErrorText`…) `String(localized:)`
  döner; testleri sabit metin yerine anahtarın bulunduğunu ve Türkçe tablodaki karşılığını doğrular.
- Yeni bir metin eklenirken iki tabloya da yazılır; `make test` eksikte kırılır.

## PR'lar (açık #1–#6 merge edildikten sonra, güncel `main`'den)

1. **feat/l10n-foundation** (bu altyapı) + Ayarlar → Genel → **Dil**: *Sistem dili* / *Türkçe* / *English*.
   Seçim uygulamanın `AppleLanguages` varsayılanına yazılır (Sistem Ayarları'ndaki uygulama başına dil ile aynı yer;
   *Sistem dili* bu anahtarı siler), "Şimdi yeniden başlat" düğmesi `TerminationController` üzerinden yeniden açar.
   `Formatting` sabit `tr_TR` yerine `Locale.autoupdatingCurrent` kullanır; testler sabit `Locale` geçirir.
   Ayarlar ekranının metinleri taşınır.
2. **feat/l10n-ui**: kütüphane, inspector, hızlı panel, menü çubuğu, diff, güncelleme penceresi.
3. **feat/l10n-core-app**: `RunErrorText`, durum/çalışma adları, bildirimler, kurulum penceresi, tanılama şeridi;
   `Info.plist` → `CFBundleDevelopmentRegion = en`, `CFBundleLocalizations = [en, tr]`; README (EN/TR) ve CLAUDE.md
   kural güncellemesi; README görsellerinin yeniden üretimi.

Ayrıca (2 veya 3 içinde):
- **Sesli not dili:** `SettingsStore.sttLanguageChoices` (`tr`, `en`) → WhisperKit'in desteklediği diller, adları
  `Locale.localizedString(forLanguageCode:)` ile; en üstte *Otomatik algıla* (`detectLanguage: true`).
- **Claude'un özet dili:** `PromptBuilder` sistem talimatına "Write the summary in <arayüz dili>." eklenir.

## Doğrulama

- `make test` (eşleşme testleri dahil) her PR'da yeşil.
- `make run`: İngilizce sistemde İngilizce, Ayarlar'dan Türkçe seçip yeniden başlatınca Türkçe; tarih biçimleri
  ("20 Ekim Salı, 14:30" / "Tuesday, October 20, 14:30") ekran görüntüsüyle kontrol.
- `SHOTCUE_README_SHOTS=… make test FILTER='ReadmeScreenshot'` her iki dilde render (testte `AppleLanguages` yerine
  ilgili tabloyu zorlayan bir yardımcı gerekebilir).
