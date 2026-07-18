import ProjectDescription

let project = Project(
    name: "FanDeck",
    targets: [
        .target(
            name: "FanDeck",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.foltyn.fandeck",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "FanDeck",
                "CFBundleName": "FanDeck",
                "CFBundleIconFile": "AppIcon",
                "LSApplicationCategoryType": "public.app-category.utilities",
                // Menu-bar-first agent: no dock icon by default. AppDelegate
                // promotes to .regular while the compact window is open.
                "LSUIElement": true,
                "NSHumanReadableCopyright": "",
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "GenesisFanControlCore", path: "../GenesisFanControl"),
            ],
            settings: .settings(base: [
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "-",
                "DEVELOPMENT_TEAM": "",
                "PROVISIONING_PROFILE_SPECIFIER": "",
                "SWIFT_VERSION": "5.10",
            ])
        ),
    ]
)
