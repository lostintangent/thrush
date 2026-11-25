// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Thrush",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "Thrush", targets: ["Thrush"]),
        .library(name: "ThrushUI", targets: ["ThrushUI"]),
        .executable(name: "ThrushBench", targets: ["ThrushBench"]),
    ],
    targets: [
        .target(name: "Thrush"),
        .target(name: "ThrushUI", dependencies: ["Thrush"]),
        .target(
            name: "ThrushFixtures",
            path: "Fixtures",
            exclude: ["reference"],
            resources: [.copy("first-bytes.json")]
        ),
        .executableTarget(name: "ThrushBench", dependencies: ["Thrush", "ThrushFixtures"]),
        .testTarget(name: "ThrushTests", dependencies: ["Thrush", "ThrushFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
