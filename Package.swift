// swift-tools-version: 6.0
import PackageDescription

// MotionKernel is the pure-Swift, Apple-framework-free core of the motion-design app.
// HARD RULE (platform-strategy.md §2): no imports of AppKit, Metal, CoreText,
// AVFoundation, CoreGraphics — nothing Apple-only. It must build and test on Linux.
// CoreText/Metal live in the app target behind the RenderTree boundary.
let package = Package(
    name: "Arka",
    // Only the app target is macOS-bound; MotionKernel itself builds anywhere (incl. Linux CI).
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MotionKernel", targets: ["MotionKernel"]),
        .executable(name: "Arka", targets: ["Arka"]),
    ],
    targets: [
        // The portable, Apple-framework-free core. Builds & tests on Linux (platform-strategy §2).
        .target(
            name: "MotionKernel",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "MotionKernelTests",
            dependencies: ["MotionKernel"]
        ),
        // The macOS app: SwiftUI shell + AppKit/Metal canvas. NOT built on Linux — CI builds only
        // the MotionKernel target there. The .metal shader is compiled by SwiftPM into Bundle.module.
        .executableTarget(
            name: "Arka",
            dependencies: ["MotionKernel"]
        ),
    ]
)
