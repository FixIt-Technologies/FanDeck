// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GenesisFanControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GenesisFanControl", targets: ["GenesisFanControl"]),
        .executable(name: "fans", targets: ["fans"]),
        .executable(name: "genesis-fan-control-helper", targets: ["GenesisFanControlHelper"]),
        .library(name: "GenesisFanControlCore", targets: ["GenesisFanControlCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector",
                 .upToNextMajor(from: "0.9.11")),
    ],
    targets: [
        .target(
            name: "GenesisFanControlCore",
            path: "Sources/GenesisFanControlCore"
        ),
        .executableTarget(
            name: "GenesisFanControl",
            dependencies: ["GenesisFanControlCore"],
            path: "Sources/GenesisFanControl"
        ),
        .executableTarget(
            name: "fans",
            dependencies: ["GenesisFanControlCore"],
            path: "Sources/fans"
        ),
        .executableTarget(
            name: "GenesisFanControlHelper",
            dependencies: ["GenesisFanControlCore"],
            path: "Sources/GenesisFanControlHelper"
        ),
        .testTarget(
            name: "GenesisFanControlTests",
            dependencies: [
                "GenesisFanControlCore",
                "GenesisFanControl",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/GenesisFanControlTests"
        ),
    ]
)
