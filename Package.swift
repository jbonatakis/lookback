// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookback",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Lookback", targets: ["Lookback"])],
    targets: [
        .target(name: "Lookback"),
        .testTarget(name: "LookbackTests", dependencies: ["Lookback"])
    ]
)
