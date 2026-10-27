// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HelpAndICore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "HelpAndICore", targets: ["HelpAndICore"])],
    targets: [
        .target(name: "HelpAndICore"),
        .testTarget(name: "HelpAndICoreTests", dependencies: ["HelpAndICore"]),
    ]
)
