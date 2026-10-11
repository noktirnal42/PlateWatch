// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FleetImporters",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "FleetImporters", targets: ["FleetImporters"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(name: "FleetImporters", dependencies: ["PlateKit"]),
        .testTarget(name: "FleetImportersTests", dependencies: ["FleetImporters"]),
    ]
)
