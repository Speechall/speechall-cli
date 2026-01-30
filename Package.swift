// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "speechall-cli",
    platforms: [.macOS(.v26)],
    dependencies: [
        // .package(url: "https://github.com/Speechall/speechall-swift-sdk", branch: "main"),
        .package(path: "/Users/atacan/Developer/Repositories/Speechall-SDK/speechall-swift-sdk/"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.8.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "speechall",
            dependencies: [
                .product(name: "SpeechallAPI", package: "speechall-swift-sdk"),
                .product(name: "SpeechallAPITypes", package: "speechall-swift-sdk"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)
