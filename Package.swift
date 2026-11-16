// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnPsql",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PostgresWire", targets: ["PostgresWire"]),
        .library(name: "PostgresKit", targets: ["PostgresKit"]),
        .library(name: "CcinnPsqlKit", targets: ["CcinnPsqlKit"]),
        .executable(name: "CcinnPsql", targets: ["CcinnPsql"]),
    ],
    targets: [
        // PostgreSQL frontend/backend protocol v3: messages, authentication, value decoding. No I/O.
        .target(name: "PostgresWire", swiftSettings: settings),
        // Transport (TLS, SSH), connections, pools, sessions, cancellation and PostgreSQL-aware metadata/operations.
        .target(name: "PostgresKit", dependencies: ["PostgresWire"], swiftSettings: settings),
        // UI-independent app logic: profiles, SQL lexer/guard/completion, EXPLAIN model, charts, export, MCP.
        .target(name: "CcinnPsqlKit", dependencies: ["PostgresKit"], swiftSettings: settings),
        // SwiftUI/AppKit application (and the `mcp` subcommand).
        .executableTarget(name: "CcinnPsql", dependencies: ["PostgresKit", "CcinnPsqlKit"], swiftSettings: settings),

        .testTarget(name: "PostgresWireTests", dependencies: ["PostgresWire"], swiftSettings: settings),
        .testTarget(name: "PostgresKitTests", dependencies: ["PostgresWire", "PostgresKit"], swiftSettings: settings),
        .testTarget(name: "CcinnPsqlKitTests", dependencies: ["PostgresKit", "CcinnPsqlKit"], swiftSettings: settings),
        .testTarget(name: "IntegrationTests", dependencies: ["PostgresWire", "PostgresKit", "CcinnPsqlKit"], swiftSettings: settings),
        // AppKit behaviour of the app's views (editor text storage, input methods).
        .testTarget(name: "CcinnPsqlAppTests", dependencies: ["CcinnPsql", "CcinnPsqlKit"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
