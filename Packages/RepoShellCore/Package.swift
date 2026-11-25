// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RepoShellCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RepoShellShared", targets: ["RepoShellShared"]),
        .library(name: "RepoShellVcs", targets: ["RepoShellVcs"]),
        .library(name: "RepoShellServices", targets: ["RepoShellServices"]),
    ],
    targets: [
        .target(
            name: "RepoShellShared",
            dependencies: []
        ),
        .target(
            name: "RepoShellVcs",
            dependencies: ["RepoShellShared"]
        ),
        .target(
            name: "RepoShellServices",
            dependencies: ["RepoShellShared", "RepoShellVcs"]
        ),
        .testTarget(
            name: "RepoShellCoreTests",
            dependencies: ["RepoShellShared", "RepoShellVcs", "RepoShellServices"]
        ),
    ]
)
