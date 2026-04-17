// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NightModeNativeMVP",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "NightModeNativeCore",
            targets: ["NightModeNativeCore"]
        ),
        .executable(
            name: "NightModeNativeMVP",
            targets: ["NightModeNativeCLI"]
        ),
        .executable(
            name: "NightModeNativeApp",
            targets: ["NightModeNativeApp"]
        ),
    ],
    targets: [
        .target(
            name: "NightModeNativeCore"
        ),
        .executableTarget(
            name: "NightModeNativeCLI",
            dependencies: ["NightModeNativeCore"]
        ),
        .executableTarget(
            name: "NightModeNativeApp",
            dependencies: ["NightModeNativeCore"],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
