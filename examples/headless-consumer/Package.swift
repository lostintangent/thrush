// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HeadlessConsumer",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [.product(name: "Thrush", package: "thrush")],
            // Swift Build passes Foundation to the linker for this executable.
            // Strip unused dylibs so otool reports the libraries the example actually needs.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]
        )
    ],
    swiftLanguageModes: [.v6]
)
