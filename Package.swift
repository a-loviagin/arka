// swift-tools-version: 6.0
import PackageDescription

// MotionKernel is the pure-Swift, Apple-framework-free core of the motion-design app.
// HARD RULE (platform-strategy.md §2): no imports of AppKit, Metal, CoreText,
// AVFoundation, CoreGraphics — nothing Apple-only. It must build and test on Linux.
// CoreText/Metal live in the app target behind the RenderTree boundary.
let package = Package(
    name: "MotionKernel",
    products: [
        .library(name: "MotionKernel", targets: ["MotionKernel"]),
    ],
    targets: [
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
    ]
)
