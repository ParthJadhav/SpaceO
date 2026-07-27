// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceO",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaceOKit", targets: ["SpaceOKit"]),
        .executable(name: "spaceo", targets: ["spaceo"]),
        .executable(name: "SpaceOViewer", targets: ["SpaceOViewer"]),
    ],
    targets: [
        // The only target that touches private API. dlsym avoids hard-link failure when a symbol
        // disappears; higher-level lifecycle and route checks validate mutation behavior.
        .target(
            name: "SpaceOPrivate",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .target(
            name: "SpaceOKit",
            dependencies: ["SpaceOPrivate"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .target(name: "SpaceOMCP", dependencies: ["SpaceOKit"]),
        .executableTarget(name: "spaceo", dependencies: ["SpaceOKit", "SpaceOMCP"]),
        // The VM-style console app. Touches no private API itself; everything unusual it does
        // (per-PID event delivery, window stamping) goes through SpaceOKit's MirrorInput.
        .executableTarget(
            name: "SpaceOViewer",
            dependencies: ["SpaceOKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .testTarget(
            name: "SpaceOKitTests",
            dependencies: ["SpaceOKit", "SpaceOMCP", "SpaceOPrivate"]
        ),
    ]
)
