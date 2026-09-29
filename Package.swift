// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Focus",
    // MenuBarExtra was introduced in macOS 13.
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FocusApp", targets: ["FocusApp"]),
        .executable(name: "focus", targets: ["FocusCLI"]),
    ],
    targets: [
        // Shared engine: store, queue rules, sources. No UI.
        .target(
            name: "FocusCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Menubar app. Bundled into Focus.app by `make app`.
        .executableTarget(name: "FocusApp", dependencies: ["FocusCore"]),
        // `focus` CLI for humans and LLM agents.
        .executableTarget(name: "FocusCLI", dependencies: ["FocusCore"]),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"]),
    ]
)
