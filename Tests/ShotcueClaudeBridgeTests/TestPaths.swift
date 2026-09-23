import Foundation

enum TestPaths {
    /// Tests/Fixtures dizini. Her test target'ı Tests/<Target>Tests/ altında olduğu için iki üst dizin.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TestPaths.swift
            .deletingLastPathComponent()  // <Target>Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
}
