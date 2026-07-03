// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cc-meter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CCMeterCore"),
        .executableTarget(
            name: "cc-meter",
            dependencies: ["CCMeterCore"]
        ),
        .testTarget(
            name: "CCMeterCoreTests",
            dependencies: ["CCMeterCore"]
        )
    ]
)
