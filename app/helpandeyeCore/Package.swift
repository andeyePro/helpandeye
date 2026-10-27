// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "helpandeyeCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "helpandeyeCore", targets: ["helpandeyeCore"])],
    targets: [
        .target(name: "helpandeyeCore"),
        .testTarget(name: "helpandeyeCoreTests", dependencies: ["helpandeyeCore"]),
    ]
)
