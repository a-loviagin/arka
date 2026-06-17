# Arka

A macOS-native motion-design tool for UI/product designers and marketing teams: a key-based
timeline (Jitter-style) with a prompt-based AI workflow, exporting to a self-contained `.motion`
format plus GIF/MP4/ProRes/Lottie.

The full design lives in `specs/` (read `specs/README.md` first). Strategy: **pure Swift,
Mac-first** (`specs/platform-strategy.md`), with a framework-free kernel that keeps a future
web/server port a port rather than a rewrite.

## Status

**Phase 9 — `.motion` save/open (done).** The self-contained package format (export-and-format.md
§5): `MotionPackage` reads/writes a bundle directory (`document.json` + content-addressed `assets/`
+ `thumbnail.png`), with content-addressing (`ContentHash`), migration-on-open (`SchemaMigrator`),
and asset-reference validation — all Foundation-only in the kernel (Linux-clean). Thumbnails render
the frame at 25% duration. File ▸ Open / Save Package… in the app swap the live document and reload
its assets. Verified end-to-end: a package with a real image asset is saved, reopened (migrated),
and rendered back. 65 tests.

**Phase 8 — MP4 export (done).** First shareable output (export-and-format.md §1-2). A
`VideoExporter` steps each frame at exact rational time (no clock — render-engine.md §5), renders
into `CVPixelBuffer`-backed Metal textures (zero-copy via `CVMetalTextureCache`), and feeds an
`AVAssetWriter` (H.264/HEVC, even dims, bpp-preset bitrate, BT.709 tag). Verified end-to-end: a
clip is exported and read back — correct size/duration, and a decoded frame's pixels match the
render (effects survive encode/decode). File ▸ Export Movie… in the app. 56 tests.

**Phase 7 — group-opacity isolation (done).** Completes the compositing model (render-engine.md
§3). The builder descends the parent tree and isolates faded/effected groups: their children render
into one intermediate (opacity divided out so the group fades once at composite), so a group
opacity < 1 fades overlapping children *together* rather than each separately. Precomp and group
share one `ResolvedNode` path in the renderer. Verified: an isolated faded group's overlap equals a
single child, while non-isolated translucent children stack brighter. 55 tests. The renderer now
covers direct-draw, effects, precomp, and group isolation — all of §3.

**Phase 6 — precomps / nesting (done).** The RenderTree is now a node tree (leaf | precomp); the
builder recurses into referenced compositions (cycle-guarded) and the renderer rasterizes each
nested comp into a pooled texture, then composites it through the precomp layer's transform,
opacity, and effects — the "After Effects superpower". Nested comps reuse the shared frame pool and
recurse arbitrarily. Verified structurally (transform + opacity) and visually (scaled/rotated
nested comps with a drop shadow). 54 tests.

**Phase 5 — intermediates & effects (done).** The multi-pass compositing machinery
(render-engine.md §3): a size-bucketed `IntermediatePool`, layers with effects rendered into
intermediate textures, then composited back in z-order. **Gaussian blur** (separable two-pass,
blurred in premultiplied space) and **drop shadow** (blurred alpha → tint → offset behind the
sharp content). Verified structurally (blur spreads coverage past sharp bounds; shadow casts
offset tinted pixels) and visually. The demo's cards now cast soft shadows. 52 tests.

**Phase 4 — image layers (done).** A `TextureCache` (ImageIO/CGImage → premultiplied rgba8,
keyed by `assetId`) plus an image fragment that reuses the textured-quad path. The RenderTree
builder resolves image layers through a `TextureProvider`. Shapes, text, and images now composite
together in z-order (verified by an image-color render test; 50 tests total). The demo scales in a
procedural gradient image.

**Phase 3 — renderer conformance (done).** Render code is now its own `MotionRender` library
target (macOS-only, behind the RenderTree boundary), with an offscreen render-to-texture + pixel
readback path (`PixelImage`, ImageIO PNG). The conformance suite (render-engine.md §7) does
**structural pixel assertions** that self-validate correctness — background = bg color, a filled
rect's center = its fill, 50%-opacity composites to half-gray, an SDF ellipse excludes its
bounding-box corners, an animated shape moves between sampled times, and text lights up real glyph
coverage — plus a golden-PNG pin with perceptual tolerance. 49 tests total.

**Phase 2 — first moving pixels (done).** A macOS app target (`Arka`) renders the kernel's
evaluated scene with Metal (now via the `MotionRender` target):

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
