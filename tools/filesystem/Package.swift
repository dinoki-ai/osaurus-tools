// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusFilesystem",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusFilesystem", type: .dynamic, targets: ["Plugin"])
    ],
    targets: [
        .target(
            name: "Plugin",
            path: "Sources/Plugin"
        )
    ]
)
