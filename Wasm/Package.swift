// swift-tools-version: 6.4
import PackageDescription

// ThrushCore built for WebAssembly with Embedded Swift, behind a few exports over linear memory.
// The core's sources are the repository's own, linked in unchanged.
let package = Package(
    name: "ThrushWasm",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "ThrushCore"),
        .executableTarget(
            name: "ThrushWasm",
            dependencies: ["ThrushCore"],
            linkerSettings: [
                // The host calls the exports, and nothing runs at start.
                .unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"]),
                // Grapheme breaking reads the standard library's Unicode tables, which Embedded Swift links on request.
                .linkedLibrary("swiftUnicodeDataTables"),
            ]
        ),
        // The same operations run natively, so the check can compare both builds' replays byte for byte.
        .executableTarget(name: "NativeReplay", dependencies: ["ThrushCore"]),
    ]
)
