// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kite",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Kite", targets: ["Kite"]),
        .executable(name: "kitectl", targets: ["KiteCLI"]),
        .executable(name: "kite-plugin-host", targets: ["KitePluginHost"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"])]
        ),
        .executableTarget(
            name: "Kite",
            dependencies: ["CSQLite"],
            path: "Sources/Kite",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "KitePluginHost",
            path: "Sources/KitePluginHost",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "KiteTests",
            dependencies: ["Kite"],
            path: "Tests/KiteTests"
        ),
        .executableTarget(
            name: "KiteCLI",
            path: "Sources/KiteCLI",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
