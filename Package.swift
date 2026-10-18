// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Plumb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Plumb",
            path: "Sources/Plumb",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "PlumbTests", dependencies: ["Plumb"], path: "Tests/PlumbTests"),
    ]
)
