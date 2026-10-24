// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SIADesktop",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SIACore"),
        .executableTarget(name: "siactl", dependencies: ["SIACore"]),
        .executableTarget(name: "SIAApp", dependencies: ["SIACore"],
                          linkerSettings: [.linkedFramework("AVKit"),
                                           .linkedFramework("AVFoundation")]),
        .executableTarget(name: "siatests", dependencies: ["SIACore"]),
    ]
)
