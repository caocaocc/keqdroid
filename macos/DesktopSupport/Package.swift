// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopSupport",
    platforms: [.macOS(.v12)],
    products: [.library(name: "KEQDesktopSupport", targets: ["KEQDesktopSupport"]),
               .executable(name: "keqdis-desktop-tests", targets: ["DesktopChecks"])],
    targets: [
        .target(name: "KEQDesktopSupport", linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "DesktopChecks", dependencies: ["KEQDesktopSupport"]),
        .testTarget(name: "KEQDesktopSupportTests", dependencies: ["KEQDesktopSupport"])
    ]
)
