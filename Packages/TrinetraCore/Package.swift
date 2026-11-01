// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrinetraCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TrinetraCore", targets: ["TrinetraCore"]),
        .executable(name: "trinetra", targets: ["trinetra"]),
    ],
    targets: [
        .target(name: "TrinetraCore"),
        .executableTarget(name: "trinetra", dependencies: ["TrinetraCore"]),
        .testTarget(name: "TrinetraCoreTests", dependencies: ["TrinetraCore"]),
    ]
)
