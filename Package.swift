// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XRadar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "XRadarCore",
            targets: ["XRadarCore"]
        ),
        .executable(
            name: "XRadar",
            targets: ["XRadar"]
        )
    ],
    targets: [
        .target(
            name: "XRadarCore",
            path: "Sources/XRadarCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"])
            ]
        ),
        .executableTarget(
            name: "XRadar",
            dependencies: ["XRadarCore"],
            path: "XRadar",
            exclude: ["Resources"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "XRadarTests",
            dependencies: ["XRadarCore"],
            path: "XRadarTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "XRadarVerifier",
            dependencies: ["XRadarCore"],
            path: "XRadarVerifier",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
