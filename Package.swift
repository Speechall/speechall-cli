// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "speechall-cli",
    platforms: [.macOS(.v26)],
    dependencies: [
        // .package(url: "https://github.com/Speechall/speechall-swift-sdk", branch: "main"),
        .package(path: "/Users/atacan/Developer/Repositories/Speechall-SDK/speechall-swift-sdk/"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "speechall-cli",
            dependencies: [
                .product(name: "SpeechallAPI", package: "speechall-swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)
