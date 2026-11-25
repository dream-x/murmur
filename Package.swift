// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "murmur",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "murmur",
            path: "Sources/murmur",
            linkerSettings: [
                // Embed Info.plist so TCC shows usage descriptions when run as a bare binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["murmur"],
            path: "Tests/MurmurTests"
        ),
    ]
)
