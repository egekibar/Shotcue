import AppKit
import ShotcueCore
import SwiftUI

/// Post-capture quick panel (spec §5.1, research 05 §C.1 wireframe).
///
/// The panel's `NSPanel` (non-activating, `canBecomeKey` override, `NSEvent` monitors) is Plan 06's
/// job; this view only supplies the SwiftUI content, the focus hand-off and the shortcuts.
public struct QuickPanelView: View {
    public let store: QuickPanelStore
    public let thumbnails: ThumbnailCache?

    /// `@FocusState` is a plain property wrapper (not a macro), so it compiles with CLT.
    @FocusState private var noteFocused: Bool

    public init(store: QuickPanelStore, thumbnails: ThumbnailCache? = nil) {
        self.store = store
        self.thumbnails = thumbnails
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 12) {
                preview
                routing
            }
            noteEditor
            recordingRow
            if store.showsModelNotice, let model = store.modelStore {
                modelNotice(model)
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            actions
        }
        .padding(16)
        .frame(width: 560)
        .glassEffect(in: .rect(cornerRadius: 16))
        // Focus cannot be taken on the first frame inside a non-activating panel (research 02 §6).
        .task {
            await Task.yield()
            noteFocused = true
        }
        .onExitCommand { store.dismiss() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.viewfinder").foregroundStyle(.tint)
            Text(L10n.t("New Capture")).font(.headline)
            Spacer(minLength: 8)
            Text(L10n.t("⌘⏎ save · ⌘⇧⏎ save and send · esc close"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            if let image = thumbnails?.image(at: store.thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .imageScale(.large)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 248, height: 152)
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - Project and mode

    private var routing: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("PROJECT"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(
                    L10n.t("Project"),
                    selection: Binding<UUID?>(
                        get: { store.selectedProjectID },
                        set: { store.selectedProjectID = $0 })
                ) {
                    Text(L10n.t("None (inbox)")).tag(UUID?.none)
                    ForEach(store.projects) { project in
                        projectLabel(project).tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                if let path = store.selectedProject?.path {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("MODE"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(
                    L10n.t("Mode"),
                    selection: Binding<TaskMode>(
                        get: { store.mode },
                        set: { store.mode = $0 })
                ) {
                    Text(L10n.t("Analyze")).tag(TaskMode.analyze)
                    Text(L10n.t("Implement")).tag(TaskMode.implement)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer(minLength: 0)
            projectShortcutButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func projectLabel(_ project: Project) -> some View {
        if let index = store.projectShortcutIndex(for: project.id) {
            Text("\(project.name)  ⌘\(index)")
        } else {
            Text(project.name)
        }
    }

    /// Invisible buttons that give `⌘1…⌘9` a place to land while the panel is key (spec §5.1).
    private var projectShortcutButtons: some View {
        ZStack {
            ForEach(Array(store.projects.prefix(9).enumerated()), id: \.element.id) { pair in
                Button("") {
                    store.selectProject(atShortcut: pair.offset + 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(pair.offset + 1)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Note

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(get: { store.noteText }, set: { store.noteText = $0 }))
                .font(.body)
                .frame(minHeight: 76)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .focused($noteFocused)
            if store.noteText.isEmpty {
                Text(L10n.t("Write a note…"))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Recording

    private var recordingRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.toggleRecording() }
            } label: {
                Label(
                    store.isRecording ? L10n.t("Stop") : L10n.t("Voice Note"),
                    systemImage: store.isRecording ? "stop.circle.fill" : "mic.circle")
            }
            .buttonStyle(.glass)
            .tint(store.isRecording ? .red : .accentColor)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!store.canRecord)

            LevelMeterView(level: store.level)
                .opacity(store.isRecording ? 1 : 0.35)

            Text(Formatting.stopwatch(store.recordingSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if !store.voiceNotes.isEmpty {
                Label(L10n.t("\(store.voiceNotes.count) recordings"), systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if store.microphoneState == .denied {
                Text(L10n.t("No microphone access"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if store.microphoneState == .notDetermined {
                Button(L10n.t("Allow Microphone")) {
                    Task { await store.requestMicrophone() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            } else {
                Text(L10n.t("on-device transcription"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Spec §6.2: a recording made without the model is kept and waits; the panel says so and offers the download
    /// (its size shown, started only by this click) instead of promising an on-device transcript.
    @ViewBuilder
    private func modelNotice(_ model: TranscriberModelStore) -> some View {
        HStack(spacing: 8) {
            switch model.state {
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text(L10n.t("Downloading the transcription model… \(Int((progress * 100).rounded()))%"))
                        .font(.caption)
                }
                .progressViewStyle(.linear)
            case .paused:
                Label(
                    L10n.t("The model download is paused; the recording is kept and transcribed once the model arrives."),
                    systemImage: "pause.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Spacer(minLength: 6)
                Button(L10n.t("Resume Download")) { model.startDownload() }
                    .buttonStyle(.glass)
                    .font(.caption)
            case .failed:
                Label(L10n.t("The model could not be loaded; the recording is kept and waits to be transcribed."), systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer(minLength: 6)
                Button(L10n.t("Download the Model Again (\(model.downloadSizeText))")) { model.startDownload() }
                    .buttonStyle(.glass)
                    .font(.caption)
            default:
                Label(
                    L10n.t("The model is not downloaded; the recording is kept and transcribed once the model arrives."), systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Spacer(minLength: 6)
                Button(L10n.t("Download Model (\(model.downloadSizeText))")) { model.startDownload() }
                    .buttonStyle(.glass)
                    .font(.caption)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            // No `.keyboardShortcut(.cancelAction)`: Plan 06's key monitor owns Esc (like ⌘↩ / ⌘⇧↩), and
            // `.onExitCommand` above is its in-view fallback; `dismiss()` ignores a repeated Esc.
            Button(L10n.t("Cancel")) { store.dismiss() }

            Spacer(minLength: 12)

            Button(L10n.t("Schedule…")) { store.isSchedulePresented = true }
                .buttonStyle(.glass)
                .popover(
                    isPresented: Binding(
                        get: { store.isSchedulePresented },
                        set: { store.isSchedulePresented = $0 })
                ) {
                    schedulePopover
                }
                .disabled(store.selectedProjectID == nil)

            // No `.keyboardShortcut` on these two: `.keyboardShortcut(.return, modifiers: .command)`
            // also fires on ⌘⇧↩, so both buttons would answer the same keystroke. Plan 06's
            // `NSEvent` monitor owns ⌘↩ / ⌘⇧↩ / esc and calls the store directly; the "⌘⏎" text is
            // only a hint.
            Button {
                Task { await store.saveAndClose() }
            } label: {
                Text(L10n.t("Save  ⌘⏎"))
            }
            .buttonStyle(.glass)
            .disabled(!store.canSave)

            Button {
                Task { await store.saveAndSend() }
            } label: {
                Text(L10n.t("Save and Send  ⌘⇧⏎"))
            }
            .buttonStyle(.glassProminent)
            .disabled(store.selectedProjectID == nil)
        }
    }

    private var schedulePopover: some View {
        ScheduleDateForm(
            date: Binding(get: { store.scheduleDate }, set: { store.scheduleDate = $0 }),
            onCancel: { store.isSchedulePresented = false },
            onSchedule: { when in
                store.isSchedulePresented = false
                Task { await store.saveAndSchedule(at: when) }
            })
    }
}

/// Simple RMS level bar (spec §4.3: "Waveform için basit SwiftUI seviye çubuğu yeterli").
public struct LevelMeterView: View {
    public let level: Float
    public let barCount: Int

    public init(level: Float, barCount: Int = 14) {
        self.level = level
        self.barCount = barCount
    }

    /// How many bars are lit. Pure and tested; clamps out-of-range input.
    public var litBars: Int {
        let clamped = min(max(Double(level), 0), 1)
        return Int((clamped * Double(barCount)).rounded(.down))
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(index < litBars ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: 5 + CGFloat(index) * 0.9)
            }
        }
        .frame(height: 20, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: litBars)
        .accessibilityHidden(true)
    }
}
