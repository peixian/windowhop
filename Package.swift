// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowHop",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowHop", targets: ["WindowHop"])],
    targets: [
        .target(name: "WindowHopCore"),
        .executableTarget(name: "WindowHop", dependencies: ["WindowHopCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("Carbon")]),
        .testTarget(name: "WindowHopCoreTests", dependencies: ["WindowHopCore"])
    ]
)
