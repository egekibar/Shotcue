// swift-tools-version: 6.4
import PackageDescription

let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]
let uiSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)] + upcoming
let serviceSettings: [SwiftSetting] = [.defaultIsolation(nil)] + upcoming

let package = Package(
    name: "Shotcue",
    // English is the source language; every UI string also has a Turkish entry (`<Module>/Resources/*.lproj`).
    // Classic `.strings` tables: String Catalogs (`.xcstrings`) need `xcstringstool`, which ships with Xcode only.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Shotcue", targets: ["ShotcueApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "ShotcueCore", resources: [.process("Resources")], swiftSettings: serviceSettings),
        .target(
            name: "ShotcuePersistence",
            dependencies: ["ShotcueCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: serviceSettings),
        .target(name: "ShotcueCapture", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        .target(
            name: "ShotcueNotes",
            dependencies: ["ShotcueCore", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            swiftSettings: serviceSettings),
        .target(name: "ShotcueClaudeBridge", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        // In-app updates from GitHub Releases: release feed, DMG download/verify/stage, post-exit bundle swap.
        .target(name: "ShotcueUpdater", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        .target(
            name: "ShotcueUI", dependencies: ["ShotcueCore"], resources: [.process("Resources")],
            swiftSettings: uiSettings),
        // Fakes of every Core protocol, shared by all test targets (never linked into the app).
        .target(name: "ShotcueTestSupport", dependencies: ["ShotcueCore"], swiftSettings: serviceSettings),
        .executableTarget(
            name: "ShotcueApp",
            dependencies: [
                "ShotcueCore", "ShotcueUI", "ShotcuePersistence", "ShotcueCapture",
                "ShotcueNotes", "ShotcueClaudeBridge", "ShotcueUpdater",
            ],
            resources: [.process("Resources")],
            swiftSettings: uiSettings),
        .testTarget(name: "ShotcueCoreTests", dependencies: ["ShotcueCore", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcuePersistenceTests", dependencies: ["ShotcuePersistence", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueCaptureTests", dependencies: ["ShotcueCapture", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueNotesTests", dependencies: ["ShotcueNotes", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueClaudeBridgeTests", dependencies: ["ShotcueClaudeBridge", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueUpdaterTests", dependencies: ["ShotcueUpdater", "ShotcueTestSupport"], swiftSettings: serviceSettings),
        .testTarget(name: "ShotcueUITests", dependencies: ["ShotcueUI", "ShotcueTestSupport"], swiftSettings: uiSettings),
    ],
    swiftLanguageModes: [.v6]
)
