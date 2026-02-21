// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PeerToPeerMessaging",
    platforms: [
        .iOS(.v26),
        .visionOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "PeerToPeerMessaging",
            targets: ["PeerToPeerMessaging"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", .upToNextMajor(from: "1.0.0"))
    ],
    targets: [
        .target(
            name: "PeerToPeerMessaging",
            dependencies: [.product(name: "X509", package: "swift-certificates")]
        ),
        .testTarget(
            name: "PeerToPeerMessagingTests",
            dependencies: ["PeerToPeerMessaging"]
        )
    ]
)

