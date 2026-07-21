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
            sources: [
                "App/",
                "Core/Models/",
                "Core/Network/",
                "Core/Security/",
                "Core/Storage/",
                "Core/Web/",
                "Core/Update/",
                "Features/Setup/",
                "Features/Catalog/",
                "Features/Connections/",
                "Features/Settings/",
                "Features/Remote/",
            ]
        ),
        .testTarget(
            name: "RemoteEverythingTests",
            dependencies: ["RemoteEverything"],
            path: "RemoteEverythingTests"
        ),
    ]
)
