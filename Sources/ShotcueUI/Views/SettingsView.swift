import ShotcueCore
import SwiftUI

/// The `Settings` scene's content (spec §6.6): four tabs, each a grouped `Form`.
/// `claudeVersion`, `transcriberState` and `onDownloadModel` are supplied by Plan 06, because reading
/// `claude --version` and driving the WhisperKit download belong to the service modules.
public struct SettingsView: View {
    public let settings: SettingsStore
    public let permissions: PermissionsStore
    public let projects: [Project]
    public let claudeVersion: String?
    public let transcriberState: TranscriberModelState
    public let onDownloadModel: () -> Void
    /// Shown on the download button ("Modeli indir (≈1,6 GB)", spec §6.2: "boyut gösterilir").
    public let modelDownloadSize: String?
    /// Input devices for the "Giriş cihazı" picker; empty → a UID text field is shown instead.
    /// Filled by the App layer from `AudioDeviceCatalog.inputDevices()` (ShotcueNotes).
    public let inputDevices: [(uid: String, name: String)]

    public init(
        settings: SettingsStore,
        permissions: PermissionsStore,
        projects: [Project],
        claudeVersion: String?,
        transcriberState: TranscriberModelState,
        onDownloadModel: @escaping () -> Void,
        modelDownloadSize: String? = nil,
        inputDevices: [(uid: String, name: String)] = []
    ) {
        self.settings = settings
        self.permissions = permissions
        self.projects = projects
        self.claudeVersion = claudeVersion
        self.transcriberState = transcriberState
        self.onDownloadModel = onDownloadModel
        self.modelDownloadSize = modelDownloadSize
        self.inputDevices = inputDevices
    }

    public var body: some View {
        TabView {
            Tab("Genel", systemImage: "gearshape") { generalTab }
            Tab("Claude", systemImage: "terminal") { claudeTab }
            Tab("Ses", systemImage: "mic") { audioTab }
            Tab("İzinler", systemImage: "lock.shield") { permissionsTab }
        }
        .frame(width: 580, height: 460)
        .task { await permissions.refresh() }
    }

    // MARK: - Genel

