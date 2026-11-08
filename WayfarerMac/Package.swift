// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wayfarer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wayfarer",
            path: "Sources/Wayfarer",
            swiftSettings: [.unsafeFlags(["-Ounchecked", "-wmo"], .when(configuration: .release))]
        )
    ]
)
