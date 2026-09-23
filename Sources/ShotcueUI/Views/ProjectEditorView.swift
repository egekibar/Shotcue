import ShotcueCore
import SwiftUI
import UniformTypeIdentifiers

/// Create/edit sheet for a project (Task 14). All state lives in `LibraryStore.projectDraft`.
public struct ProjectEditorView: View {
    public let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    public var body: some View {
        @Bindable var bindable = store
        if let draft = Binding($bindable.projectDraft) {
            form(draft)
                .fileImporter(
                    isPresented: $bindable.isProjectFolderPickerPresented,
                    allowedContentTypes: [.folder]
                ) { result in
                    if case .success(let url) = result { store.projectFolderPicked(url) }
                }
        }
    }

    private func form(_ draft: Binding<ProjectDraft>) -> some View {
        let validation = draft.wrappedValue.validationMessage()
        let agent = draft.wrappedValue.effectiveAgent(default: store.defaultAgent)
        return VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Proje") {
                    TextField("Ad", text: draft.name)
                    LabeledContent("Klasör") {
                        HStack {
                            TextField("/Users/…/proje", text: draft.path)
                                .textFieldStyle(.roundedBorder)
                            Button("Seç…") { store.isProjectFolderPickerPresented = true }
                        }
                    }
                }
                Section("Varsayılanlar") {
                    Picker("Ajan", selection: agentBinding(draft)) {
                        Text("Genel ayar (\(store.defaultAgent.displayName))").tag("")
                        ForEach(AgentKind.allCases) { agent in
                            Text(agent.displayName).tag(agent.rawValue)
                        }
                    }
                    Picker("Mod", selection: draft.defaultMode) {
                        Text("Analiz").tag(TaskMode.analyze)
                        Text("Uygula").tag(TaskMode.implement)
                    }
                    .pickerStyle(.segmented)
                    Picker("Model", selection: draft.defaultModel) {
                        ForEach(
                            AgentModelChoices.options(for: agent, including: draft.wrappedValue.defaultModel),
                            id: \.self
                        ) { model in
                            Text(model.isEmpty ? "Genel ayar" : model).tag(model)
                        }
                    }
                    Picker("Effort", selection: draft.defaultEffort) {
                        ForEach(effortOptions(draft.wrappedValue.defaultEffort, agent: agent), id: \.self) { effort in
                            Text(effort.isEmpty ? "Genel ayar" : effort).tag(effort)
                        }
                    }
                }
                Section("Günlük kuyruk") {
                    Toggle("Her gün kuyruğu çalıştır", isOn: draft.dailyEnabled)
                    DatePicker("Saat", selection: timeBinding(draft), displayedComponents: .hourAndMinute)
                        .disabled(!draft.wrappedValue.dailyEnabled)
                    Text(
                        "Saat bugün geçtiyse ilk çalışma yarın olur. Kuyruk, projedeki Hazır görevleri sırayla gönderir."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Güvenlik ağı") {
                    Toggle("Her çalıştırmayı yeni branch'te başlat", isOn: draft.runInBranch)
                    Toggle("Çalıştırmadan önce değişiklikleri stash'le", isOn: draft.stashBeforeRun)
                    Text(
                        "Bunlardan biri açıkken bu projenin görevleri aynı anda değil, sırayla çalışır; kapalıyken eş zamanlı çalışabilir."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let validation {
                    Label(validation, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Vazgeç", role: .cancel) { store.cancelProjectEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.wrappedValue.isNew ? "Oluştur" : "Kaydet") {
                    Task { await store.saveProjectDraft() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(validation != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    /// Switching the agent clears a model or effort the new agent does not take, so the pickers never hold a value
    /// the run would skip.
    private func agentBinding(_ draft: Binding<ProjectDraft>) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue.agent },
            set: { newValue in
                draft.wrappedValue.agent = newValue
                let agent = draft.wrappedValue.effectiveAgent(default: store.defaultAgent)
                if !draft.wrappedValue.defaultModel.isEmpty,
                    !AgentModelChoices.model(draft.wrappedValue.defaultModel, appliesTo: agent)
                {
                    draft.wrappedValue.defaultModel = ""
                }
                if !AgentModelChoices.efforts(for: agent).contains(draft.wrappedValue.defaultEffort) {
                    draft.wrappedValue.defaultEffort = ""
                }
            })
    }

    /// The agent's efforts, plus a stored one it does not list so the picker can still show it.
    private func effortOptions(_ stored: String, agent: AgentKind) -> [String] {
        let efforts = AgentModelChoices.efforts(for: agent)
        return stored.isEmpty || efforts.contains(stored) ? efforts : efforts + [stored]
    }

    /// Hour/minute of the draft shown through a `DatePicker` (display only; the date part is ignored).
    private func timeBinding(_ draft: Binding<ProjectDraft>) -> Binding<Date> {
        let calendar = store.calendar
        return Binding(
            get: {
                calendar.date(
                    bySettingHour: draft.wrappedValue.dailyHour,
                    minute: draft.wrappedValue.dailyMinute, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let parts = calendar.dateComponents([.hour, .minute], from: newValue)
                draft.wrappedValue.dailyHour = parts.hour ?? ProjectDraft.defaultDailyTime.hour
                draft.wrappedValue.dailyMinute = parts.minute ?? ProjectDraft.defaultDailyTime.minute
            })
    }
}
