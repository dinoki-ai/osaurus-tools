// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusFilesystem",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusFilesystem", type: .dynamic, targets: ["OsaurusFilesystem"])
    ],
    targets: [
        .target(
            name: "OsaurusFilesystem",
            path: "Sources/OsaurusFilesystem"
        )
    ]
)
