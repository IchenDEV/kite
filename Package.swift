// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SuperDD",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "SuperDD", targets: ["SuperDD"]),
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
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "SuperDDTests",
            dependencies: ["SuperDD"],
            path: "Tests/SuperDDTests"
        ),
    ]
)
