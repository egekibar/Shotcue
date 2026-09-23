import Foundation

/// The final `result` line of a headless run (`--output-format stream-json` and `json` share this shape).
public struct ClaudeRunResult: Hashable, Sendable, Codable {
    public var subtype: String
    public var isError: Bool
    public var sessionID: String?
    public var result: String?
    public var totalCostUSD: Double?
    public var numTurns: Int?
    public var durationMs: Int?
    public var permissionDenials: [String]

    public init(
        subtype: String, isError: Bool, sessionID: String? = nil, result: String? = nil,
        totalCostUSD: Double? = nil, numTurns: Int? = nil, durationMs: Int? = nil,
        permissionDenials: [String] = []
    ) {
        self.subtype = subtype
        self.isError = isError
        self.sessionID = sessionID
        self.result = result
        self.totalCostUSD = totalCostUSD
        self.numTurns = numTurns
        self.durationMs = durationMs
        self.permissionDenials = permissionDenials
    }

    public static let successSubtype = "success"
    public static let maxTurnsSubtype = "error_max_turns"
    public static let maxBudgetSubtype = "error_max_budget_usd"
    public static let executionErrorSubtype = "error_during_execution"

    public var isSuccess: Bool { subtype == Self.successSubtype && !isError }
    /// A limit was reached: never retry automatically, ask the user (spec §8).
    public var hitLimit: Bool { subtype == Self.maxTurnsSubtype || subtype == Self.maxBudgetSubtype }
}

/// One parsed line of the live stream.
public enum RunEvent: Hashable, Sendable {
    case initialized(sessionID: String?, model: String?)
    case assistantText(String)
    case toolUse(name: String, summary: String)
    case apiRetry(attempt: Int?)
    case result(ClaudeRunResult)
    case other(type: String)
}
