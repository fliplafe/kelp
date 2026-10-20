// swift-tools-version:6.0
import PackageDescription
import Foundation

/// libghostty is built locally by scripts/build-ghostty.sh (too big for git); its targets exist only when it's there.
let ghosttyLinks: [LinkerSetting] = [.linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"), .linkedFramework("CoreText"),
                                      .linkedFramework("CoreGraphics"), .linkedFramework("IOSurface"), .linkedFramework("Carbon"),
                                      .linkedFramework("UniformTypeIdentifiers"), .linkedLibrary("c++")]
/// KELP_NO_GHOSTTY=1 leaves them out (release builds: the probe isn't shipped and libghostty is arm64-only).
let hasGhostty = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Vendor/GhosttyKit.xcframework")
    && Context.environment["KELP_NO_GHOSTTY"] == nil

let package = Package(
    name: "Kelp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kelp", targets: ["kelp"]),
        .executable(name: "kelpd", targets: ["kelpd"]),
        .executable(name: "KelpApp", targets: ["KelpApp"]),
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
        .target(name: "AgentData", dependencies: ["Core"]),
        .target(name: "Daemon", dependencies: ["Core", "GitKit", "Agents", "Integrations", "AgentData"]),
        .target(name: "TerminalKit", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "Core"] + (hasGhostty ? ["GhosttyKit"] : []),
                linkerSettings: hasGhostty ? ghosttyLinks : []),
        .executableTarget(name: "kelpd", dependencies: ["Daemon"]),
        .executableTarget(name: "kelp", dependencies: ["Core"]),
        .target(name: "LSPKit", dependencies: ["Core"]),
        .target(name: "WorkbenchKit", dependencies: ["Core"]),
        .target(name: "Integrations", dependencies: ["Core", "GitKit"]),
        .target(name: "Markdown", resources: [.copy("Resources/mermaid.min.js"), .copy("Resources/mermaid-LICENSE.txt")]),   // mermaid 11.17.2, MIT
        .target(name: "EditorKit", dependencies: [.product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "KelpApp",
            dependencies: ["Core", "GitKit", "Agents", "TerminalKit", "EditorKit", "LSPKit", "Markdown", "WorkbenchKit", .product(name: "Sparkle", package: "Sparkle")]
                + (hasGhostty ? ["GhosttyKit"] : []),
            swiftSettings: [.swiftLanguageMode(.v5)],
            // SwiftPM records the deployment target (14.0) as the SDK the app was built with, and AppKit then draws the
            // macOS 14 look (compatibility mode). Naming a current SDK gets the system's own design on macOS 26+.
            // Limit: fixed at 26.0; raise it when a later SDK's look is wanted.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"])]
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
        .testTarget(name: "AgentDataTests", dependencies: ["AgentData"]),
        .testTarget(name: "DaemonTests", dependencies: ["Daemon", "Agents"]),
        .testTarget(name: "LSPKitTests", dependencies: ["LSPKit"]),
        .testTarget(name: "IntegrationsTests", dependencies: ["Integrations"]),
        .testTarget(name: "MarkdownTests", dependencies: ["Markdown"]),
        .testTarget(name: "WorkbenchKitTests", dependencies: ["WorkbenchKit", "Core"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
        .testTarget(name: "KelpAppTests", dependencies: ["KelpApp", "Core"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

if hasGhostty {
    package.targets += [
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    ]
}
