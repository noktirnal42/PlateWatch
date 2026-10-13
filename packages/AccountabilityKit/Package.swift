// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AccountabilityKit",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "AccountabilityKit", targets: ["AccountabilityKit"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(name: "AccountabilityKit", dependencies: ["PlateKit"]),
        .testTarget(name: "AccountabilityKitTests", dependencies: ["AccountabilityKit"]),
    ]
)
