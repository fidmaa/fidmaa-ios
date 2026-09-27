// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FidmaaCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "FidmaaCore", targets: ["FidmaaCore"]),
    ],
    targets: [
        .target(name: "FidmaaCore"),
        .testTarget(name: "FidmaaCoreTests", dependencies: ["FidmaaCore"]),
    ]
)
