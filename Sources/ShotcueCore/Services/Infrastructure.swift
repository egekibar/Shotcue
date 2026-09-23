import Foundation

public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public struct AppNotification: Hashable, Sendable {
    public enum Kind: String, Sendable { case runDone, runFailed }
    public var kind: Kind
    public var title: String
    public var body: String
    public var taskID: UUID?
    public var runID: UUID?
    public init(kind: Kind, title: String, body: String, taskID: UUID? = nil, runID: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.taskID = taskID
        self.runID = runID
    }
}

public protocol Notifier: Sendable {
    func notify(_ notification: AppNotification) async
}
