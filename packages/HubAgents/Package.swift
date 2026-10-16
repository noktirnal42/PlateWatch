// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HubAgents", platforms: [.macOS(.v14)],
    products: [
        .library(name: "HubAgentCore", targets: ["HubAgentCore"]),
        .library(name: "HubAgentProviders", targets: ["HubAgentProviders"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", exact: "2.29.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.29.1")
    ],
    targets: [
        .target(name: "HubAgentCore"),
        .target(name: "HubAgentProviders", dependencies: ["HubAgentCore",
            .product(name: "MLXLLM", package: "mlx-swift-examples"),
            .product(name: "MLXLMCommon", package: "mlx-swift-examples")]),
        .testTarget(name: "HubAgentCoreTests", dependencies: ["HubAgentCore"])
    ]
)
