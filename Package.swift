// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenTangerine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TangerineCore", targets: ["TangerineCore"]),
        .executable(name: "OpenTangerine", targets: ["OpenTangerine"])
    ],
    targets: [
        .target(name: "TangerineCore"),
        .executableTarget(name: "OpenTangerine", dependencies: ["TangerineCore"]),
        .testTarget(name: "TangerineCoreTests", dependencies: ["TangerineCore"])
    ]
)
