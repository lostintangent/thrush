// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Sample",
    platforms: [.macOS("27.0"), .iOS("27.2")],
    dependencies: [.package(name: "thrush", path: "../..")],
    targets: [
        .executableTarget(name: "Sample", dependencies: [.product(name: "Thrush", package: "thrush")]),
    ],
    swiftLanguageModes: [.v6]
)
