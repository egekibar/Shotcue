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
            "Bir şey ters gitti",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } })
        ) {
            Button("Tamam") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
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
                    Button("İptal", systemImage: "stop.circle") {
                        Task { await store.cancel() }
                    }
                    .buttonStyle(.glass)
                }
                if task.status == .failed || task.status == .cancelled || task.status == .done {
                    Button("Yeniden çalıştır", systemImage: "arrow.clockwise") {
                        Task { await store.retry() }
                    }
                    .buttonStyle(.glass)
                }
                Button("Şimdi gönder", systemImage: "paperplane.fill") {
                    Task { await store.sendNow() }
                }
                .buttonStyle(.glassProminent)
                .disabled(!store.canSend)
            }
        } else {
            Text("Görev yüklenemedi.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Captures

    @ViewBuilder
    private var capturesSection: some View {
        if !store.captures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("GÖRSELLER")
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

            HStack(spacing: 8) {
                Text("\(capture.width)×\(capture.height) @\(Int(capture.scale))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Kopyala", systemImage: "doc.on.doc") {
                    store.copyImage(captureID: capture.id)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Finder'da göster", systemImage: "folder") {
                    store.revealInFinder(captureID: capture.id)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tint)
        }
    }

    // MARK: - Title and note

    @ViewBuilder
    private var titleAndNoteSection: some View {
        if let task = store.task {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("BAŞLIK")
                TextField(
                    "Başlık",
                    text: Binding(get: { store.titleDraft }, set: { store.editTitle($0) }),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .title)
                .onSubmit { Task { await store.commit(.title) } }
                .disabled(!store.isEditable)
                if !task.titleEditedByUser {
                    Text("Nottan otomatik türetiliyor. Düzenlersen sabitlenir.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionTitle("NOT")
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
                sectionTitle("SESLİ NOT")
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
                Button("Aç", systemImage: "play.circle") {
                    store.openAudio(voiceNoteID: note.id)
                }
                Button("Yeniden çevir", systemImage: "arrow.clockwise") {
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

    @ViewBuilder
    private func transcriptStateBadge(_ note: VoiceNote) -> some View {
        switch note.transcriptState {
        case .pending:
            Label("çevriliyor", systemImage: "ellipsis.circle")
                .font(.caption2).foregroundStyle(.orange)
        case .failed:
            Label("çevrilemedi", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        case .done:
            if note.editedByUser {
                Label("düzenlendi", systemImage: "pencil")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var routingSection: some View {
        if let task = store.task {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("YÖNLENDİRME")
                Picker(
                    "Proje",
                    selection: Binding<UUID?>(
                        get: { task.projectID },
                        set: { newValue in Task { await store.setProject(newValue) } })
                ) {
                    Text("Seçilmedi").tag(UUID?.none)
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
                    "Mod",
                    selection: Binding<TaskMode>(
                        get: { task.mode },
                        set: { newValue in Task { await store.setMode(newValue) } })
                ) {
                    Text("Analiz").tag(TaskMode.analyze)
                    Text("Uygula").tag(TaskMode.implement)
                }
                .pickerStyle(.segmented)
                .disabled(!store.isEditable)

                LabeledContent("Model") {
                    TextField(
                        "proje varsayılanı",
                        text: Binding(
                            get: { task.modelOverride ?? "" },
                            set: { newValue in Task { await store.setModelOverride(newValue) } })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .disabled(!store.isEditable)
                }
            }
        }
    }

    // MARK: - Scheduling

    @ViewBuilder
    private var schedulingSection: some View {
        if let task = store.task {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("ZAMANLAMA")
                if let scheduledAt = task.scheduledAt {
                    HStack(spacing: 8) {
                        Label(Formatting.dateAndTime(scheduledAt), systemImage: "clock")
                            .font(.callout)
                        Spacer(minLength: 6)
                        Button("Kaldır") { Task { await store.unschedule() } }
                            .buttonStyle(.glass)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Tarih seç…", systemImage: "calendar") {
                            store.isSchedulePresented = true
                        }
                        .buttonStyle(.glass)
                        .popover(
                            isPresented: Binding(
                                get: { store.isSchedulePresented },
                                set: { store.isSchedulePresented = $0 })
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                DatePicker(
                                    "Tarih ve saat",
                                    selection: Binding(
                                        get: { store.scheduleDate },
                                        set: { store.scheduleDate = $0 })
                                )
                                .datePickerStyle(.graphical)
                                HStack {
                                    Spacer()
                                    Button("Vazgeç") { store.isSchedulePresented = false }
                                    Button("Zamanla") {
                                        let when = store.scheduleDate
                                        store.isSchedulePresented = false
                                        Task { await store.schedule(at: when) }
                                    }
                                    .buttonStyle(.glassProminent)
                                }
                            }
                            .padding(16)
                            .frame(width: 320)
                        }
                        Button("Günlük kuyruğa al", systemImage: "calendar.badge.clock") {
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
            sectionTitle("ÇALIŞMALAR")
            if store.runs.isEmpty {
                Text("Bu görev hiç gönderilmedi.")
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
            Task { await store.selectRun(run.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RunStateChip(state: run.state)
                    Spacer(minLength: 6)
                    Text(Formatting.relativeDate(run.startedAt, now: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(Formatting.cost(run.costUSD))
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
                if let error = run.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.red)
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
    }

    // MARK: - Handoff

    private var handoffSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("AKTARIM")
            HStack(spacing: 8) {
                Button("Terminalde devam et", systemImage: "terminal") {
                    Task { await store.openInTerminal() }
                }
                .disabled(store.sessionID == nil)
                Button("Desktop'ta aç", systemImage: "app.badge") {
                    Task { await store.openInDesktop() }
                }
                .disabled(store.sessionID == nil)
            }
            Button("Desktop composer'da aç", systemImage: "square.and.pencil") {
                Task { await store.openComposer() }
            }
            .disabled(store.project == nil)
        }
        .buttonStyle(.glass)
        .font(.callout)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
