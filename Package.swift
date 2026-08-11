// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SuperDD",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "SuperDD", targets: ["SuperDD"]),
        .executable(name: "superddctl", targets: ["SuperDDCLI"]),
        .executable(name: "superdd-plugin-host", targets: ["SuperDDPluginHost"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"])]
        ),
        .executableTarget(
            name: "SuperDD",
            dependencies: ["CSQLite"],
            path: "Sources/SuperDD",
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
            name: "SuperDDPluginHost",
            path: "Sources/SuperDDPluginHost",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "SuperDDTests",
            dependencies: ["SuperDD"],
            path: "Tests/SuperDDTests"
        ),
        .executableTarget(
            name: "SuperDDCLI",
            path: "Sources/SuperDDCLI",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
