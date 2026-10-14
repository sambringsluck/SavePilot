// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SavePilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SavePilot", targets: ["SavePilot"])
    ],
    targets: [
        .executableTarget(
            name: "SavePilot",
            path: "Sources/SavePilot"
        )
    ],
    swiftLanguageModes: [.v5]
)
