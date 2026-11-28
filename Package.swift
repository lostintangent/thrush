// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Thrush",
    platforms: [.macOS("27.0"), .iOS("27.2")],
    products: [
        .library(name: "Thrush", targets: ["Thrush"]),
    ],
    targets: [
        .target(name: "ThrushCore"),
        .target(name: "Thrush", dependencies: ["ThrushCore"]),
        // The proofs mount the sample app's window, which they compile from examples/swiftui through Sample.
        .executableTarget(name: "ThrushProofs", dependencies: ["Thrush", "ThrushFixtures"],
                          exclude: ["Sample/SwiftUIExample.swift"]),
        .testTarget(name: "ThrushProofsTests", dependencies: ["ThrushProofs", "Thrush", "ThrushCore"]),
        .testTarget(name: "ThrushTests", dependencies: ["Thrush", "ThrushCore", "ThrushFixtures"]),
        .executableTarget(name: "ThrushServer", dependencies: ["ThrushCore"]),
        .target(
            name: "ThrushFixtures",
            dependencies: ["ThrushCore"],
            path: "Fixtures",
            exclude: ["reference"],
            resources: [.copy("recordings"), .copy("reference/m4/phone/vim-resume.json")]
        ),
        .executableTarget(name: "ThrushBench", dependencies: ["ThrushCore", "ThrushFixtures"],
                          path: "Benchmarks/ThrushBench"),
        .executableTarget(name: "ThrushConformance", dependencies: ["ThrushCore", "ThrushFixtures"]),
        .testTarget(
            name: "ThrushConformanceTests",
            dependencies: ["ThrushConformance", "ThrushFixtures"],
            resources: [.copy("Cases"), .copy("KnownGaps.json"), .copy("ReferenceDefects.json")]
        ),
        .executableTarget(name: "ThrushWebSocketCheck", dependencies: ["Thrush", "ThrushFixtures"],
                          path: "Tests/ThrushWebSocketCheck/Client"),
        .testTarget(name: "ThrushCoreTests", dependencies: ["ThrushCore", "ThrushFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
