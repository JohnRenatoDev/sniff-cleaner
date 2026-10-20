// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sniff",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SniffCore", targets: ["SniffCore"]),
        .executable(name: "Sniff", targets: ["Sniff"]),
        .executable(name: "SniffScheduler", targets: ["SniffScheduler"]),
        .executable(name: "SniffIcon", targets: ["SniffIcon"]),
        .executable(name: "SniffCLI", targets: ["SniffCLI"])
    ],
    targets: [
        .target(name: "SniffCore", resources: [.process("Resources")]),
        .target(name: "SniffIdentity", dependencies: ["SniffCore"]),
        .target(name: "SniffCommands", dependencies: ["SniffCore"]),
        .executableTarget(name: "SniffCLI", dependencies: ["SniffCommands"]),
        .executableTarget(name: "Sniff", dependencies: ["SniffCore", "SniffIdentity"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "SniffScheduler", dependencies: ["SniffCore"]),
        .executableTarget(name: "SniffIcon", dependencies: ["SniffIdentity"]),
        .testTarget(name: "SniffMotionTests", dependencies: ["SniffIdentity"]),
        .testTarget(name: "SniffCoreTests", dependencies: ["SniffCore"]),
        .testTarget(name: "SniffCommandTests", dependencies: ["SniffCore", "SniffCommands"])
    ]
)
