// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AgentBar", targets: ["AgentBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "AgentBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AgentBar",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
