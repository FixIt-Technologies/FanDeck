// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings

let packageSettings = PackageSettings(
    productTypes: [
        "ViewInspector": .framework,
    ]
)
#endif

let package = Package(
    name: "GenesisFansDependencies",
    dependencies: [
        // Headless SwiftUI view-tree testing (test target only).
        .package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.10.0"),
    ]
)
