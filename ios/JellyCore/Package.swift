// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JellyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JellyCore", targets: ["JellyCore"]),
    ],
    targets: [
        .target(name: "JellyCore"),
        .testTarget(name: "JellyCoreTests", dependencies: ["JellyCore"]),
    ]
)
