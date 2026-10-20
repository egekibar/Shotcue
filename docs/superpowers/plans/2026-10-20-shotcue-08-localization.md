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

## Durum (2026-10-20): tamamlandı, tek PR (#7)

Ayarlar'daki dil seçicisi ancak `Info.plist` dilleri bildirince çalışıyor, `Info.plist` de ancak bütün metinler
taşınınca değişebiliyor (yoksa sistem menüleri arayüzün geri kalanından önce dil değiştiriyor). Bu yüzden üç PR yerine
hepsi #7'de, adım adım commit'lerle:

1. Altyapı: tablolar, `L10n`, eşleşme ve kapsam testleri.
2. Dil ayarı (`AppLanguage`, `SettingsStore.appLanguage`, "Şimdi yeniden başlat" → `TerminationController`
   `.languageChange`), yerel ayara uyan `Formatting`, Ayarlar ekranı ve çalışma logu.
3. `ShotcueUI`'nin geri kalanı.
4. Core (`RunErrorText`, güncelleme hataları, hızlı zamanlama seçimleri), ClaudeBridge, Notes, Updater.
5. App katmanı; tanılama raporu sabit İngilizce.
6. Sesli not: Whisper'ın bütün dilleri ve otomatik algılama; varsayılan arayüz dili.
7. Ajanlar özeti arayüz dilinde yazar (`PromptBuilder.systemPrompt(interfaceLanguage:)`).
8. `Info.plist`: `CFBundleDevelopmentRegion = en`, `CFBundleLocalizations = [en, tr]`.

Kalan (1.3.0 release'i ile): İngilizce README'deki Türkçe etiketlerin İngilizceye çevrilmesi ve README görsellerinin
iki dilde yeniden üretilmesi.

## Doğrulama

- `make test` (eşleşme testleri dahil) her PR'da yeşil.
- `make run`: İngilizce sistemde İngilizce, Ayarlar'dan Türkçe seçip yeniden başlatınca Türkçe; tarih biçimleri
  ("20 Ekim Salı, 14:30" / "Tuesday, October 20, 14:30") ekran görüntüsüyle kontrol.
- `SHOTCUE_README_SHOTS=… make test FILTER='ReadmeScreenshot'` her iki dilde render (testte `AppleLanguages` yerine
  ilgili tabloyu zorlayan bir yardımcı gerekebilir).
