# CLAUDE.md — Arka (motion-design tool)

## What this is
macOS-native motion-design app. Pure Swift, Mac-first. Full spec set in `specs/` — read
`specs/README.md` first; it orders the other nine docs. The specs are the contract; code targets
them, not the reverse.

## Architecture (current)
- **`MotionKernel`** (SwiftPM package, `Sources/MotionKernel/`) — the deterministic core. The one
  hard rule (CI-enforced): **no Apple-only imports** (AppKit, Metal, MetalKit, CoreText,
  CoreGraphics, AVFoundation, UIKit, Combine, `simd`). Foundation only. It must build and test on
  Linux. CoreText/Metal belong in the future app target, behind the RenderTree boundary.
  - `Math/` — `Vec2`, `ColorValue` (OKLab lerp), `Affine2D`, `Easing` (cubic-bezier), `Spring`
    (closed-form), `Interpolatable`/`Componentwise`.
  - `Schema/` — the document tree, all `Codable` with omitted-defaults; `AnimatableValue` is the
    one shape used everywhere.
  - `Evaluate/` — pure `(track, t) → value`; `SceneEvaluator` composes the parent chain. **Keep
    this pure and deterministic** — golden-frame / preview-export equivalence depends on it.
  - `Commands/` — the **only write pathway**. `AnyCommand` (Codable wire format = AI output =
    future multiplayer protocol). `CommandStore` does snapshot undo + gesture transactions.
  - `Migration/` — semver-gated, append-only migration steps.

## Conventions
- Time is **seconds** (Double), never frames. `fps` is metadata.
- Every entity has a stable string `EntityID` (client-prefixed). Reference by ID, never index.
- z-order is a fractional `SortKey`, not array position.
- New write = a `Command`. Never mutate the document struct directly outside command `apply`.
- Color interpolation is OKLab; working/keyframe values stored sRGB-encoded.

## Commands
```bash
swift build
swift test          # 41 tests; undo round-trip fuzz is the workhorse
```

## Don't
- Don't add an Apple framework import to `MotionKernel` (CI fails; breaks Linux/server/Wasm).
- Don't add a second write path around `CommandStore`.
- Don't make the evaluate stage stateful/cached in a way that changes results.
