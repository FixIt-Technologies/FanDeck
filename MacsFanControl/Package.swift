// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacsFanControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacsFanControl", targets: ["MacsFanControl"]),
        .executable(name: "fans", targets: ["fans"]),
        .library(name: "MacsFanControlCore", targets: ["MacsFanControlCore"]),
    ],
    targets: [
        .target(
            name: "MacsFanControlCore",
            path: "Sources/MacsFanControlCore"
        ),
        .executableTarget(
            name: "MacsFanControl",
            dependencies: ["MacsFanControlCore"],
            path: "Sources/MacsFanControl"
        ),
        .executableTarget(
            name: "fans",
            dependencies: ["MacsFanControlCore"],
            path: "Sources/fans"
        ),
        .testTarget(
            name: "MacsFanControlTests",
            dependencies: ["MacsFanControlCore"],
            path: "Tests/MacsFanControlTests"
        ),
    ]
)
