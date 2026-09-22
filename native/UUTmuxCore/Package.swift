// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UUTmuxCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UUTmuxCore", targets: ["UUTmuxCore"]),
    ],
    targets: [
        .target(name: "UUTmuxCore"),
        .testTarget(name: "UUTmuxCoreTests", dependencies: ["UUTmuxCore"]),
    ]
)
