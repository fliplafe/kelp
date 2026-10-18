// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Krill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "krill", targets: ["krill"]),
        .executable(name: "krilld", targets: ["krilld"]),
        .executable(name: "KrillApp", targets: ["KrillApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", from: "0.15.0"),
    ],
    targets: [
        .target(name: "Core", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "GitKit", dependencies: ["Core"]),
        .target(name: "Agents", dependencies: ["Core"]),
        .target(name: "Daemon", dependencies: ["Core", "GitKit", "Agents", "LocalAI"]),
        .target(name: "TerminalKit", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "Core"]),
        .executableTarget(name: "krilld", dependencies: ["Daemon"]),
        .executableTarget(name: "krill", dependencies: ["Core"]),
        .target(name: "LSPKit", dependencies: ["Core"]),
        .target(name: "LocalAI"),
        .target(name: "EditorKit", dependencies: [.product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "KrillApp",
            dependencies: ["Core", "GitKit", "Agents", "TerminalKit", "EditorKit", "LSPKit", "LocalAI", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
        .testTarget(name: "DaemonTests", dependencies: ["Daemon", "Agents"]),
        .testTarget(name: "LSPKitTests", dependencies: ["LSPKit"]),
        .testTarget(name: "LocalAITests", dependencies: ["LocalAI"]),
    ]
)
