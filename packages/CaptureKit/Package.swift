// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
    ],
    dependencies: [
        .package(path: "../PlateKit"),
    ],
    targets: [
        .target(name: "CaptureKit", dependencies: ["PlateKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
    ]
)
