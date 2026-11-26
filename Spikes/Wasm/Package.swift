// swift-tools-version: 6.4
import PackageDescription

// ThrushCore built for WebAssembly, behind a handful of exports over linear memory. The core's
// sources are the repository's own, linked in unchanged.
let package = Package(
    name: "ThrushWasm",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "ThrushCore"),
        .executableTarget(
            name: "ThrushWasm",
            dependencies: ["ThrushCore"],
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"])]
        ),
        // The same operations run natively, to check that both builds replay the same bytes.
        .executableTarget(name: "NativeReplay", dependencies: ["ThrushCore"]),
    ]
)
