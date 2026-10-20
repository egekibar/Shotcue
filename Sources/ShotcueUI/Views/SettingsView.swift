import ShotcueCore
import SwiftUI

/// The `Settings` scene's content (spec §6.6): four tabs, each a grouped `Form`.
/// The agent versions, `transcriberState` and `onDownloadModel` are supplied by Plan 06, because reading
/// `<cli> --version` and driving the WhisperKit download belong to the service modules.
public struct SettingsView: View {
    public let settings: SettingsStore
    public let permissions: PermissionsStore
    public let projects: [Project]
    public let claudeVersion: String?
    /// `codex --version` / `agy --version`; nil = not found (red).
    public let codexVersion: String?
    public let antigravityVersion: String?
    public let transcriberState: TranscriberModelState
    /// Starts the download, or resumes a paused one from its partial files.
    public let onDownloadModel: () -> Void
    /// "Duraklat" while the model downloads.
    public let onPauseDownload: () -> Void
    /// "Modeli sil" / "İndirileni sil", after the confirmation.
    public let onDeleteModel: () -> Void
    /// Shown on the download button ("Modeli indir (≈1,6 GB)", spec §6.2: "boyut gösterilir").
    public let modelDownloadSize: String?
    /// What the model (or its partial download) takes on disk ("1,5 GB"); nil when nothing is there.
    public let modelDiskUsage: String?
    /// Whisper's language codes for the voice-note language picker; filled by the App layer from WhisperKit.
    public let sttLanguages: [String]
    /// Input devices for the "Giriş cihazı" picker; empty → a UID text field is shown instead.
    /// Filled by the App layer from `AudioDeviceCatalog.inputDevices()` (ShotcueNotes).
    public let inputDevices: [(uid: String, name: String)]
    /// The running version, shown in Genel > Güncellemeler.
    public let appVersion: String?
    /// "Şimdi denetle"; the button is hidden when nil.
    public let onCheckForUpdates: (() -> Void)?
    /// "Restart now" after a language change; the button is hidden when nil.
    public let onRestart: (() -> Void)?

    public init(
        settings: SettingsStore,
        permissions: PermissionsStore,
        projects: [Project],
        claudeVersion: String?,
        codexVersion: String? = nil,
        antigravityVersion: String? = nil,
        transcriberState: TranscriberModelState,
        onDownloadModel: @escaping () -> Void,
        onPauseDownload: @escaping () -> Void = {},
        onDeleteModel: @escaping () -> Void = {},
        modelDownloadSize: String? = nil,
        modelDiskUsage: String? = nil,
        sttLanguages: [String] = SettingsStore.sttLanguageChoices,
        inputDevices: [(uid: String, name: String)] = [],
        appVersion: String? = nil,
        onCheckForUpdates: (() -> Void)? = nil,
        onRestart: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.permissions = permissions
        self.projects = projects
        self.claudeVersion = claudeVersion
        self.codexVersion = codexVersion
        self.antigravityVersion = antigravityVersion
        self.transcriberState = transcriberState
        self.onDownloadModel = onDownloadModel
        self.onPauseDownload = onPauseDownload
        self.onDeleteModel = onDeleteModel
        self.modelDownloadSize = modelDownloadSize
        self.modelDiskUsage = modelDiskUsage
        self.sttLanguages = sttLanguages
        self.inputDevices = inputDevices
        self.appVersion = appVersion
        self.onCheckForUpdates = onCheckForUpdates
        self.onRestart = onRestart
    }

    @UIState private var confirmsModelDeletion = false

    public var body: some View {
        TabView {
            Tab(L10n.t("General"), systemImage: "gearshape") { generalTab }
            Tab(L10n.t("Agents"), systemImage: "terminal") { agentsTab }
            Tab(L10n.t("Audio"), systemImage: "mic") { audioTab }
            Tab(L10n.t("Permissions"), systemImage: "lock.shield") { permissionsTab }
        }
        .frame(width: 580, height: 460)
        .task { await permissions.refresh() }
    }

    // MARK: - Genel

