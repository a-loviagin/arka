# Arka

A macOS-native motion-design tool for UI/product designers and marketing teams: a key-based
timeline (Jitter-style) with a prompt-based AI workflow, exporting to a self-contained `.motion`
format plus GIF/MP4/ProRes/Lottie.

The full design lives in `specs/` (read `specs/README.md` first). Strategy: **pure Swift,
Mac-first** (`specs/platform-strategy.md`), with a framework-free kernel that keeps a future
web/server port a port rather than a rewrite.

## Status

**Phase 2 — first moving pixels (done).** A macOS app target (`Arka`) renders the kernel's
evaluated scene with Metal:

- **RenderTree boundary** — `RenderTreeBuilder` resolves the kernel's `SceneEvaluator` output into
  flat `RenderItem`s (world matrix, opacity, resolved shape style). `simd`/Metal live only here.
- **SDF renderer** — instanced analytic SDF shapes (rect/rounded-rect/ellipse) with scale-aware
  antialiasing, pre-multiplied blending, drawn into a `CAMetalLayer`.
- **App shell** — SwiftUI chrome + AppKit/Metal canvas, a media-clock `PlaybackController`
  (`CADisplayLink`-driven, anchored time — no wall-clock drift), play/scrub/loop transport, and a
  built-in demo comp (springy cards, a morphing pill, a dot on a curved motion path).

Run it: `swift run Arka`.

**Phase 1 — `MotionKernel` (done).** The pure-Swift, Apple-framework-free core that
everything else depends on. This is the "first build step" the specs mandate before any pixel
exists:

- **Schema model** — `MotionDocument` → `Composition` → `Layer` → `Transform`/content, the
  `AnimatableValue`/`Track`/`Keyframe` abstraction, all `Codable` with omitted-defaults.
- **Math** — `Vec2`, OKLab `ColorValue` interpolation, CSS cubic-bezier easing solver, closed-form
  damped spring (deterministic, no simulation).
- **Evaluate stage** — the deterministic `(track, t) → value` core and a scene evaluator that
  composes world transforms and opacity down the parent chain.
- **Command system** — the single write pathway (`AnyCommand`), property-path addressing, and a
  snapshot-based **undo store** with gesture transactions. AI generations are one tagged
  transaction → one ⌘Z reverts a whole generation.
- **Migrations** — semver-gated migration harness (baseline v0.1).
- Multiplayer "do now" foundations baked in: fractional `SortKey` z-order, client-prefixed IDs,
  pure-function parent-cycle check.

41 tests pass, including the undo round-trip fuzz (byte-identical restore) and evaluate-stage
boundary tests. Linux CI enforces the no-Apple-frameworks rule.

## Build

```bash
swift build
swift test
```

## What's next

Per `specs/render-engine.md §8` and the per-doc build orders: the Metal render layer (SDF shapes
→ first moving pixels), then the SwiftUI editor shell, the pattern library + AI pipeline, and
export. None of those touch `MotionKernel`'s framework-free boundary.
