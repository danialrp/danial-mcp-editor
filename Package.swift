// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanialMCPEditor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .executable(name: "DanialMCPEditor", targets: ["EditorApp"]),
        .executable(name: "dme", targets: ["dme"]),
        .executable(name: "dme-probe", targets: ["dme-probe"]),
    ],
    targets: [
        // Data model, commands and time maths. Pure Swift: no media frameworks.
        .target(name: "EditorCore"),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),

        // Command bus, journal, undo, user settings and the tool catalog.
        .target(name: "EditorKit", dependencies: ["EditorCore"]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),

        // AVFoundation and Metal: media probing now, playback and rendering later.
        .target(name: "MediaEngine", dependencies: ["EditorCore", "EditorKit"]),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine"], exclude: ["Fixtures"]),

        // Model Context Protocol: JSON-RPC handler, HTTP and stdio transports.
        .target(name: "MCPServer", dependencies: ["EditorKit"]),
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer", "MediaEngine"]),

        // The editor without a window: runs the MCP server.
        .executableTarget(name: "dme", dependencies: ["EditorKit", "MediaEngine", "MCPServer"]),

        // The app: window, player, timeline, keymap, with the MCP server inside.
        .executableTarget(name: "EditorApp", dependencies: ["EditorKit", "MediaEngine", "MCPServer"]),

        // Phase 0 measurement tool. See docs/phase0.md.
        // Throwaway code: Swift 5 mode keeps AVFoundation callbacks simple.
        .executableTarget(
            name: "dme-probe",
            dependencies: ["EditorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
