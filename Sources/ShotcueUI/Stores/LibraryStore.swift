import Foundation
import Observation
import ShotcueCore

/// Drives the library window (spec §5.3): sidebar counts, the filtered/sorted content list, multi
/// selection and every bulk action in the bottom bar.
///
/// State changes arrive through two repository streams (`observeProjects()`, `observeAllTasks()`) that
/// are consumed in `Task`s owned by this store; `stop()` cancels them. Nothing here touches the disk
/// except `delete(taskIDs:)`, which removes the files whose relative paths the rows carried.
@MainActor
@Observable
public final class LibraryStore {
    /// Renumbers a project's `sort_index` column when a fractional gap collapses.
    /// Expanded, the initializer reads:
    /// `init(services: AppServices, renumber: @escaping @Sendable (UUID?) async throws -> Void = { _ in })`.
    public typealias Renumber = @Sendable (UUID?) async throws -> Void

    // MARK: - Observable state

    public private(set) var projects: [Project] = []
    /// The tasks shown in the content area: `allTasks` (or the search result) filtered by `selection`.
    public private(set) var tasks: [ShotTask] = []
    public private(set) var counts: [SidebarSelection: Int] = [:]
    /// Built whenever exactly one task is selected, so the inspector has something to show.
    public private(set) var detailStore: TaskDetailStore?
    /// taskID -> thumbnail (or full capture) relative path, for the grid cells.
    public private(set) var thumbRelPaths: [UUID: String] = [:]
    /// taskID -> total voice-note seconds, for the "0:04 🎙" badge on a card.
    public private(set) var voiceSeconds: [UUID: Double] = [:]
    public private(set) var isPaused = false

    public var sortOrder: SortOrder = .newest
    public var viewMode: ViewMode = .grid
    public var isInspectorPresented = true
    public var isSchedulePresented = false
    public var scheduleDate: Date
    public var lastError: String?

    /// Sidebar selection. Setting it re-filters the content list and drops the content selection.
    public var selection: SidebarSelection {
        get {
            access(keyPath: \.selection)
            return storedSelection
        }
        set {
            withMutation(keyPath: \.selection) { storedSelection = newValue }
            selectedTaskIDs = []
            recompute()
        }
    }

    /// `⌘F` text. Setting it schedules a debounced repository search; `runSearch()` is the immediate one.
    public var searchText: String {
        get {
            access(keyPath: \.searchText)
            return storedSearchText
        }
        set {
            withMutation(keyPath: \.searchText) { storedSearchText = newValue }
            scheduleSearch()
        }
    }

    /// Content selection. Setting it rebuilds `detailStore`.
    public var selectedTaskIDs: Set<UUID> {
        get {
            access(keyPath: \.selectedTaskIDs)
            return storedSelectedIDs
        }
        set {
            withMutation(keyPath: \.selectedTaskIDs) { storedSelectedIDs = newValue }
            syncDetailStore()
        }
    }

    // MARK: - Private state

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let renumber: Renumber
    @ObservationIgnored private var allTasks: [ShotTask] = []
    /// Non-nil while a search is active; the filter then runs over these rows instead of `allTasks`.
    @ObservationIgnored private var searchResults: [ShotTask]?
    @ObservationIgnored private var streams: [Task<Void, Never>] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var decorationTask: Task<Void, Never>?
    @ObservationIgnored private var detailStartTask: Task<Void, Never>?
    @ObservationIgnored private var storedSelection: SidebarSelection = .inbox
    @ObservationIgnored private var storedSearchText = ""
    @ObservationIgnored private var storedSelectedIDs: Set<UUID> = []

    /// `renumber` defaults to a no-op so the store works (and tests) without the persistence module.
    /// Plan 06 passes `PersistenceMaintenance.renumberSortIndexes`.
    public init(
        services: AppServices,
        renumber: @escaping Renumber = { _ in }
    ) {
        self.services = services
        self.renumber = renumber
        self.scheduleDate = services.clock.now.addingTimeInterval(3600)
    }

    // MARK: - Lifecycle

