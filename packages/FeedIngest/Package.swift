// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FeedIngest",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "FeedIngest", targets: ["FeedIngest"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(name: "FeedIngest", dependencies: ["PlateKit"]),
        .testTarget(name: "FeedIngestTests", dependencies: ["FeedIngest"]),
    ]
)
