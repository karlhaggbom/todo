// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Todo",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Todo",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TodoApp",
            dependencies: ["Todo"],
            path: "Sources/TodoApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TodoTests",
            dependencies: ["Todo"],
            path: "Tests/TodoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)