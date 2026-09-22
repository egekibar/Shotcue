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
            Text("Yeni yakalama").font(.headline)
            Spacer(minLength: 8)
            Text("⌘⏎ kaydet · ⌘⇧⏎ kaydet ve gönder · esc kapat")
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
                Text("PROJE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(
                    "Proje",
                    selection: Binding<UUID?>(
                        get: { store.selectedProjectID },
                        set: { store.selectedProjectID = $0 })
                ) {
                    Text("Seçilmedi (inbox)").tag(UUID?.none)
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
                Text("MOD")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(
                    "Mod",
                    selection: Binding<TaskMode>(
                        get: { store.mode },
                        set: { store.mode = $0 })
                ) {
                    Text("Analiz").tag(TaskMode.analyze)
                    Text("Uygula").tag(TaskMode.implement)
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
                Text("Not yaz…")
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
                    store.isRecording ? "Durdur" : "Sesli not",
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
                Label("\(store.voiceNotes.count) kayıt", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if store.microphoneState == .denied {
                Text("Mikrofon izni yok")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if store.microphoneState == .notDetermined {
                Button("Mikrofon izni ver") {
                    Task { await store.requestMicrophone() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            } else {
                Text("cihaz içi transkripsiyon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            // No `.keyboardShortcut(.cancelAction)`: Plan 06's key monitor owns Esc (like ⌘↩ / ⌘⇧↩), and
            // `.onExitCommand` above is its in-view fallback; `dismiss()` ignores a repeated Esc.
            Button("Vazgeç") { store.dismiss() }

            Spacer(minLength: 12)

            Button("Zamanla…") { store.isSchedulePresented = true }
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
                Text("Kaydet  ⌘⏎")
            }
            .buttonStyle(.glass)
            .disabled(!store.canSave)

            Button {
                Task { await store.saveAndSend() }
            } label: {
                Text("Kaydet ve gönder  ⌘⇧⏎")
            }
            .buttonStyle(.glassProminent)
            .disabled(store.selectedProjectID == nil)
        }
    }

    private var schedulePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ne zaman gönderilsin?").font(.headline)
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
                    Task { await store.saveAndSchedule(at: when) }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
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