    /// Subscribes to the repository streams. Idempotent; pair with `stop()`.
    ///
    /// Stream loops hold the store weakly and re-bind `self` per element, so a store that is dropped
    /// without `stop()` is not kept alive by a stream that never ends. A restart (the library window
    /// reopened) rebuilds the inspector's detail store for the current selection.
    public func start() {
        guard streams.isEmpty else { return }
        let projectStream = services.projects.observeProjects()
        let taskStream = services.tasks.observeAllTasks()
        let dispatcher = services.dispatcher
        streams.append(
            Task { [weak self] in
                for await list in projectStream {
                    guard let self else { return }
                    self.projects = list
                    self.recompute()
                }
            })
        streams.append(
            Task { [weak self] in
                for await list in taskStream {
                    guard let self else { return }
                    self.allTasks = list
                    self.recompute()
                    self.scheduleDecorations()
                }
            })
        streams.append(
            Task { [weak self] in
                let paused = await dispatcher.isPaused()
                self?.isPaused = paused
            })
        syncDetailStore()
    }

    public func stop() {
        for stream in streams { stream.cancel() }
        streams.removeAll()
        searchTask?.cancel()
        searchTask = nil
        decorationTask?.cancel()
        decorationTask = nil
        dropDetailStore()
    }

    // MARK: - Derived views of the data

