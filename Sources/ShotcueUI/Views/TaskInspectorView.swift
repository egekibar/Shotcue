import AppKit
import ShotcueCore
import SwiftUI

/// The task inspector (spec §5.4, research 05 §C.3): images, title, note, transcript, project, mode,
/// model override, scheduling, run history, the live/recorded log and the handoff actions.
public struct TaskInspectorView: View {
    public let store: TaskDetailStore
    public let thumbnails: ThumbnailCache?

    /// The text field being edited. Its draft is committed when focus leaves it (and on submit).
    @FocusState private var focusedField: TaskDetailStore.EditableField?

    public init(store: TaskDetailStore, thumbnails: ThumbnailCache? = nil) {
        self.store = store
        self.thumbnails = thumbnails
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                capturesSection
                titleAndNoteSection
                transcriptSection
                routingSection
                schedulingSection
                runsSection
                handoffSection
            }
            .padding(14)
        }
        .onChange(of: focusedField) { previous, _ in
            guard let previous else { return }
            Task { await store.commit(previous) }
        }
        // Selecting another task swaps the store; the old subtree (and its drafts) must go away with it.
        .onDisappear { [store] in
            Task { await store.commitDrafts() }
        }
        .id(store.taskID)
        .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        .alert(
            L10n.t("Something went wrong"),
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } })
        ) {
            Button(L10n.t("OK")) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { store.isDiffPresented },
                set: { if !$0 { store.closeDiff() } })
        ) {
            DiffSheet(
                document: store.diffDocument ?? DiffDocument(), text: store.diffText ?? "",
                onClose: { store.closeDiff() })
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        if let task = store.task {
            HStack(spacing: 8) {
                StatusChip(status: task.status)
                Spacer(minLength: 8)
                if store.canCancel {
                    Button(L10n.t("Cancel Run"), systemImage: "stop.circle") {
                        Task { await store.cancel() }
                    }
                    .buttonStyle(.glass)
                }
                if task.status == .failed || task.status == .cancelled || task.status == .done {
                    Button(L10n.t("Run Again"), systemImage: "arrow.clockwise") {
                        Task { await store.retry() }
                    }
                    .buttonStyle(.glass)
                    .disabled(store.isWaitingForTranscript)
                }
                Button(L10n.t("Send Now"), systemImage: "paperplane.fill") {
                    Task { await store.sendNow() }
                }
                .buttonStyle(.glassProminent)
                .disabled(!store.canSend)
            }
            if store.isWaitingForTranscript {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("The voice note is being transcribed… The task will be sent when it is done."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(L10n.t("The task could not be loaded.")).foregroundStyle(.secondary)
        }
    }

    // MARK: - Captures

    @ViewBuilder
    private var capturesSection: some View {
        if !store.captures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(L10n.t("IMAGES"))
                ForEach(store.captures) { capture in
                    captureRow(capture)
                }
            }
        }
    }

    private func captureRow(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let image = thumbnails?.image(relPath: capture.thumbRelPath ?? capture.relPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 160)
                        .overlay {
                            Image(systemName: "photo").imageScale(.large).foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 8))
            // ⌘C copies the image only while this preview has focus, through the standard Copy command, so
            // the text fields and the run log keep their own ⌘C (no global key equivalent on a button).
            .focusable()
            .onCopyCommand { copyProviders(for: capture) }
            .help(L10n.t("Select the image and press ⌘C to copy it."))

            HStack(spacing: 8) {
                Text("\(capture.width)×\(capture.height) @\(Int(capture.scale))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button(L10n.t("Copy"), systemImage: "doc.on.doc") {
                    store.copyImage(captureID: capture.id)
                }
                Button(L10n.t("Show in Finder"), systemImage: "folder") {
                    store.revealInFinder(captureID: capture.id)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tint)
        }
    }

    /// What Copy puts on the pasteboard for a focused capture: the PNG file itself.
    private func copyProviders(for capture: Capture) -> [NSItemProvider] {
        guard let provider = NSItemProvider(contentsOf: store.absoluteURL(for: capture.relPath)) else { return [] }
        return [provider]
    }

    // MARK: - Title and note

    @ViewBuilder
    private var titleAndNoteSection: some View {
        if let task = store.task {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(L10n.t("TITLE"))
                TextField(
                    L10n.t("Title"),
                    text: Binding(get: { store.titleDraft }, set: { store.editTitle($0) }),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .title)
                .onSubmit { Task { await store.commit(.title) } }
                .disabled(!store.isEditable)
                if !task.titleEditedByUser {
                    Text(L10n.t("Derived from the note. Edit it to keep your own."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionTitle(L10n.t("NOTE"))
                TextEditor(text: Binding(get: { store.noteDraft }, set: { store.editNote($0) }))
                    .focused($focusedField, equals: .note)
                    .font(.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                    .disabled(!store.isEditable)
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        if !store.voiceNotes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.t("VOICE NOTE"))
                ForEach(store.voiceNotes) { note in
                    voiceNoteRow(note)
                }
            }
        }
    }

    private func voiceNoteRow(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(Formatting.stopwatch(note.durationSec), systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                transcriptStateBadge(note)
                Spacer(minLength: 6)
                Button(L10n.t("Play"), systemImage: "play.circle") {
                    store.openAudio(voiceNoteID: note.id)
                }
                Button(L10n.t("Transcribe Again"), systemImage: "arrow.clockwise") {
                    Task { await store.retranscribe(voiceNoteID: note.id) }
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tint)

            TextEditor(
                text: Binding(
                    get: { store.transcriptDraft(for: note.id) },
                    set: { store.editTranscript(voiceNoteID: note.id, text: $0) })
            )
            .focused($focusedField, equals: .transcript(note.id))
            .font(.callout)
            .frame(minHeight: 60)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
        }
    }

    /// A pending note says what it waits for: the queue ("çevriliyor") or the model ("model indirilmedi", with the
    /// download one click away — spec §6.2).
    @ViewBuilder
    private func transcriptStateBadge(_ note: VoiceNote) -> some View {
        let status = store.transcriptStatus(for: note)
        switch status {
        case .transcribing, .modelDownloading:
            Label(status.label ?? "", systemImage: "ellipsis.circle")
                .font(.caption2).foregroundStyle(.orange)
        case .waitingForModel, .modelUnavailable:
            Label(status.label ?? "", systemImage: "arrow.down.circle")
                .font(.caption2).foregroundStyle(.orange)
            if let model = store.modelStore {
                Button(L10n.t("Download Model (\(model.downloadSizeText))")) { model.startDownload() }
                    .font(.caption2)
            }
        case .modelPaused:
            Label(status.label ?? "", systemImage: "pause.circle")
                .font(.caption2).foregroundStyle(.orange)
            if let model = store.modelStore {
                Button(L10n.t("Resume Download")) { model.startDownload() }
                    .font(.caption2)
            }
        case .failed:
            Label(status.label ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        case .edited:
            Label(status.label ?? "", systemImage: "pencil")
                .font(.caption2).foregroundStyle(.secondary)
        case .done:
            EmptyView()
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var routingSection: some View {
        if let task = store.task {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.t("ROUTING"))
                Picker(
                    L10n.t("Project"),
                    selection: Binding<UUID?>(
                        get: { task.projectID },
                        set: { newValue in Task { await store.setProject(newValue) } })
                ) {
                    Text(L10n.t("None")).tag(UUID?.none)
                    ForEach(store.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .disabled(!store.isEditable)

                if let path = store.project?.path {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }

                Picker(
                    L10n.t("Mode"),
                    selection: Binding<TaskMode>(
                        get: { task.mode },
                        set: { newValue in Task { await store.setMode(newValue) } })
                ) {
                    Text(L10n.t("Analyze")).tag(TaskMode.analyze)
                    Text(L10n.t("Implement")).tag(TaskMode.implement)
                }
                .pickerStyle(.segmented)
                .disabled(!store.isEditable)

                LabeledContent(L10n.t("Agent")) {
                    Text(store.agent.displayName)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 240, alignment: .leading)

                Picker(
                    L10n.t("Model"),
                    selection: Binding<String>(
                        get: { task.modelOverride ?? "" },
                        set: { newValue in Task { await store.setModelOverride(newValue) } })
                ) {
                    ForEach(
                        AgentModelChoices.options(for: store.agent, including: task.modelOverride), id: \.self
                    ) { model in
                        Text(model.isEmpty ? L10n.t("Project default") : model).tag(model)
                    }
                }
                // Leading, like the Proje and Mod rows: a flexible frame centres its content by default.
                .frame(maxWidth: 240, alignment: .leading)
                .disabled(!store.isEditable)
            }
        }
    }

    // MARK: - Scheduling

    @ViewBuilder
    private var schedulingSection: some View {
        if store.task != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.t("SCHEDULE"))
                if let scheduledAt = store.scheduledFor {
                    HStack(spacing: 8) {
                        Label(Formatting.dateAndTime(scheduledAt), systemImage: "clock")
                            .font(.callout)
                        Spacer(minLength: 6)
                        Button(L10n.t("Remove")) { Task { await store.unschedule() } }
                            .buttonStyle(.glass)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button(L10n.t("Pick a Date…"), systemImage: "calendar") {
                            store.isSchedulePresented = true
                        }
                        .buttonStyle(.glass)
                        .popover(
                            isPresented: Binding(
                                get: { store.isSchedulePresented },
                                set: { store.isSchedulePresented = $0 })
                        ) {
                            ScheduleDateForm(
                                date: Binding(get: { store.scheduleDate }, set: { store.scheduleDate = $0 }),
                                onCancel: { store.isSchedulePresented = false },
                                onSchedule: { when in
                                    store.isSchedulePresented = false
                                    Task { await store.schedule(at: when) }
                                })
                        }
                        Button(L10n.t("Add to Daily Queue"), systemImage: "calendar.badge.clock") {
                            Task { await store.addToDailyQueue() }
                        }
                        .buttonStyle(.glass)
                        .disabled(!store.canAddToDailyQueue)
                    }
                }
            }
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("RUNS"))
            if store.runs.isEmpty {
                Text(L10n.t("This task was never sent."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.runs) { run in
                    runRow(run)
                }
            }
            if !store.displayedEvents.isEmpty || store.isDisplayingLiveRun {
                RunLogView(events: store.displayedEvents, isLive: store.isDisplayingLiveRun)
                    .frame(minHeight: 140, maxHeight: 280)
            }
        }
    }

    private func runRow(_ run: Run) -> some View {
        Button {
            Task { await store.toggleRun(run.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RunStateChip(state: run.state)
                    Spacer(minLength: 6)
                    Text(Formatting.relativeDate(run.startedAt, now: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // The row opens and closes its log; the chevron says which.
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(store.selectedRunID == run.id ? 90 : 0))
                        .animation(.snappy(duration: 0.15), value: store.selectedRunID)
                }
                HStack(spacing: 10) {
                    Text(run.agent.displayName)
                    Text(Formatting.turns(run.numTurns))
                    Text(Formatting.duration(run.finishedAt.map { $0.timeIntervalSince(run.startedAt) }))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let resultText = run.resultText, !resultText.isEmpty {
                    Text(resultText)
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
                // Final review I6: the row keeps a machine code; it is read in Turkish, with what to do about it
                // (spec §8: after a limit stop, raise the limit) and the raw detail or unknown code underneath.
                if let failure = RunErrorText.describe(
                    run.error, exitCode: run.exitCode, numTurns: run.numTurns, agent: run.agent)
                {
                    Text(failure.message)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.red)
                    if let suggestion = failure.suggestion {
                        Text(suggestion)
                            .font(.caption)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    }
                    // claude's error line (`claude_error`) is already the result text above, as primary text.
                    if let detail = failure.detail, !failure.detailIsShown(in: run.resultText) {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(store.selectedRunID == run.id ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .help(store.selectedRunID == run.id ? L10n.t("Hide Log") : L10n.t("Show Log"))
    }

    // MARK: - Handoff

    /// Equal-width buttons that flow into two columns when the inspector is wide and one when it is narrow (it
    /// resizes between 300 and 560 pt), so a long title never squeezes its neighbour.
    private var handoffSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L10n.t("HAND-OFF"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                handoffButton(L10n.t("Continue in Terminal"), systemImage: "terminal", help: Self.terminalResumeHelp) {
                    Task { await store.openInTerminal() }
                }
                .disabled(store.sessionID == nil)

                if store.showsClaudeResume {
                    handoffButton(L10n.t("Continue in Claude"), systemImage: "arrow.uturn.forward", help: Self.claudeResumeHelp)
                    {
                        Task { await store.openInDesktop() }
                    }
                    .disabled(!store.canOpenInDesktop)
                }

                handoffButton(
                    L10n.t("Start Over in Claude"), systemImage: "arrow.counterclockwise",
                    help: Self.claudeRestartHelp(projectAgent: store.agent)
                ) {
                    Task { await store.openComposer() }
                }
                .disabled(store.project == nil)

                if let run = store.runs.first(where: { $0.id == store.selectedRunID }) ?? store.latestRun {
                    handoffButton(
                        L10n.t("Show Changes"), systemImage: "plus.forwardslash.minus", help: Self.diffHelp
                    ) {
                        Task { await store.showDiff(runID: run.id) }
                    }
                    .disabled(!store.canShowDiff(for: run) || store.isLoadingDiff)
                }
            }
        }
        .buttonStyle(.glass)
        .font(.callout)
    }

    private func handoffButton(
        _ title: String, systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // A fixed icon column, so the titles line up although the symbols differ in width.
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: systemImage).frame(width: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help)
    }

    // MARK: - Handoff copy

    nonisolated static var terminalResumeHelp: String {
        L10n.t("Continues the last run's session in Terminal, with the task's own agent.")
    }
    nonisolated static var claudeResumeHelp: String {
        L10n.t(
            "Moves the last run's session into the Claude desktop app, so you carry on where it stopped, with its history."
        )
    }
    nonisolated static var diffHelp: String { L10n.t("Shows this run's code changes, file by file.") }

    /// The composer always opens the Claude desktop app, whatever agent the project runs.
    nonisolated static func claudeRestartHelp(projectAgent: AgentKind) -> String {
        let base = L10n.t(
            "Opens a new session in the Claude desktop app with the prompt filled in; you press send. The earlier run's history does not come along."
        )
        guard projectAgent != .claude else { return base }
        return base + " "
            + L10n.t("The task starts with Claude Code even though the project uses \(projectAgent.displayName).")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
