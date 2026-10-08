// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Scribe", targets: ["Scribe"]),
        .executable(name: "scribe-cli", targets: ["scribe-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "ScribeCore",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        .executableTarget(name: "Scribe", dependencies: ["ScribeCore"]),
        .executableTarget(name: "scribe-cli", dependencies: ["ScribeCore"]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
    ]
)
