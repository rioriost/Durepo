// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Durepo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DurepoCore", targets: ["DurepoCore"]),
        .executable(name: "durepo-smoke", targets: ["DurepoSmoke"]),
    ],
    targets: [
        .target(
            name: "DurepoCore",
            path: "Sources/DurepoCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DurepoSmoke",
            dependencies: ["DurepoCore"],
            path: "Sources/DurepoSmoke"
        ),
        .testTarget(
            name: "DurepoCoreTests",
            dependencies: ["DurepoCore"],
            path: "Tests/DurepoCoreTests"
        ),
    ]
)
