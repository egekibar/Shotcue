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
                    Picker("Mod", selection: draft.defaultMode) {
                        Text("Analiz").tag(TaskMode.analyze)
                        Text("Uygula").tag(TaskMode.implement)
                    }
                    .pickerStyle(.segmented)
                    Picker("Model", selection: draft.defaultModel) {
                        ForEach(
                            ClaudeModelChoices.options(including: draft.wrappedValue.defaultModel), id: \.self
                        ) { model in
                            Text(model.isEmpty ? "Genel ayar" : model).tag(model)
                        }
                    }
                    Picker("Effort", selection: draft.defaultEffort) {
                        ForEach(ProjectDraft.effortChoices, id: \.self) { effort in
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