    private var generalTab: some View {
        @Bindable var store = settings
        return Form {
            Section("Yakalama") {
                Picker("Kısayol", selection: $store.hotKeyLabel) {
                    ForEach(KeyCombo.presets, id: \.self) { combo in
                        Text(combo.label).tag(combo.label)
                    }
                }
                Text("Özel kombinasyon kaydedici v1.1'de gelecek; şimdilik hazır listeden seçilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Yakalamayı panoya da kopyala", isOn: $store.copyToClipboardOnCapture)
            }

            Section("Sistem") {
                Toggle("Oturum açılışında başlat", isOn: $store.launchAtLogin)
                // What the switch does: no idle sleep while a run is in progress (final review M5).
                Toggle("Görev çalışırken Mac'i uyanık tut", isOn: $store.keepAwake)
            }

            Section("Depolama") {
                LabeledContent("Konum") {
                    Text(settings.storageRoot.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Klasör seç…") { settings.isStoragePickerPresented = true }
                        .fileImporter(
                            isPresented: $store.isStoragePickerPresented,
                            allowedContentTypes: [.folder],
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                settings.storageRootPath = url.path
                            }
                        }
                    Button("Varsayılana dön") { settings.storageRootPath = nil }
                        .disabled(settings.storageRootPath == nil)
                }
                Text("Taşıma elle yapılır: mevcut dosyaları yeni klasöre kopyalayıp uygulamayı yeniden başlat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Varsayılan proje") {
                Picker(
                    "Hızlı panelde seçili",
                    selection: Binding<String?>(
                        get: { settings.lastUsedProjectID },
                        set: { settings.lastUsedProjectID = $0 })
                ) {
                    Text("Son kullanılan").tag(String?.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id.uuidString))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Claude

    private var claudeTab: some View {
        @Bindable var store = settings
        return Form {
            Section("CLI") {
                LabeledContent("Sürüm") {
                    if let claudeVersion {
                        Label(claudeVersion, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("bulunamadı — gönderme devre dışı", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                LabeledContent("Yol") {
                    TextField(
                        "otomatik bul",
                        text: Binding(
                            get: { settings.claudePath ?? "" },
                            set: { settings.claudePath = $0 })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                }
                Text("Boş bırakılırsa sırayla ~/.local/bin, /opt/homebrew/bin, /usr/local/bin ve login shell denenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Varsayılanlar") {
                LabeledContent("Model") {
                    TextField(
                        "CLI varsayılanı",
                        text: Binding(
                            get: { settings.defaultModel ?? "" },
                            set: { settings.defaultModel = $0 })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                }
                LabeledContent("Effort") {
                    TextField(
                        "belirtilmedi",
                        text: Binding(
                            get: { settings.defaultEffort ?? "" },
                            set: { settings.defaultEffort = $0 })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                }
            }

            Section("Limitler") {
                Stepper("Maksimum tur: \(settings.maxTurns)", value: $store.maxTurns, in: 1...500, step: 5)
                LabeledContent("Bütçe (USD)") {
                    TextField("5", value: $store.maxBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Stepper(
                    "Zaman aşımı: \(settings.timeoutMinutes) dk",
                    value: $store.timeoutMinutes, in: 1...480, step: 5)
                Stepper(
                    "Eş zamanlı çalışma: \(settings.maxConcurrentRuns)",
                    value: $store.maxConcurrentRuns, in: 1...8)
            }

            Section("Yetki modu") {
                Picker("Mod", selection: $store.permissionMode) {
                    ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                        Text(Self.permissionModeLabel(mode)).tag(mode.rawValue)
                    }
                }
                if settings.claudePermissionMode == .bypassPermissions {
                    Label(
                        "Uygula modunda Claude dosya değişikliklerini sormadan yapar. Bu bilinçli bir tercih; güvenli tarafta kalmak için acceptEdits'e düşürebilirsin.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Ek sistem talimatı") {
                TextEditor(text: $store.extraSystemPrompt)
                    .font(.callout)
                    .frame(minHeight: 70)
                Text("Sabit Shotcue talimatından sonra eklenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ses

    private var audioTab: some View {
        @Bindable var store = settings
        return Form {
            Section("Transkripsiyon") {
                Picker("Dil", selection: $store.sttLanguage) {
                    Text("Türkçe").tag("tr")
                    Text("İngilizce").tag("en")
                }
                Picker("Model", selection: $store.sttModel) {
                    ForEach(SettingsStore.sttModelChoices, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                LabeledContent("Durum") {
                    Text(Self.modelStateLabel(transcriberState))
                        .foregroundStyle(Self.modelStateTint(transcriberState))
                }
                if case .downloading(let progress) = transcriberState {
                    ProgressView(value: progress) {
                        Text("Model indiriliyor")
                    }
                    .progressViewStyle(.linear)
                } else if case .ready = transcriberState {
                    EmptyView()
                } else {
                    Button(modelDownloadSize.map { "Modeli indir (\($0))" } ?? "Modeli indir") { onDownloadModel() }
                        .buttonStyle(.glassProminent)
                }
                Text(
                    "Model hazır olmadan da sesli not alınabilir; transkripsiyon bekler ve model gelince kuyruk işlenir."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Giriş cihazı") {
                if inputDevices.isEmpty {
                    LabeledContent("Cihaz UID") {
                        TextField(
                            "sistem varsayılanı",
                            text: Binding(
                                get: { settings.inputDeviceUID ?? "" },
                                set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    }
                } else {
                    Picker(
                        "Cihaz",
                        selection: Binding<String>(
                            get: { settings.inputDeviceUID ?? "" },
                            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })
                    ) {
                        Text("Sistem varsayılanı").tag("")
                        ForEach(inputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                Text("Boş bırakılırsa sistemin varsayılan mikrofonu kullanılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Deneysel") {
                Toggle("Foundation Models ile başlık önerisi (v1.1)", isOn: $store.foundationModelsEnabled)
                    .disabled(true)
                Text(
                    "Command Line Tools'ta FoundationModels makroları derlenmediği için bu özellik v1'de kapalı (spec §6.2). Apple Intelligence durumu Tanılama şeridinde görünür."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - İzinler

    private var permissionsTab: some View {
        Form {
            Section("Durum") {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label(permissions.label(for: kind), systemImage: permissions.symbol(for: kind))
                                .foregroundStyle(permissions.tint(for: kind))
                            Text(permissions.stateLabel(for: kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if permissions.state(of: kind) == .notDetermined {
                                Button("İzin ver") { Task { await permissions.request(kind) } }
                            }
                            Button("Sistem Ayarları") { permissions.openSettings(kind) }
                        }
                        Text(permissions.explanation(for: kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button("Durumları yenile") { Task { await permissions.refresh() } }
            } footer: {
                Text(
                    "macOS, Ekran Kaydı iznini ayda bir yeniden onaylatabilir; bu beklenen davranıştır. İzin verildikten sonra Shotcue'yu yeniden başlat."
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Pure copy helpers

    nonisolated public static func modelStateLabel(_ state: TranscriberModelState) -> String {
        switch state {
        case .notDownloaded: "İndirilmedi"
        case .downloading(let progress): "İndiriliyor… %\(Int((progress * 100).rounded()))"
        case .ready: "Hazır"
        case .failed(let message): "Hata: \(message)"
        }
    }

    nonisolated public static func modelStateTint(_ state: TranscriberModelState) -> Color {
        switch state {
        case .notDownloaded: .orange
        case .downloading: .blue
        case .ready: .green
        case .failed: .red
        }
    }

    nonisolated public static func permissionModeLabel(_ mode: ClaudePermissionMode) -> String {
        switch mode {
        case .bypassPermissions: "bypassPermissions (sormaz, uygular)"
        case .acceptEdits: "acceptEdits (düzenlemeleri kabul eder)"
        case .dontAsk: "dontAsk (yalnızca okuma)"
        }
    }
}
