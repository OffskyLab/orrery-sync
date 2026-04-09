// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "orbital-sync",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "orbital-sync", targets: ["OrbitalSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/OffskyLab/swift-nmtp.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(name: "OrbitalSync", dependencies: [
            .product(name: "NMTP", package: "swift-nmtp"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "OrbitalSyncTests", dependencies: ["OrbitalSync"]),
    ]
)
