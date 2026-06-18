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
        .library(name: "MotionRender", targets: ["MotionRender"]),
        .library(name: "MotionAI", targets: ["MotionAI"]),
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
        // The Metal render layer (RenderTree boundary). macOS-only via #if os(macOS) guards; the
        // Linux CI build never touches it (it builds only the MotionKernel target).
        .target(
            name: "MotionRender",
            dependencies: ["MotionKernel"]
        ),
        .testTarget(
            name: "MotionRenderTests",
            dependencies: ["MotionRender", "MotionKernel"]
        ),
        // The AI generation pipeline (Foundation-only, Linux-clean): request/response DTOs,
        // validate/repair orchestration, prompt assembly, Anthropic client, offline heuristic
        // generator. Shared by the app and the server.
        .target(
            name: "MotionAI",
            dependencies: ["MotionKernel"]
        ),
        .testTarget(
            name: "MotionAITests",
            dependencies: ["MotionAI", "MotionKernel"]
        ),
        // The macOS app: SwiftUI shell + AppKit/Metal canvas.
        .executableTarget(
            name: "Arka",
            dependencies: ["MotionKernel", "MotionRender", "MotionAI"]
        ),
    ]
)
