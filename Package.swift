// swift-tools-version: 5.9

import PackageDescription

// Keep products and targets aligned with the source monorepo's Package.swift;
// only the relative paths differ so this manifest works after public export.
let package = Package(
    name: "M2CCheckout",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "M2CCheckout", targets: ["M2CCheckout"])
    ],
    targets: [
        .target(
            name: "M2CCheckoutCore",
            path: "Sources/M2CCheckoutCore"
        ),
        .target(
            name: "M2CCheckout",
            dependencies: ["M2CCheckoutCore"],
            path: "Sources/M2CCheckout",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "M2CCheckoutCoreTests",
            dependencies: ["M2CCheckoutCore"],
            path: "Tests/M2CCheckoutCoreTests",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "M2CCheckoutTests",
            dependencies: ["M2CCheckout", "M2CCheckoutCore"],
            path: "Tests/M2CCheckoutTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
