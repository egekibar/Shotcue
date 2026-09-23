import Foundation

/// A release version as Shotcue tags it: `MAJOR[.MINOR[.PATCH]]`, an optional leading `v`, and an optional
/// `-prerelease` suffix that sorts before the plain release. Missing parts are zero, so `v1.0` == `1.0.0`.
public struct AppVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// The text after `-`, when there is one ("beta.2" in `1.0.1-beta.2`).
    public var prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// nil for anything that is not a version ("latest", "1.x", four parts).
    public init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        var prerelease: String?
        if let dash = body.firstIndex(of: "-") {
            prerelease = String(body[body.index(after: dash)...])
            body = body[..<dash]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(
            major: numbers[0], minor: numbers[1], patch: numbers[2],
            prerelease: prerelease.flatMap { $0.isEmpty ? nil : $0 })
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let l?, let r?): return l.compare(r, options: .numeric) == .orderedAscending
        }
    }
}
