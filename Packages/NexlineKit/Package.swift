// swift-tools-version:5.10
// NexlineCore: pure Swift (levels, barge-in), tested with `swift test` on any host.
// NexlineAudio: the iOS audio engine; its code is iOS-only, so the package still builds on macOS for tests.
import PackageDescription

let package = Package(
    name: "NexlineKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NexlineCore", targets: ["NexlineCore"]),
        .library(name: "NexlineAudio", targets: ["NexlineAudio"]),
    ],
    targets: [
        .target(name: "NexlineCore"),
        .target(name: "NexlineAudio", dependencies: ["NexlineCore"]),
        .testTarget(name: "NexlineCoreTests", dependencies: ["NexlineCore"]),
    ]
)
