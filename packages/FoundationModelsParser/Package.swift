// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsParser",
    platforms: [
        .macOS(.v15), .iOS(.v18), .watchOS(.v11), .tvOS(.v18)
    ],
    products: [
        .library(name: "FoundationModelsParser", targets: ["FoundationModelsParser"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(
            name: "FoundationModelsParser",
            dependencies: [
                .product(name: "PlateKit", package: "PlateKit"),
            ]
        ),
        .testTarget(
            name: "FoundationModelsParserTests",
            dependencies: ["FoundationModelsParser"]
        ),
    ]
)