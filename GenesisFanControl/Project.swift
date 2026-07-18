import ProjectDescription

// Tuist twin of Package.swift — same four products + tests, sources unchanged.
// SPM (`swift build` / `swift test` + the bun scripts) keeps working alongside;
// this manifest exists so the GenesisFans workspace can build the legacy app
// and FanDeck from one Xcode workspace.

let adHocSigning: SettingsDictionary = [
    // Local builds ad-hoc sign (no Apple team/profile) so apps launch unsigned.
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "-",
    "DEVELOPMENT_TEAM": "",
    "PROVISIONING_PROFILE_SPECIFIER": "",
    "SWIFT_VERSION": "5.10",
]

let project = Project(
    name: "GenesisFanControl",
    targets: [
        .target(
            name: "GenesisFanControlCore",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.foltyn.genesis-fan-control.core",
            deploymentTargets: .macOS("14.0"),
            sources: ["Sources/GenesisFanControlCore/**"],
            settings: .settings(base: adHocSigning)
        ),
        .target(
            name: "GenesisFanControl",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.foltyn.genesis-fan-control",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "GenesisFanControl",
                "CFBundleName": "GenesisFanControl",
                "CFBundleIconFile": "AppIcon",
                "LSApplicationCategoryType": "public.app-category.utilities",
                "NSHumanReadableCopyright": "",
            ]),
            sources: ["Sources/GenesisFanControl/**"],
            resources: ["scripts/AppIcon.icns"],
            dependencies: [
                .target(name: "GenesisFanControlCore"),
            ],
            settings: .settings(base: adHocSigning)
        ),
        .target(
            name: "genesis-fan-control-helper",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "dev.foltyn.genesis-fan-control.helper",
            deploymentTargets: .macOS("14.0"),
            sources: ["Sources/GenesisFanControlHelper/**"],
            dependencies: [
                .target(name: "GenesisFanControlCore"),
            ],
            settings: .settings(base: adHocSigning)
        ),
        .target(
            name: "fans",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "dev.foltyn.genesis-fan-control.fans",
            deploymentTargets: .macOS("14.0"),
            sources: ["Sources/fans/**"],
            dependencies: [
                .target(name: "GenesisFanControlCore"),
            ],
            settings: .settings(base: adHocSigning)
        ),
        .target(
            name: "GenesisFanControlTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.foltyn.genesis-fan-control.tests",
            deploymentTargets: .macOS("14.0"),
            sources: ["Tests/GenesisFanControlTests/**"],
            dependencies: [
                .target(name: "GenesisFanControl"),
                .target(name: "GenesisFanControlCore"),
                .external(name: "ViewInspector"),
            ],
            settings: .settings(base: adHocSigning)
        ),
    ]
)
