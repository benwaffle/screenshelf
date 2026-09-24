// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Screenshelf",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Screenshelf", targets: ["Screenshelf"]),
        .executable(name: "shelf", targets: ["shelf"]),
    ],
    targets: [
        .target(
            name: "ShelfCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Screenshelf",
            dependencies: ["ShelfCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "shelf",
            dependencies: ["ShelfCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
