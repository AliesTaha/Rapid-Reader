// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RapidReader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RapidReaderCore", targets: ["RapidReaderCore"]),
        .executable(name: "RapidReader", targets: ["RapidReader"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")
    ],
    targets: [
        .target(
            name: "RapidReaderCore",
            dependencies: ["ZIPFoundation", "SwiftSoup"],
            path: "Sources/RapidReaderCore"
        ),
        .executableTarget(
            name: "RapidReader",
            dependencies: ["RapidReaderCore"],
            path: "Sources/RapidReader",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by script/build_and_run.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "RapidReaderCoreTests",
            dependencies: ["RapidReaderCore", "ZIPFoundation"],
            path: "Tests/RapidReaderCoreTests"
        )
    ]
)
