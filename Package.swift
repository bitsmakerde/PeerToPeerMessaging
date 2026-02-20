// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PeerToPeerMessaging",
    platforms: [
        .iOS(.v18),
        .visionOS(.v2),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PeerToPeerMessaging",
            targets: ["PeerToPeerMessaging"]
        )
    ],
    targets: [
        .target(
            name: "PeerToPeerMessaging",
            dependencies: []
        ),
        .testTarget(
            name: "PeerToPeerMessagingTests",
            dependencies: ["PeerToPeerMessaging"]
        )
    ]
)
