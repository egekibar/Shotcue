import Foundation
import ShotcueCore

/// Editable copy of a `Project` behind the create/edit sheet (spec §6.3 project fields, §6.5 daily queue).
/// Views hold no state (Plan 05 rule): the draft lives in `LibraryStore.projectDraft`.
public nonisolated struct ProjectDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var isNew: Bool
    public var name: String
    public var path: String
    /// Empty string = the default agent from Ayarlar > Ajanlar; otherwise an `AgentKind` raw value.
    public var agent: String
    public var defaultMode: TaskMode
    /// Empty string = use the agent's global default from Ayarlar > Ajanlar.
    public var defaultModel: String
    /// Empty string = use the global default.
    public var defaultEffort: String
    public var dailyEnabled: Bool
    public var dailyHour: Int
    public var dailyMinute: Int
    public var runInBranch: Bool
    public var stashBeforeRun: Bool

    public static let defaultDailyTime = DailyTime(hour: 2, minute: 0)

    public init(project: Project) {
        id = project.id
        isNew = false
        name = project.name
        path = project.path
        agent = project.agent?.rawValue ?? ""
        defaultMode = project.defaultMode
        defaultModel = project.defaultModel ?? ""
        defaultEffort = project.defaultEffort ?? ""
        dailyEnabled = project.dailyEnabled
        let time = project.dailyTime ?? Self.defaultDailyTime
        dailyHour = time.hour
        dailyMinute = time.minute
        runInBranch = project.runInBranch
        stashBeforeRun = project.stashBeforeRun
    }

    public static func new(id: UUID = UUID()) -> ProjectDraft {
        var draft = ProjectDraft(project: Project(id: id, name: "", path: ""))
        draft.isNew = true
        return draft
    }

    public var dailyTime: DailyTime { DailyTime(hour: dailyHour, minute: dailyMinute) }

    /// The agent the project's tasks will run with once saved.
    public func effectiveAgent(default fallback: AgentKind) -> AgentKind {
        AgentKind.resolve(project: AgentKind(stored: agent), default: fallback)
    }

    /// nil when the draft can be saved; otherwise a Turkish message for the editor and `lastError`.
    public func validationMessage(fileManager: FileManager = .default) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Proje adı gerekli." }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty { return "Proje klasörü gerekli." }
        if !Self.folderExists(trimmedPath, fileManager: fileManager) { return "Klasör bulunamadı: \(trimmedPath)" }
        return nil
    }

    public static func folderExists(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Writes the draft onto `base` and arms the daily queue (spec §6.5, coordinator ruling):
    /// when the queue is newly enabled or its time changed, a slot that already passed today is skipped
    /// (first run tomorrow) and a slot still ahead today runs today. Unchanged schedules keep `dailyLastFiredAt`.
    public func apply(to base: Project, now: Date, calendar: Calendar) -> Project {
        var project = base
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        project.agent = AgentKind(stored: agent)
        project.defaultMode = defaultMode
        let model = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        project.defaultModel = model.isEmpty ? nil : model
        project.defaultEffort = defaultEffort.isEmpty ? nil : defaultEffort
        project.runInBranch = runInBranch
        project.stashBeforeRun = stashBeforeRun
        let time = dailyTime
        let scheduleChanged = !(base.dailyEnabled && base.dailyTime == time)
        project.dailyEnabled = dailyEnabled
        project.dailyTime = (dailyEnabled || base.dailyTime != nil) ? time : nil
        if dailyEnabled, scheduleChanged {
            if let fire = SchedulerRules.todaysFireDate(time, now: now, calendar: calendar), fire <= now {
                project.dailyLastFiredAt = now
            } else {
                project.dailyLastFiredAt = nil
            }
        }
        return project
    }
}