    private var generalTab: some View {
        @Bindable var store = settings
        return Form {
            Section(L10n.t("Language")) {
                Picker(L10n.t("Language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.nativeName ?? L10n.t("System language")).tag(language)
                    }
                }
                if settings.isRestartNeededForLanguage {
                    HStack {
                        Text(L10n.t("Restart Shotcue to switch the language."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let onRestart {
                            Button(L10n.t("Restart now"), action: onRestart)
                        }
                    }
                }
            }

            Section(L10n.t("Capture")) {
                HotKeyRecorder(settings: settings)
                Toggle(L10n.t("Also copy captures to the clipboard"), isOn: $store.copyToClipboardOnCapture)
            }

            Section(L10n.t("System")) {
                Toggle(L10n.t("Open at login"), isOn: $store.launchAtLogin)
                // What the switch does: no idle sleep while a run is in progress (final review M5).
                Toggle(L10n.t("Keep the Mac awake while a task runs"), isOn: $store.keepAwake)
            }

            Section(L10n.t("Storage")) {
                LabeledContent(L10n.t("Location")) {
                    Text(settings.storageRoot.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(L10n.t("Choose Folder…")) { settings.isStoragePickerPresented = true }
                        .fileImporter(
                            isPresented: $store.isStoragePickerPresented,
                            allowedContentTypes: [.folder],
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                settings.storageRootPath = url.path
                            }
                        }
                    Button(L10n.t("Use Default")) { settings.storageRootPath = nil }
                        .disabled(settings.storageRootPath == nil)
                }
                Text(L10n.t("Moving is manual: copy the existing files to the new folder, then restart the app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Default Project")) {
                Picker(
                    L10n.t("Selected in the quick panel"),
                    selection: Binding<String?>(
                        get: { settings.lastUsedProjectID },
                        set: { settings.lastUsedProjectID = $0 })
                ) {
                    Text(L10n.t("Last used")).tag(String?.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id.uuidString))
                    }
                }
            }

            Section(L10n.t("Updates")) {
                Toggle(L10n.t("Check for updates automatically"), isOn: $store.autoCheckUpdates)
                if let appVersion {
                    LabeledContent(L10n.t("Version"), value: appVersion)
                }
                LabeledContent(L10n.t("Last check")) {
                    Text(settings.lastUpdateCheck?.formatted(date: .abbreviated, time: .shortened) ?? L10n.t("Never"))
                        .foregroundStyle(.secondary)
                }
                if let onCheckForUpdates {
                    Button(L10n.t("Check Now"), action: onCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ajanlar

    private var agentsTab: some View {
        @Bindable var store = settings
        return Form {
            Section(L10n.t("Default Agent")) {
                Picker(L10n.t("Agent"), selection: $store.defaultAgent) {
                    ForEach(AgentKind.allCases) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                Text(L10n.t("Tasks run with their project's agent; projects that pick none use this one (Project Settings)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AgentKind.allCases) { agent in
                agentSection(agent)
            }

            Section(L10n.t("Limits")) {
                Stepper(L10n.t("Max turns: \(settings.maxTurns)"), value: $store.maxTurns, in: 1...500, step: 5)
                LabeledContent(L10n.t("Budget (USD)")) {
                    TextField("5", value: $store.maxBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Stepper(
                    L10n.t("Timeout: \(settings.timeoutMinutes) min"),
                    value: $store.timeoutMinutes, in: 1...480, step: 5)
                Stepper(
                    L10n.t("Concurrent runs: \(settings.maxConcurrentRuns)"),
                    value: $store.maxConcurrentRuns, in: 1...20)
                Text(L10n.t("Only Claude Code enforces the turn and budget limits; the timeout and concurrency apply to every agent."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Permission Mode")) {
                Picker(L10n.t("Mode"), selection: $store.permissionMode) {
                    ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                        Text(Self.permissionModeLabel(mode)).tag(mode.rawValue)
                    }
                }
                Text(
                    L10n.t(
                        "In Codex, bypassPermissions means full access without a sandbox and the other modes a sandbox limited to the project folder; in Antigravity, every mode but bypassPermissions turns on the terminal sandbox."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if settings.claudePermissionMode == .bypassPermissions {
                    Label(
                        L10n.t(
                            "In Implement mode the agent changes files without asking. This is a deliberate choice; lower it to acceptEdits to stay on the safe side."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.t("Extra System Prompt")) {
                TextEditor(text: $store.extraSystemPrompt)
                    .font(.callout)
                    .frame(minHeight: 70)
                Text(L10n.t("Appended after Shotcue's own instructions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// One agent CLI: its version (red when missing), its path, its default model and effort.
    private func agentSection(_ agent: AgentKind) -> some View {
        Section(agent.displayName) {
            LabeledContent(L10n.t("Version")) {
                if let version = version(of: agent) {
                    Label(version, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(L10n.t("not found"), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            LabeledContent(L10n.t("Path")) {
                TextField(
                    L10n.t("find automatically"),
                    text: Binding(
                        get: { settings.executablePath(for: agent) ?? "" },
                        set: { settings.setExecutablePath($0, for: agent) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
            }
            Picker(
                L10n.t("Model"),
                selection: Binding(
                    get: { settings.defaultModel(for: agent) ?? "" },
                    set: { settings.setDefaultModel($0, for: agent) })
            ) {
                ForEach(AgentModelChoices.options(for: agent, including: settings.defaultModel(for: agent)), id: \.self) {
                    model in
                    Text(model.isEmpty ? L10n.t("CLI default") : model).tag(model)
                }
            }
            Picker(
                L10n.t("Effort"),
                selection: Binding(
                    get: { settings.defaultEffort(for: agent) ?? "" },
                    set: { settings.setDefaultEffort($0, for: agent) })
            ) {
                ForEach(effortOptions(for: agent), id: \.self) { effort in
                    Text(effort.isEmpty ? L10n.t("not set") : effort).tag(effort)
                }
            }
            Text(L10n.t("When empty, \(Self.candidateFolders(agent)) and the login shell are tried in that order."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "~/.local/bin, /opt/homebrew/bin, /usr/local/bin": where the agent's CLI is looked for when no path is set.
    nonisolated static func candidateFolders(_ agent: AgentKind) -> String {
        agent.defaultCandidates.map { ($0 as NSString).deletingLastPathComponent }.joined(separator: ", ")
    }

    private func version(of agent: AgentKind) -> String? {
        switch agent {
        case .claude: claudeVersion
        case .codex: codexVersion
        case .antigravity: antigravityVersion
        }
    }

    /// The agent's efforts, plus a stored one it does not list (typed before the picker existed).
    private func effortOptions(for agent: AgentKind) -> [String] {
        let efforts = AgentModelChoices.efforts(for: agent)
        guard let stored = settings.defaultEffort(for: agent), !efforts.contains(stored) else { return efforts }
        return efforts + [stored]
    }

    // MARK: - Ses

    private var audioTab: some View {
        @Bindable var store = settings
        return Form {
            Section(L10n.t("Transcription")) {
                Picker(L10n.t("Language"), selection: $store.sttLanguage) {
                    Text(L10n.t("Detect automatically")).tag(TranscriptionLanguage.automatic)
                    Divider()
                    ForEach(Self.languageChoices(sttLanguages, including: settings.sttLanguage), id: \.self) { code in
                        Text(Self.languageName(code)).tag(code)
                    }
                }
                Picker(L10n.t("Model"), selection: $store.sttModel) {
                    ForEach(SettingsStore.sttModelChoices, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                LabeledContent(L10n.t("Status")) {
                    Text(Self.modelStateLabel(transcriberState))
                        .foregroundStyle(Self.modelStateTint(transcriberState))
                }
                if let modelDiskUsage, !Self.isDownloading(transcriberState) {
                    LabeledContent(L10n.t("On disk"), value: modelDiskUsage)
                }
                modelControls
                Text(
                    L10n.t(
                        "Voice notes can be recorded before the model is ready; they wait and are transcribed once it arrives."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                Self.deleteModelTitle(transcriberState), isPresented: $confirmsModelDeletion,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Delete"), role: .destructive) { onDeleteModel() }
                Button(L10n.t("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Voice notes are not transcribed until the model is downloaded again."))
            }

            Section(L10n.t("Input Device")) {
                if inputDevices.isEmpty {
                    LabeledContent(L10n.t("Device UID")) {
                        TextField(
                            L10n.t("system default"),
                            text: Binding(
                                get: { settings.inputDeviceUID ?? "" },
                                set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    }
                } else {
                    Picker(
                        L10n.t("Device"),
                        selection: Binding<String>(
                            get: { settings.inputDeviceUID ?? "" },
                            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })
                    ) {
                        Text(L10n.t("System default")).tag("")
                        ForEach(inputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                Text(L10n.t("When empty, the system's default microphone is used."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Experimental")) {
                Toggle(L10n.t("Title suggestions with Foundation Models (v1.1)"), isOn: $store.foundationModelsEnabled)
                    .disabled(true)
                Text(
                    L10n.t(
                        "Off in v1: the FoundationModels macros do not build with the Command Line Tools (spec §6.2). Apple Intelligence's state shows in the diagnostics bar."
                    )
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
            Section(L10n.t("Status")) {
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
                                Button(L10n.t("Allow")) { Task { await permissions.request(kind) } }
                            }
                            Button(L10n.t("System Settings")) { permissions.openSettings(kind) }
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
                Button(L10n.t("Refresh")) { Task { await permissions.refresh() } }
            } footer: {
                Text(
                    L10n.t(
                        "macOS may ask to confirm Screen Recording again about once a month; that is expected. Restart Shotcue after granting a permission."
                    )
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    /// Revize-1: the download can be paused and resumed, and the model or a partial download deleted.
    @ViewBuilder
    private var modelControls: some View {
        switch transcriberState {
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress) {
                    Text(L10n.t("Downloading the model"))
                }
                .progressViewStyle(.linear)
                Button(L10n.t("Pause"), systemImage: "pause.fill") { onPauseDownload() }
            }
        case .paused:
            HStack {
                Button(L10n.t("Resume"), systemImage: "arrow.down.circle") { onDownloadModel() }
                    .buttonStyle(.glassProminent)
                Button(L10n.t("Delete Download"), systemImage: "trash", role: .destructive) { confirmsModelDeletion = true }
            }
        case .ready:
            Button(L10n.t("Delete Model"), systemImage: "trash", role: .destructive) { confirmsModelDeletion = true }
        case .failed:
            HStack {
                Button(L10n.t("Try Again"), systemImage: "arrow.clockwise") { onDownloadModel() }
                    .buttonStyle(.glassProminent)
                if modelDiskUsage != nil {
                    Button(L10n.t("Delete Download"), systemImage: "trash", role: .destructive) {
                        confirmsModelDeletion = true
                    }
                }
            }
        case .notDownloaded:
            Button(modelDownloadSize.map { L10n.t("Download Model (\($0))") } ?? L10n.t("Download Model")) { onDownloadModel() }
                .buttonStyle(.glassProminent)
        }
    }

    // MARK: - Pure copy helpers

    /// The codes sorted by their names in the interface language, plus a stored one the list lacks.
    nonisolated static func languageChoices(
        _ codes: [String], including stored: String, locale: Locale = LocalizationOverride.locale
    ) -> [String] {
        var all = Set(codes)
        if !TranscriptionLanguage.isAutomatic(stored) { all.insert(stored) }
        return all.sorted { languageName($0, locale: locale).localizedStandardCompare(languageName($1, locale: locale)) == .orderedAscending }
    }

    /// "Turkish" / "Türkçe" for "tr", in the interface language; the code itself when the system has no name.
    nonisolated static func languageName(_ code: String, locale: Locale = LocalizationOverride.locale) -> String {
        locale.localizedString(forLanguageCode: code).map { $0.capitalized(with: locale) } ?? code
    }

    nonisolated static func isDownloading(_ state: TranscriberModelState) -> Bool {
        if case .downloading = state { return true }
        return false
    }

    nonisolated public static func deleteModelTitle(_ state: TranscriberModelState) -> String {
        state == .ready ? L10n.t("Delete the model?") : L10n.t("Delete the partial download?")
    }

    nonisolated public static func modelStateLabel(_ state: TranscriberModelState) -> String {
        switch state {
        case .notDownloaded: L10n.t("Not downloaded")
        case .downloading(let progress): L10n.t("Downloading… \(Int((progress * 100).rounded()))%")
        case .paused(let progress?): L10n.t("Paused \(Int((progress * 100).rounded()))%")
        case .paused(nil): L10n.t("Paused")
        case .ready: L10n.t("Ready")
        case .failed(let message): L10n.t("Error: \(message)")
        }
    }

    nonisolated public static func modelStateTint(_ state: TranscriberModelState) -> Color {
        switch state {
        case .notDownloaded: .orange
        case .downloading: .blue
        case .paused: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    nonisolated public static func permissionModeLabel(_ mode: ClaudePermissionMode) -> String {
        switch mode {
        case .bypassPermissions: L10n.t("bypassPermissions (applies without asking)")
        case .acceptEdits: L10n.t("acceptEdits (accepts edits)")
        case .dontAsk: L10n.t("dontAsk (read-only)")
        }
    }
}
