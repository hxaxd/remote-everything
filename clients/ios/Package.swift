// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteEverything",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "RemoteEverything", targets: ["RemoteEverything"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RemoteEverything",
            path: "RemoteEverything",
            exclude: ["Resources/Info.plist", "App/RemoteEverythingApp.swift"],
            // Whole directories, so a new Core/ or App/ subdirectory is compiled
            // instead of silently missing from the SwiftPM build.
            sources: ["App", "Core"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ]
        ),
        .testTarget(
            name: "RemoteEverythingTests",
            dependencies: ["RemoteEverything"],
            path: "RemoteEverythingTests"
        ),
    ]
)
