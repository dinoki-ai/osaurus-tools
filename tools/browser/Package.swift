// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusBrowser",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusBrowser", type: .dynamic, targets: ["OsaurusBrowser"])
    ],
    targets: [
        .target(
            name: "OsaurusBrowser",
            path: "Sources/OsaurusBrowser",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "OsaurusBrowserTests",
            dependencies: ["OsaurusBrowser"],
            path: "Tests/OsaurusBrowserTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
