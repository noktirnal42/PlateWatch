// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VehicleML",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VehicleML", targets: ["VehicleML"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(name: "VehicleML", dependencies: ["PlateKit"]),
        .testTarget(name: "VehicleMLTests", dependencies: ["VehicleML"]),
    ]
)
