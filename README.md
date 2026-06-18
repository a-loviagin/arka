# Arka

A macOS-native motion-design tool for UI/product designers and marketing teams: a key-based
timeline (Jitter-style) with a prompt-based AI workflow, exporting to a self-contained `.motion`
format plus GIF/MP4/ProRes/Lottie.

The full design lives in `specs/` (read `specs/README.md` first). Strategy: **pure Swift,
Mac-first** (`specs/platform-strategy.md`), with a framework-free kernel that keeps a future
web/server port a port rather than a rewrite.

## Status

**Phase 19 — vector paths + video (done).** The object set now covers the last two render gaps.
**Vector-path shapes**: a kernel `PathData` (subpaths of cubic-bezier vertices, optional tangent
handles) on `ShapeContent`; the renderer flattens curves and ear-clips each subpath into a fill
triangle list through a new path pipeline (fill-only for v1; stroke is a follow-up), so custom
outlines blur/shadow like any layer and the AI can author them. **Video**: a frame-accurate
`VideoFrameProvider` (AVFoundation `AVAssetImageGenerator`, zero tolerance → deterministic, honoring
trim/speed) decodes a frame at the comp time and renders it through the image quad path; wired into
the live editor canvas. Verified by tessellation unit tests + a Metal triangle-fill test, and an
export→decode→render video round-trip. 118 tests.

**Phase 18 — AI pipeline + backend service (done).** The whole prompt-to-motion scope
(ai-pipeline.md §1–7). A new Foundation-only, Linux-clean **`MotionAI`** library: request/response
DTOs, a **validate/repair `GenerationPipeline`** (scratch-applies each command against the document,
lints for actual animation, feeds machine-readable errors back to the model, max 2 retries), an
offline **`HeuristicGenerator`** (keyword → pattern/character → `ApplyPattern`/`Stagger` macro, so
the feature works with no key), a live **`AnthropicClient`** (raw `URLSession` Messages API, forces a
single `emit_motion` tool call so output decodes through the same `AnyCommand` Codable), and a shared
**`GenerationService`**. In the app, a **⌘K prompt panel** generates and applies an edit as one
`.ai` transaction (one ⌘Z); uses Claude when `ANTHROPIC_API_KEY` is set, else the heuristic. A new
**`ArkaServer`** (Hummingbird) exposes `POST /generate` running the *same* kernel + pipeline, so the
`.motion` contract is one codebase client and server. 106 tests.

**Phase 17 — more export formats (done).** ProRes 4444 with alpha (transparent-background MOV),
animated GIF (ImageIO, fps≤50, centisecond delays, looping), and PNG image sequences (numbered,
optional alpha) — all reusing the offscreen render path; File menu items for each. Verified by
exporting and reading each back (dimensions / frame count / pixels). 89 tests.

**Phase 16 — motion pattern library + presets (done).** ai-pipeline.md §9 step 1 (no AI yet): a
kernel `PatternLibrary` of ~15 hand-tuned, parametric patterns (fade/pop/scale-reveal, slide
in/out ×4, pulse/bounce/shake) across four `MotionCharacter`s (gentle/snappy/bouncy/dramatic) that
**expand deterministically into plain keyframe commands** — reviewed Swift + tuned values, not
stochastic tokens. A presets panel applies them to the selected layer(s) at the playhead in one ⌘Z;
multiple layers stagger. This is the foundation the eventual AI macro vocabulary plugs into. 86 tests.

**Phase 15 — canvas/inspector refinements (done).** **Snapping + alignment guides** on moves (to
comp + other-layer edges/centers, red guides, ⌘ disables) via a pure kernel `CanvasSnapper`; an
**anchor tool** (drag the anchor while the layer stays put); **non-uniform scale** (per-axis corner
projection, ⇧ for uniform); **scrubbable number fields** (X/Y/rotation/scale, one transaction per
drag); and **multi-select** (shift-click, marquee, layer-list ⌘/⇧-click) with multi-layer move. 81
tests.

**Phase 14 — timeline polish (done).** Keyframes are now fully editable: click a diamond to
**select** it (Edit ▸ Delete Keyframe / ⌫ removes it), and click a **segment** between two keys to
open an **easing popover** (Linear / Ease In-Out / Snappy / Bouncy) — backed by a new kernel
`SetKeyframeInterp` command so presets can switch between linear, bezier (with handles), and spring.
77 tests.

**Phase 13 — transform gizmos (done).** Canvas direct-manipulation is now complete: **corner
handles scale** (uniform, about the layer's anchor) and a **rotate handle** above the box rotates,
alongside the existing move. A press routes by what it lands on (handle → scale/rotate, body →
move, empty → deselect); each gesture is one transaction (one ⌘Z) and auto-keyframes when the
track is already animated. 75 tests.

**Phase 12 — editor depth (done).** A **layer list** (select, drag-reorder → `ReorderLayer` with a
fractional `SortKey`, visibility toggle via new `SetLayerVisible`/`SetLayerLocked` commands) and
**keyframe authoring** — inspector diamond toggles add/remove a keyframe at the playhead for
position & opacity (capturing the resolved value), so you can build animation from a static layer,
not just edit existing keys. Everything still flows through the one `CommandStore`. 75 tests.

**Phase 11 — timeline dope-sheet (done).** The other half of a keyframe tool (editor-ui.md §3): a
scrubbable ruler/playhead, a row per layer with sub-rows for each animated property (kernel
`TimelineDigest`), and keyframe diamonds you can drag to retime — emitting `MoveKeyframes` in one
transaction (one ⌘Z step), frame-snapped unless ⌘ is held. Row taps select the layer, synced with
the canvas. 73 tests.

**Phase 10 — editor v0.1 (done).** The `CommandStore` (commands + snapshot undo) now drives the
UI (editor-ui.md §1-2). `DocumentModel` owns the store; the document is an observable mirror
refreshed on every command. On the canvas you can **click to select** (CPU hit-test against the
evaluated scene — kernel `HitTester`) and **drag to move** (one transaction → `SetProperty`, or
`SetKeyframe` at the playhead if the track is animated). A SwiftUI overlay draws the selection box
+ handles; an inspector shows the selected layer with a live opacity slider that writes through
commands. ⌘Z / ⇧⌘Z undo/redo, ⌘O/⌘S/⌘E for open/save/export. Pure pieces (hit-test, viewport,
affine inverse) are kernel-tested. 71 tests.

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
swift run Arka          # the macOS editor (⌘K for the AI prompt)
swift run ArkaServer    # the backend; GET /health, POST /generate on :8080 (PORT to override)
```

The AI features use Claude when `ANTHROPIC_API_KEY` is set in the environment, and fall back to the
offline heuristic generator otherwise — both the app and the server.

## What's next

The core pipeline (kernel → render → editor → export → AI) is in place end to end. Open directions:
richer command vocabulary for the AI (text/asset edits, multi-step plans), few-shot exemplars and an
eval harness for generations, a thin client that calls `ArkaServer` instead of the in-process
generator, and Lottie export. None of those touch `MotionKernel`'s framework-free boundary.
