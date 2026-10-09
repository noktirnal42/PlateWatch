// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlateSync",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "PlateSync", targets: ["PlateSync"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(name: "PlateSync", dependencies: ["PlateKit"]),
        .testTarget(name: "PlateSyncTests", dependencies: ["PlateSync"]),
    ]
)
