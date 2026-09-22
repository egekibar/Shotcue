import AppKit
import ShotcueCore
import SwiftUI

/// The library window (spec §5.3, research 05 §C.2): sidebar with Projeler / Inbox / Durum, a grid or a
/// table of tasks, `⌘F` search, a glass selection bar at the bottom and the task inspector on the right.
///
/// Every piece of mutable state lives in `LibraryStore`; this view only binds to it.
public struct LibraryView: View {
    public let store: LibraryStore
    public let thumbnails: ThumbnailCache?

    /// macOS 27's `reorderable()` is behind this flag. The shipped path is the macOS 26
    /// `draggable`/`dropDestination` one, because `.reorderable()` is known to crash in views with
    /// conditional compilation or popovers (research 01 §2). Flip only after manual verification on 27.
    public static let useNativeReorder = false

    public init(store: LibraryStore, thumbnails: ThumbnailCache? = nil) {
        self.store = store
        self.thumbnails = thumbnails
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]
    }

    public var body: some View {
        @Bindable var bindable = store
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .navigationTitle(navigationTitle)
                .navigationSubtitle("\(store.sortedTasks.count) öğe")
                .searchable(text: $bindable.searchText, placement: .toolbar, prompt: "Başlık, not, transkript")
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) { selectionBar }
                .inspector(isPresented: $bindable.isInspectorPresented) { inspector }
        }
        .task { store.start() }
        .onDisappear { store.stop() }
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
        .sheet(item: $bindable.projectDraft) { _ in
            ProjectEditorView(store: store)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(
            selection: Binding<SidebarSelection?>(
                get: { store.selection },
                set: { if let value = $0 { store.selection = value } })
        ) {
            Section("Projeler") {
                ForEach(store.projects) { project in
                    projectRow(project)
                }
                Button {
                    store.isProjectCreatorPresented = true
                } label: {
                    Label("Proje ekle…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("Inbox") {
                Label("Gelen", systemImage: "tray")
                    .badge(store.counts[.inbox] ?? 0)
                    .tag(SidebarSelection.inbox)
                    .dropDestination(for: TaskDragItem.self) { items, _ in
                        let ids = Set(items.flatMap(\.taskIDs))
                        guard !ids.isEmpty else { return false }
                        Task { await store.move(taskIDs: ids, toProject: nil) }
                        return true
                    }
            }

            Section("Durum") {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Label(
                        StatusPresentation.label(for: status),
                        systemImage: StatusPresentation.symbol(for: status)
                    )
                    .badge(store.counts[.status(status)] ?? 0)
                    .tag(SidebarSelection.status(status))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
    }

    private func projectRow(_ project: Project) -> some View {
        let folderMissing = !ProjectDraft.folderExists(project.path)
        return Label(project.name, systemImage: project.dailyEnabled ? "folder.badge.gearshape" : "folder")
            .foregroundStyle(folderMissing ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .badge(store.counts[.project(project.id)] ?? 0)
            .tag(SidebarSelection.project(project.id))
            .help(folderMissing ? "Klasör bulunamadı: \(project.path)" : project.path)
            .dropDestination(for: TaskDragItem.self) { items, _ in
                let ids = Set(items.flatMap(\.taskIDs))
                guard !ids.isEmpty else { return false }
                Task { await store.move(taskIDs: ids, toProject: project.id) }
                return true
            }
            .contextMenu {
                Button("Proje ayarları…", systemImage: "gearshape") {
                    Task { await store.beginEditProject(id: project.id) }
                }
                Button("Projeyi sil", systemImage: "trash", role: .destructive) {
                    Task { await store.deleteProject(id: project.id) }
                }
            }
    }

    private var navigationTitle: String {
        switch store.selection {
        case .inbox: "Gelen"
        case .project(let id): store.project(id: id)?.name ?? "Proje"
        case .status(let status): StatusPresentation.label(for: status)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.sortedTasks.isEmpty {
            emptyState
        } else if store.viewMode == .grid {
            grid
        } else {
            table
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(store.searchText.isEmpty ? "Burada henüz bir şey yok" : "Eşleşme bulunamadı")
                .font(.title3.weight(.medium))
            Text(
                store.searchText.isEmpty
                    ? "Kısayolla ekrandan bir bölge seç; yakalama buraya düşer."
                    : "Başka bir kelime dene."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.sortedTasks) { task in
                    gridCell(task)
                }
                .reorderableIfEnabled(Self.useNativeReorder && store.sortOrder == .manual)
            }
            .padding(14)
        }
        .focusable()
        .onDeleteCommand { Task { await store.delete(taskIDs: store.selectedTaskIDs) } }
    }

    private func gridCell(_ task: ShotTask) -> some View {
        TaskCardView(
            task: task,
            thumbnailURL: store.thumbnailURL(for: task.id),
            isSelected: store.selectedTaskIDs.contains(task.id),
            cache: thumbnails,
            voiceSeconds: store.voiceSeconds[task.id]
        )
        .onTapGesture {
            // SwiftUI does not report modifiers on a tap, so read them from the live event.
            let flags = NSEvent.modifierFlags
            store.toggleSelection(
                taskID: task.id,
                extend: flags.contains(.command),
                range: flags.contains(.shift))
        }
        .draggable(dragItem(for: task))
        .dropDestination(for: TaskDragItem.self) { items, _ in
            guard store.sortOrder == .manual,
                let moving = items.flatMap(\.taskIDs).first, moving != task.id
            else { return false }
            let ordered = store.sortedTasks
            guard let index = ordered.firstIndex(where: { $0.id == task.id }) else { return false }
            let above = index > 0 ? ordered[index - 1].id : nil
            Task { await store.reorder(taskID: moving, before: above, after: task.id) }
            return true
        }
        .contextMenu { taskMenu(for: task) }
    }

    private var table: some View {
        Table(
            store.sortedTasks,
            selection: Binding<Set<UUID>>(
                get: { store.selectedTaskIDs },
                set: { store.selectedTaskIDs = $0 })
        ) {
            TableColumn("Başlık") { task in
                HStack(spacing: 6) {
                    Image(systemName: store.voiceSeconds[task.id] != nil ? "mic.fill" : "text.alignleft")
                        .foregroundStyle(.secondary)
                    Text(task.title).lineLimit(1)
                }
            }
            TableColumn("Durum") { task in
                StatusChip(status: task.status)
            }
            .width(110)
            TableColumn("Proje") { task in
                Text(store.project(id: task.projectID)?.name ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(140)
            TableColumn("Güncellendi") { task in
                Text(Formatting.relativeDate(task.updatedAt, now: Date()))
                    .foregroundStyle(.secondary)
            }
            .width(110)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, ids.count == 1, let task = store.sortedTasks.first(where: { $0.id == id }) {
                taskMenu(for: task)
            } else if !ids.isEmpty {
                selectionMenu(ids)
            }
        }
    }

    private func dragItem(for task: ShotTask) -> TaskDragItem {
        // Dragging a selected card drags the whole selection; dragging an unselected one drags just it.
        if store.selectedTaskIDs.contains(task.id), store.selectedTaskIDs.count > 1 {
            return TaskDragItem(
                taskIDs: store.sortedTasks
                    .filter { store.selectedTaskIDs.contains($0.id) }
                    .map(\.id))
        }
        return TaskDragItem(taskIDs: [task.id])
    }

    // MARK: - Menus

    @ViewBuilder
    private func taskMenu(for task: ShotTask) -> some View {
        Button("Şimdi gönder", systemImage: "paperplane.fill") {
            Task { await store.send(taskIDs: [task.id]) }
        }
        .disabled(task.projectID == nil || task.status == .running)
        Menu("Projeye taşı") {
            ForEach(store.projects) { project in
                Button(project.name) {
                    Task { await store.move(taskIDs: [task.id], toProject: project.id) }
                }
            }
            Divider()
            Button("Inbox'a al") {
                Task { await store.move(taskIDs: [task.id], toProject: nil) }
            }
        }
        Button("Günlük kuyruğa al", systemImage: "calendar.badge.clock") {
            Task { await store.addToDailyQueue(taskIDs: [task.id]) }
        }
        Divider()
        Button("Sil", systemImage: "trash", role: .destructive) {
            Task { await store.delete(taskIDs: [task.id]) }
        }
    }

    @ViewBuilder
    private func selectionMenu(_ ids: Set<UUID>) -> some View {
        Button("Tek görev olarak gönder", systemImage: "square.stack.3d.down.forward") {
            Task { await store.sendAsOne(taskIDs: ids) }
        }
        Button("Ayrı ayrı gönder", systemImage: "paperplane") {
            Task { await store.send(taskIDs: ids) }
        }
        Menu("Projeye taşı") {
            ForEach(store.projects) { project in
                Button(project.name) {
                    Task { await store.move(taskIDs: ids, toProject: project.id) }
                }
            }
        }
        Divider()
        Button("Sil", systemImage: "trash", role: .destructive) {
            Task { await store.delete(taskIDs: ids) }
        }
    }

    // MARK: - Toolbar and bottom bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(
                "Sırala",
                selection: Binding<SortOrder>(
                    get: { store.sortOrder }, set: { store.sortOrder = $0 })
            ) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)

            Picker(
                "Görünüm",
                selection: Binding<ViewMode>(
                    get: { store.viewMode }, set: { store.viewMode = $0 })
            ) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Izgara / Liste")

            Button {
                Task { await store.runQueueNow() }
            } label: {
                Label("Kuyruğu çalıştır", systemImage: "play.fill")
            }
            .disabled(store.isPaused)

            Button {
                Task { await store.setPaused(!store.isPaused) }
            } label: {
                Label(
                    store.isPaused ? "Sürdür" : "Duraklat",
                    systemImage: store.isPaused ? "play.circle" : "pause.circle")
            }

            Button {
                store.isInspectorPresented.toggle()
            } label: {
                Label("Detay", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if store.selectedTaskIDs.count > 1 {
            HStack(spacing: 8) {
                Text("\(store.selectedTaskIDs.count) seçili")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 12)
                Button("Ayrı ayrı gönder") {
                    Task { await store.send(taskIDs: store.selectedTaskIDs) }
                }
                .buttonStyle(.glass)
                .disabled(!store.canSendSelection)

                Menu("Projeye taşı") {
                    ForEach(store.projects) { project in
                        Button(project.name) {
                            Task { await store.move(taskIDs: store.selectedTaskIDs, toProject: project.id) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button("Zamanla…") {
                    store.isSchedulePresented = true
                }
                .buttonStyle(.glass)
                .popover(
                    isPresented: Binding(
                        get: { store.isSchedulePresented },
                        set: { store.isSchedulePresented = $0 })
                ) {
                    schedulePopover
                }

                Button("Sil", systemImage: "trash") {
                    Task { await store.delete(taskIDs: store.selectedTaskIDs) }
                }
                .buttonStyle(.glass)

                Button("Tek görev olarak gönder") {
                    Task { await store.sendAsOne(taskIDs: store.selectedTaskIDs) }
                }
                .buttonStyle(.glassProminent)
                .disabled(!store.canSendSelection)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(in: .rect(cornerRadius: 16))
            .padding(12)
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
                    let ids = store.selectedTaskIDs
                    let when = store.scheduleDate
                    store.isSchedulePresented = false
                    Task { await store.schedule(taskIDs: ids, at: when) }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let detail = store.detailStore {
            TaskInspectorView(store: detail, thumbnails: thumbnails)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(store.selectedTaskIDs.isEmpty ? "Bir görev seç" : "Tek görev seç")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
    }
}

extension ForEach where Content: View, Data.Element: Identifiable {
    /// macOS 27's native reorder, gated twice: by the OS check and by `LibraryView.useNativeReorder`.
    /// The symbols only exist in SDK 27, which is the SDK Command Line Tools 27 compiles against.
    @ViewBuilder
    func reorderableIfEnabled(_ enabled: Bool) -> some View {
        if enabled, #available(macOS 27, *) {
            self.reorderable()
        } else {
            self
        }
    }
}