    /// Pure: the content list in the current sort order. Tested directly.
    public var sortedTasks: [ShotTask] {
        switch sortOrder {
        case .newest:
            return tasks.sorted { lhs, rhs in
                lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
            }
        case .oldest:
            return tasks.sorted { lhs, rhs in
                lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
            }
        case .manual:
            return tasks.sorted { lhs, rhs in
                lhs.sortIndex != rhs.sortIndex ? lhs.sortIndex < rhs.sortIndex : lhs.createdAt < rhs.createdAt
            }
        case .status:
            return tasks.sorted { lhs, rhs in
                let left = StatusPresentation.rank(for: lhs.status)
                let right = StatusPresentation.rank(for: rhs.status)
                return left != right ? left < right : lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    public var selectedTasks: [ShotTask] {
        sortedTasks.filter { selectedTaskIDs.contains($0.id) }
    }

    /// The single selected task, or nil when the selection is empty or plural.
    public var singleSelectedTask: ShotTask? {
        guard selectedTaskIDs.count == 1, let id = selectedTaskIDs.first else { return nil }
        return allTasks.first { $0.id == id }
    }

    public func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Absolute URL of a task's thumbnail, or nil when it has no capture yet.
    public func thumbnailURL(for taskID: UUID) -> URL? {
        guard let rel = thumbRelPaths[taskID] else { return nil }
        return services.fileStore.absoluteURL(for: rel)
    }

    public var canSendSelection: Bool {
        !selectedTasks.isEmpty && selectedTasks.allSatisfy { $0.projectID != nil && $0.status != .running }
    }

    // MARK: - Selection

    /// Grid cells call this with the live modifier flags (`List`/`Table` handle it themselves).
    public func toggleSelection(taskID: UUID, extend: Bool, range: Bool) {
        let ordered = sortedTasks.map(\.id)
        if range, let anchor = storedSelectedIDs.first,
            let from = ordered.firstIndex(of: anchor), let to = ordered.firstIndex(of: taskID)
        {
            let bounds = min(from, to)...max(from, to)
            selectedTaskIDs = storedSelectedIDs.union(ordered[bounds])
        } else if extend {
            var next = storedSelectedIDs
            if next.contains(taskID) { next.remove(taskID) } else { next.insert(taskID) }
            selectedTaskIDs = next
        } else {
            selectedTaskIDs = [taskID]
        }
    }

    // MARK: - Search

    public func runSearch() async {
        searchTask?.cancel()
        searchTask = nil
        await performSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = storedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            recompute()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            await self.performSearch()
        }
    }

    private func performSearch() async {
        let query = storedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            recompute()
            return
        }
        do {
            searchResults = try await services.tasks.search(query)
        } catch {
            searchResults = []
            report(error)
        }
        recompute()
    }

    // MARK: - Bulk actions

    /// Persists the inspector's uncommitted text before an action hands `ids` on: on macOS a click on a
    /// button does not take focus from a text view, so no focus-loss commit has run yet.
    private func flushInspectorDrafts(for ids: Set<UUID>) async {
        guard let detail = detailStore, ids.contains(detail.taskID) else { return }
        await detail.commitDrafts()
    }

    /// "Ayrı ayrı gönder": every selected task becomes its own run.
    public func send(taskIDs: Set<UUID>) async {
        await flushInspectorDrafts(for: taskIDs)
        for id in ordered(taskIDs) {
            do {
                try await services.dispatcher.enqueue(taskID: id)
            } catch {
                report(error)
            }
        }
    }

    /// "Tek task olarak birleştir ve gönder": captures and voice notes of the other tasks move onto the
    /// first one (manual order), the extra rows are deleted, and a single run is enqueued.
    public func sendAsOne(taskIDs: Set<UUID>) async {
        await flushInspectorDrafts(for: taskIDs)
        let ids = ordered(taskIDs)
        guard let primaryID = ids.first else { return }
        guard ids.count > 1 else { return await send(taskIDs: [primaryID]) }
        do {
            guard var primary = try await services.tasks.task(id: primaryID) else { return }
            guard primary.status.isEditable else { return }
            var noteParts = [primary.noteText]
            for otherID in ids.dropFirst() {
                guard let other = try await services.tasks.task(id: otherID), other.status.isEditable
                else { continue }
                // Move the attachments BEFORE deleting the row: `deleteTask` removes whatever still
                // points at it, and moved rows no longer do.
                let captures = try await services.tasks.captures(taskID: otherID)
                if !captures.isEmpty {
                    try await services.tasks.moveCaptures(ids: captures.map(\.id), toTaskID: primaryID)
                }
                for var note in try await services.tasks.voiceNotes(taskID: otherID) {
                    note.taskID = primaryID
                    try await services.tasks.save(note)
                }
                noteParts.append(other.noteText)
                try await services.tasks.deleteTask(id: otherID)
            }
            primary.noteText =
                noteParts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if !primary.titleEditedByUser {
                let transcripts = try await services.tasks.voiceNotes(taskID: primaryID)
                    .compactMap(\.transcript)
                primary.title = TitleMaker.title(
                    noteText: primary.noteText,
                    transcript: transcripts.first,
                    createdAt: primary.createdAt)
            }
            primary.updatedAt = services.clock.now
            try await services.tasks.save(primary)
            selectedTaskIDs = [primaryID]
            try await services.dispatcher.enqueue(taskID: primaryID)
        } catch {
            report(error)
        }
    }

    /// "Projeye taşı". Coming out of the inbox the task also becomes `ready` (spec §7); going back to the
    /// inbox never strands it (`ProjectAssignment`).
    public func move(taskIDs: Set<UUID>, toProject projectID: UUID?) async {
        await flushInspectorDrafts(for: taskIDs)
        let now = services.clock.now
        for id in ordered(taskIDs) {
            do {
                guard let projectID else {
                    _ = try await ProjectAssignment.detach(taskID: id, services: services)
                    continue
                }
                guard var task = try await services.tasks.task(id: id), task.status.isEditable
                else { continue }
                let cameFromInbox = task.projectID == nil
                task.projectID = projectID
                task.updatedAt = now
                if cameFromInbox, task.status == .inbox {
                    try task.transition(to: .ready, at: now)
                }
                try await services.tasks.save(task)
            } catch {
                report(error)
            }
        }
    }

    /// "Zamanla". Fails loudly for project-less tasks: `inbox` has no edge to `scheduled`.
    public func schedule(taskIDs: Set<UUID>, at date: Date) async {
        await flushInspectorDrafts(for: taskIDs)
        let now = services.clock.now
        for id in ordered(taskIDs) {
            do {
                guard var task = try await services.tasks.task(id: id) else { continue }
                task.scheduledAt = date
                try task.transition(to: .scheduled, at: now)
                try await services.tasks.save(task)
            } catch {
                report(error)
            }
        }
    }

    /// "Günlük kuyruğa al" = make sure the task is `ready`; the scheduler picks ready tasks up.
    public func addToDailyQueue(taskIDs: Set<UUID>) async {
        await flushInspectorDrafts(for: taskIDs)
        let now = services.clock.now
        for id in ordered(taskIDs) {
            do {
                guard var task = try await services.tasks.task(id: id), task.status != .ready,
                    task.status.canTransition(to: .ready)
                else { continue }
                try task.transition(to: .ready, at: now)
                try await services.tasks.save(task)
            } catch {
                report(error)
            }
        }
    }

    /// Deletes the rows and then the files they referenced (captures, thumbs, audio, run logs).
    /// A running task is never deleted (spec §7: it can only be cancelled); the user is told why.
    public func delete(taskIDs: Set<UUID>) async {
        var deleted: Set<UUID> = []
        var skippedRunning = false
        for id in ordered(taskIDs) {
            do {
                guard let task = try await services.tasks.task(id: id) else { continue }
                guard task.status != .running else {
                    skippedRunning = true
                    continue
                }
                let captures = try await services.tasks.captures(taskID: id)
                let notes = try await services.tasks.voiceNotes(taskID: id)
                let runs = try await services.runs.runs(taskID: id)
                var relPaths = captures.map(\.relPath)
                relPaths += captures.compactMap(\.thumbRelPath)
                relPaths += notes.map(\.relPath)
                relPaths += runs.map(\.logRelPath)
                // Committing the inspector's text after the row is gone would re-insert it (upsert).
                if detailStore?.taskID == id { detailStore?.discardDrafts() }
                try await services.tasks.deleteTask(id: id)
                deleted.insert(id)
                await removeFiles(relPaths)
            } catch {
                report(error)
            }
        }
        if skippedRunning { lastError = Self.runningDeleteMessage }
        selectedTaskIDs = storedSelectedIDs.subtracting(deleted)
    }

    // MARK: - Delete confirmation

    /// Tasks waiting for the user's answer in the delete confirmation dialog; empty while none is shown.
    public private(set) var pendingDeleteIDs: Set<UUID> = []

    /// Drives the confirmation dialog: true while tasks wait for confirmation; setting it false cancels.
    public var isDeleteConfirmationPresented: Bool {
        get { !pendingDeleteIDs.isEmpty }
        set { if !newValue { pendingDeleteIDs = [] } }
    }

    public var deleteConfirmationTitle: String {
        pendingDeleteIDs.count == 1
            ? "Görev kalıcı olarak silinsin mi?"
            : "\(pendingDeleteIDs.count) görev kalıcı olarak silinsin mi?"
    }

    /// "Sil" is available only for a non-empty set without a running task (a run can only be cancelled).
    public func canDelete(taskIDs: Set<UUID>) -> Bool {
        !taskIDs.isEmpty && !allTasks.contains { taskIDs.contains($0.id) && $0.status == .running }
    }

    public var canDeleteSelection: Bool { canDelete(taskIDs: selectedTaskIDs) }

    /// ⌫ and every "Sil" land here: nothing is deleted before `confirmDelete(taskIDs:)`. Running tasks are
    /// left out; when nothing else remains the user is told why.
    public func requestDelete(taskIDs: Set<UUID>) {
        let running = Set(allTasks.filter { taskIDs.contains($0.id) && $0.status == .running }.map(\.id))
        let deletable = taskIDs.subtracting(running)
        guard !deletable.isEmpty else {
            if !running.isEmpty { lastError = Self.runningDeleteMessage }
            return
        }
        pendingDeleteIDs = deletable
    }

    /// The dialog's "Sil". The view passes the set the dialog was presented for
    /// (`confirmationDialog(presenting:)`), because SwiftUI may reset the presentation binding before the
    /// button's action runs.
    public func confirmDelete(taskIDs: Set<UUID>) async {
        pendingDeleteIDs = []
        await delete(taskIDs: taskIDs)
    }

    public func cancelDelete() {
        pendingDeleteIDs = []
    }

    static let runningDeleteMessage = "Çalışan bir görev silinemez. Önce iptal et."

    /// The absolute URL of `relPath` when deleting it is safe: non-empty, resolving strictly below one of
    /// the four data folders (captures/, thumbs/, audio/, runs/) of this store. Anything else (empty,
    /// `..` escapes, the folders themselves, the database, absolute paths elsewhere) is nil.
    nonisolated static func removableURL(for relPath: String, in fileStore: FileStore) -> URL? {
        let trimmed = relPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = fileStore.absoluteURL(for: trimmed).standardizedFileURL
        guard let resolved = fileStore.relativePath(for: url) else { return nil }
        let components = resolved.split(separator: "/")
        guard components.count >= 2, let folder = components.first, removableFolders.contains(String(folder))
        else { return nil }
        return url
    }

    nonisolated static let removableFolders: Set<String> = [
        FileStore.capturesDir, FileStore.thumbsDir, FileStore.audioDir, FileStore.runsDir,
    ]

    /// Manual-order drag & drop. `before` is the neighbour ABOVE the drop point, `after` the one BELOW;
    /// pass nil for the ends of the list.
    public func reorder(taskID: UUID, before: UUID?, after: UUID?) async {
        await flushInspectorDrafts(for: [taskID])
        let beforeIndex = sortIndex(of: before)
        let afterIndex = sortIndex(of: after)
        do {
            guard var task = try await services.tasks.task(id: taskID) else { return }
            task.sortIndex = SortIndex.between(beforeIndex, afterIndex)
            task.updatedAt = services.clock.now
            try await services.tasks.save(task)
            if SortIndex.needsRenumber(beforeIndex, afterIndex) {
                try await renumber(task.projectID)
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Projects

    public func createProject(name: String, path: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPath.isEmpty else {
            lastError = "Proje adı ve klasör yolu gerekli."
            return
        }
        do {
            let existing = try await services.projects.allProjects()
            let project = Project(
                name: trimmedName, path: trimmedPath,
                sortIndex: SortIndex.between(existing.last?.sortIndex, nil),
                createdAt: services.clock.now)
            try await services.projects.save(project)
            selection = .project(project.id)
        } catch {
            report(error)
        }
    }

    /// Deleting a project returns its tasks to the inbox without stranding them (`ProjectAssignment`);
    /// captures are never destroyed here. Refused while one of its tasks runs. The tasks are read from the
    /// repository, not the stream snapshot, so none is missed.
    public func deleteProject(id: UUID) async {
        do {
            let projectTasks = try await services.tasks.tasks(projectID: id)
            guard !projectTasks.contains(where: { $0.status == .running }) else {
                lastError = "Bu projede çalışan bir görev var. Önce bitmesini bekle ya da iptal et."
                return
            }
            for task in projectTasks {
                _ = try await ProjectAssignment.detach(taskID: task.id, services: services)
            }
            try await services.projects.deleteProject(id: id)
            if storedSelection == .project(id) { selection = .inbox }
        } catch {
            report(error)
        }
    }

    // MARK: - Project editor (Task 14)

    /// Non-nil while the create/edit sheet is visible (`LibraryView` binds it with `.sheet(item:)`).
    public var projectDraft: ProjectDraft?
    public var isProjectFolderPickerPresented = false
    /// The daily-queue arming rule is calendar-dependent; tests inject a fixed one.
    public var calendar: Calendar = .current

    /// "Proje ekle…" sets this; true opens a fresh create draft, false closes it.
    public var isProjectCreatorPresented: Bool {
        get { projectDraft?.isNew == true }
        set {
            if newValue {
                beginCreateProject()
            } else if projectDraft?.isNew == true {
                cancelProjectEditor()
            }
        }
    }

    public func beginCreateProject() {
        projectDraft = .new()
    }

    public func beginEditProject(id: UUID) async {
        do {
            guard let project = try await services.projects.project(id: id) else { return }
            projectDraft = ProjectDraft(project: project)
        } catch {
            report(error)
        }
    }

    public func cancelProjectEditor() {
        projectDraft = nil
        isProjectFolderPickerPresented = false
    }

    /// Folder chosen in the editor's picker; fills an empty name with the folder's name.
    public func projectFolderPicked(_ url: URL) {
        guard var draft = projectDraft else { return }
        draft.path = url.path
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = url.lastPathComponent
        }
        projectDraft = draft
    }

    /// Validates and saves the draft. Returns true and closes the editor on success.
    @discardableResult
    public func saveProjectDraft() async -> Bool {
        guard let draft = projectDraft else { return false }
        if let message = draft.validationMessage() {
            lastError = message
            return false
        }
        let now = services.clock.now
        do {
            if draft.isNew {
                let existing = try await services.projects.allProjects()
                let base = Project(
                    id: draft.id, name: "", path: "",
                    sortIndex: SortIndex.between(existing.last?.sortIndex, nil),
                    createdAt: now)
                try await services.projects.save(draft.apply(to: base, now: now, calendar: calendar))
                selection = .project(draft.id)
            } else {
                guard let base = try await services.projects.project(id: draft.id) else {
                    lastError = "Proje bulunamadı."
                    return false
                }
                try await services.projects.save(draft.apply(to: base, now: now, calendar: calendar))
            }
            projectDraft = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Queue controls

    public func runQueueNow() async {
        await services.dispatcher.runQueueNow()
    }

    public func setPaused(_ paused: Bool) async {
        await services.dispatcher.setPaused(paused)
        isPaused = await services.dispatcher.isPaused()
    }

    // MARK: - Recomputation

    private func recompute() {
        let base = searchResults ?? allTasks
        tasks = filtered(base)
        counts = makeCounts(allTasks)
        let visible = Set(tasks.map(\.id))
        let trimmed = storedSelectedIDs.intersection(visible)
        if trimmed != storedSelectedIDs {
            withMutation(keyPath: \.selectedTaskIDs) { storedSelectedIDs = trimmed }
            syncDetailStore()
        }
    }

    private func filtered(_ list: [ShotTask]) -> [ShotTask] {
        switch storedSelection {
        case .inbox: list.filter { $0.projectID == nil }
        case .project(let id): list.filter { $0.projectID == id }
        case .status(let status): list.filter { $0.status == status }
        }
    }

    private func makeCounts(_ list: [ShotTask]) -> [SidebarSelection: Int] {
        var result: [SidebarSelection: Int] = [:]
        result[.inbox] = list.count { $0.projectID == nil }
        for project in projects {
            result[.project(project.id)] = list.count { $0.projectID == project.id }
        }
        for status in TaskStatus.allCases {
            result[.status(status)] = list.count { $0.status == status }
        }
        return result
    }

    private func syncDetailStore() {
        guard storedSelectedIDs.count == 1, let id = storedSelectedIDs.first else {
            dropDetailStore()
            return
        }
        guard detailStore?.taskID != id else { return }
        dropDetailStore()
        let store = TaskDetailStore(services: services, taskID: id)
        detailStore = store
        detailStartTask = Task { await store.start() }
    }

    /// Stops the inspector's store and cancels a `start()` that has not run yet, so a store dropped
    /// before its start task ran never subscribes afterwards.
    private func dropDetailStore() {
        detailStartTask?.cancel()
        detailStartTask = nil
        detailStore?.stop()
        detailStore = nil
    }

    /// Loads the thumbnail path and voice-note length of tasks we have not decorated yet.
    private func scheduleDecorations() {
        decorationTask?.cancel()
        let pending = allTasks.map(\.id).filter { thumbRelPaths[$0] == nil && voiceSeconds[$0] == nil }
        guard !pending.isEmpty else { return }
        let repository = services.tasks
        decorationTask = Task { [weak self] in
            for id in pending {
                if Task.isCancelled { return }
                guard let captures = try? await repository.captures(taskID: id),
                    let notes = try? await repository.voiceNotes(taskID: id)
                else { continue }
                guard let self else { return }
                if let first = captures.first {
                    self.thumbRelPaths[id] = first.thumbRelPath ?? first.relPath
                }
                let seconds = notes.reduce(0) { $0 + $1.durationSec }
                if seconds > 0 { self.voiceSeconds[id] = seconds }
            }
        }
    }

    private func sortIndex(of taskID: UUID?) -> Double? {
        guard let taskID else { return nil }
        return allTasks.first { $0.id == taskID }?.sortIndex
    }

    private func ordered(_ ids: Set<UUID>) -> [UUID] {
        let manual =
            allTasks
            .filter { ids.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.sortIndex != rhs.sortIndex ? lhs.sortIndex < rhs.sortIndex : lhs.createdAt < rhs.createdAt
            }
        let known = Set(manual.map(\.id))
        return manual.map(\.id) + ids.filter { !known.contains($0) }
    }

    /// Deletes files off the main actor and waits, so callers (and tests) see a settled filesystem.
    /// Only paths `removableURL(for:in:)` accepts are touched, never a directory, and every refusal or
    /// failure is logged instead of being swallowed.
    private func removeFiles(_ relPaths: [String]) async {
        var urls: [URL] = []
        for relPath in relPaths {
            if let url = Self.removableURL(for: relPath, in: services.fileStore) {
                urls.append(url)
            } else {
                NSLog("Shotcue: not deleting unexpected path '%@'", relPath)
            }
        }
        guard !urls.isEmpty else { return }
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for url in urls {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                guard !isDirectory.boolValue else {
                    NSLog("Shotcue: not deleting directory '%@'", url.path)
                    continue
                }
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    NSLog("Shotcue: could not delete '%@': %@", url.path, error.localizedDescription)
                }
            }
        }.value
    }

    private func report(_ error: any Error) {
        if let stateError = error as? TaskStateError {
            lastError = Self.message(for: stateError)
        } else {
            lastError = error.localizedDescription
        }
    }

    static func message(for error: TaskStateError) -> String {
        switch error {
        case .missingProject: "Bu görev bir projeye atanmadan gönderilemez."
        case .scheduledDateRequired: "Zamanlama için tarih ve saat gerekli."
        case .invalidTransition(let from, let to):
            "\(StatusPresentation.label(for: from)) → \(StatusPresentation.label(for: to)) geçişi geçersiz."
        }
    }
}
