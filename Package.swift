// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookback",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Lookback", targets: ["Lookback"]),
        .executable(name: "lookback-demo", targets: ["LookbackDemo"])
    ],
    targets: [
        .target(name: "Lookback"),
        .executableTarget(name: "LookbackDemo", dependencies: ["Lookback"], path: "Examples/LookbackDemo"),
        .testTarget(name: "LookbackTests", dependencies: ["Lookback"], resources: [.copy("Fixtures")])
    ]
)
