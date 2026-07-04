// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FactorJ",
    defaultLocalization: "pt-BR",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "FactorJ", targets: ["FactorJ"]),
        .library(name: "FactorJCore", targets: ["FactorJCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "FactorJCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/FactorJCore"
        ),
        .executableTarget(
            name: "FactorJ",
            dependencies: ["FactorJCore"],
            path: "Sources/FactorJ"
        ),
        .testTarget(
            name: "FactorJCoreTests",
            dependencies: ["FactorJCore"],
            path: "Tests/FactorJCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
