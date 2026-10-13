// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlateKit",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "PlateKit", targets: ["PlateKit"]),
    ],
    targets: [
        .target(name: "PlateKit", resources: [.copy("Resources/gazetteer.tsv")]),
        .testTarget(name: "PlateKitTests", dependencies: ["PlateKit"]),
    ]
)
