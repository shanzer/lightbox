// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LightboxCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LightboxCore", targets: ["LightboxCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1"))
    ],
    targets: [
        .target(
            name: "LightboxCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "LightboxCoreTests",
            dependencies: ["LightboxCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
