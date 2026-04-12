// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "orrery-sync",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "orrery-sync", targets: ["OrrerySync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/OffskyLab/swift-nmtp.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
    ],
    targets: [
        .executableTarget(name: "OrrerySync", dependencies: [
            .product(name: "NMTP", package: "swift-nmtp"),
            .product(name: "NMTPeer", package: "swift-nmtp"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .testTarget(name: "OrrerySyncTests", dependencies: [
            "OrrerySync",
            .product(name: "NMTPeer", package: "swift-nmtp"),
        ]),
    ]
)
