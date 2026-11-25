// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Thrush",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "Thrush", targets: ["Thrush"]),
        .library(name: "ThrushUI", targets: ["ThrushUI"]),
        .library(name: "ThrushConnection", targets: ["ThrushConnection"]),
        .executable(name: "ThrushBench", targets: ["ThrushBench"]),
    ],
    targets: [
        .target(name: "Thrush"),
        .target(name: "ThrushUI", dependencies: ["Thrush"]),
        .executableTarget(name: "ThrushDemo", dependencies: ["ThrushUI", "ThrushConnection", "Thrush"]),
        .testTarget(name: "ThrushUITests", dependencies: ["ThrushUI", "Thrush", "ThrushFixtures"]),
        .target(name: "ThrushConnection", dependencies: ["Thrush"]),
        .executableTarget(name: "ThrushPTYCheck", dependencies: ["Thrush", "ThrushConnection"]),
        .target(
            name: "ThrushFixtures",
            dependencies: ["Thrush"],
            path: "Fixtures",
            exclude: ["reference"],
            resources: [.copy("first-bytes.json"), .copy("replays")]
        ),
        .executableTarget(name: "ThrushBench", dependencies: ["Thrush", "ThrushFixtures"]),
        .executableTarget(
            name: "ThrushLoopbackCheck",
            dependencies: ["Thrush", "ThrushConnection", "ThrushFixtures"]
        ),
        .testTarget(name: "ThrushTests", dependencies: ["Thrush", "ThrushFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
