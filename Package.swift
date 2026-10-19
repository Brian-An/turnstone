// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Turnstone",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TurnstoneCore", targets: ["TurnstoneCore"]),
        .executable(name: "Turnstone", targets: ["Turnstone"])
    ],
    targets: [
        .target(name: "TurnstoneCore"),
        // VideoPlayer's SwiftUI overlay resolves AVPlayerView dynamically.
        .executableTarget(name: "Turnstone", dependencies: ["TurnstoneCore"], linkerSettings: [.linkedFramework("AVKit")]),
        .testTarget(name: "TurnstoneCoreTests", dependencies: ["TurnstoneCore"]),
        .testTarget(name: "TurnstoneAppTests", dependencies: ["Turnstone"])
    ]
)
