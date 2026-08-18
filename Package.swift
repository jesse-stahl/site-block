// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SiteBlock",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "SiteBlockCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SiteBlockCoreTests",
            dependencies: ["SiteBlockCore"]
        ),
        .executableTarget(
            name: "SiteBlockHelper",
            dependencies: ["SiteBlockCore"]
        ),
        .executableTarget(
            name: "SiteBlock",
            dependencies: ["SiteBlockCore"]
        ),
    ]
)
