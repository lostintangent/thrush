// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AppConsumer",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(name: "thrush", path: "../..")],
    targets: [
        .executableTarget(name: "AppConsumer", dependencies: [.product(name: "Thrush", package: "thrush")]),
    ],
    swiftLanguageModes: [.v6]
)
