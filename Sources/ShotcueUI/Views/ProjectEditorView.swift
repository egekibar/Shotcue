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
        // Not `Binding($bindable.projectDraft)`: that force-unwraps, and saving sets the draft to nil while the
        // sheet is still animating out, so its fields would read nil and crash. Fall back to the last draft.
        if let current = store.projectDraft {
            form(
                Binding(
                    get: { store.projectDraft ?? current },
                    set: { store.editProjectDraft($0) })
            )
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
                Section(L10n.t("Project")) {
                    TextField(L10n.t("Name"), text: draft.name)
                    LabeledContent(L10n.t("Folder")) {
                        HStack {
                            TextField(L10n.t("/Users/…/project"), text: draft.path)
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.t("Choose…")) { store.isProjectFolderPickerPresented = true }
                        }
                    }
                }
                Section(L10n.t("Defaults")) {
                    Picker(L10n.t("Agent"), selection: agentBinding(draft)) {
                        Text(L10n.t("Global setting (\(store.defaultAgent.displayName))")).tag("")
                        ForEach(AgentKind.allCases) { agent in
                            Text(agent.displayName).tag(agent.rawValue)
                        }
                    }
                    Picker(L10n.t("Mode"), selection: draft.defaultMode) {
                        Text(L10n.t("Analyze")).tag(TaskMode.analyze)
                        Text(L10n.t("Implement")).tag(TaskMode.implement)
                    }
                    .pickerStyle(.segmented)
                    Picker(L10n.t("Model"), selection: draft.defaultModel) {
                        ForEach(
                            AgentModelChoices.options(for: agent, including: draft.wrappedValue.defaultModel),
                            id: \.self
                        ) { model in
                            Text(model.isEmpty ? L10n.t("Global setting") : model).tag(model)
                        }
                    }
                    Picker(L10n.t("Effort"), selection: draft.defaultEffort) {
                        ForEach(effortOptions(draft.wrappedValue.defaultEffort, agent: agent), id: \.self) { effort in
                            Text(effort.isEmpty ? L10n.t("Global setting") : effort).tag(effort)
                        }
                    }
                }
                Section(L10n.t("Daily Queue")) {
                    Toggle(L10n.t("Run the queue every day"), isOn: draft.dailyEnabled)
                    DatePicker(L10n.t("Time"), selection: timeBinding(draft), displayedComponents: .hourAndMinute)
                        .disabled(!draft.wrappedValue.dailyEnabled)
                    Text(
                        L10n.t("If the time has passed today, the first run is tomorrow. The queue sends the project's Ready tasks in order.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section(L10n.t("Safety Nets")) {
                    Toggle(L10n.t("Start every run on a new branch"), isOn: draft.runInBranch)
                    Toggle(L10n.t("Stash changes before every run"), isOn: draft.stashBeforeRun)
                    Text(
                        L10n.t("With either one on, this project's tasks run one at a time; with both off they can run side by side.")
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
                Button(L10n.t("Cancel"), role: .cancel) { store.cancelProjectEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.wrappedValue.isNew ? L10n.t("Create") : L10n.t("Save")) {
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
