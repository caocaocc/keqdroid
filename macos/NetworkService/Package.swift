// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KEQNetworkService",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "KEQNetworkClient", targets: ["KEQNetworkClient"]),
        .executable(name: "keqdis-network-service", targets: ["NetworkServiceDaemon"]),
        .executable(name: "keqdis-network-tests", targets: ["NetworkServiceChecks"]),
    ],
    targets: [
        .target(name: "CNetworkXPC", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Security")]),
        .target(name: "KEQNetworkClient", dependencies: ["CNetworkXPC"]),
        .target(name: "NetworkServiceKit", dependencies: ["CNetworkXPC"], linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Security")]),
        .executableTarget(name: "NetworkServiceDaemon", dependencies: ["NetworkServiceKit", "CNetworkXPC"]),
        .executableTarget(name: "NetworkServiceChecks", dependencies: ["NetworkServiceKit", "KEQNetworkClient", "CNetworkXPC"]),
        .testTarget(name: "NetworkServiceTests", dependencies: ["NetworkServiceKit", "KEQNetworkClient"]),
    ]
)
