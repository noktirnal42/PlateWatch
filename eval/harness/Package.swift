// swift-tools-version: 6.0
import PackageDescription

/// Offline evaluation harness: runs the production analysis path (decode →
/// PlateAnalysisPipeline → fleet markings → RedactionGate) over a labelled
/// image corpus and scores it. See eval/README.md.
let package = Package(
    name: "EvalHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../packages/PlateKit"),
        .package(path: "../../packages/CaptureKit"),
        .package(path: "../../packages/VehicleML"),
    ],
    targets: [
        .executableTarget(name: "EvalHarness", dependencies: [
            .product(name: "PlateKit", package: "PlateKit"),
            .product(name: "CaptureKit", package: "CaptureKit"),
            .product(name: "VehicleML", package: "VehicleML"),
        ]),
    ]
)
