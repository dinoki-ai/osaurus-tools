// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OsaurusGit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusGit", type: .dynamic, targets: ["OsaurusGit"])
    ],
    targets: [
        .target(
            name: "OsaurusGit",
            path: "Sources/OsaurusGit"
        )
    ]
)
