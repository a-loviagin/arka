# Arka

A macOS-native motion-design tool for UI/product designers and marketing teams: a key-based
timeline (Jitter-style) with a prompt-based AI workflow, exporting to a self-contained `.motion`
format plus GIF/MP4/ProRes/Lottie.

The full design lives in `specs/` (read `specs/README.md` first). Strategy: **pure Swift,
Mac-first** (`specs/platform-strategy.md`), with a framework-free kernel that keeps a future
web/server port a port rather than a rewrite.

## Status

**Phase 29 — multiplayer review (in progress).** Playback-level review (multiplayer.md "the killer
collab feature"): a creator shares a board/frame; a viewer plays it on the web and leaves comments
anchored to a timeline moment + a board pin; the creator sees them back on the timeline.
- **Slice 1 (done)** — review model + store (`MotionKernel`): `ReviewComment` (time + optional pin +
  author/text, lenient decode for web clients), `ShareMeta`/`ShareUpload`, and an actor `ShareStore`
  (create/fetch/comment, injectable clock+id for deterministic tests).
- **Slice 2 (done)** — `ArkaServer` endpoints (`POST /share`, `GET /share/:id` + `/lottie` +
  `/comments`, `POST /share/:id/comments`) and a static **web viewer** at `/v/:id` that plays the
  shared **Lottie** with lottie-web (real scrubbable timeline), and lets a viewer comment at the
  current time + drop a board pin. Reuses Phase 25's Lottie export — no renderer port. Verified
  end-to-end via curl.
- **Slice 3 (done)** — the macOS half: **Share ▸ Share Board / Current Frame for Review…** exports
  the scope to Lottie (the whole board is synthesized as one comp of per-frame precomps), uploads it,
  copies the viewer link, and opens the **Review** panel. The panel fetches the viewers' comments;
  clicking one **seeks the playhead** to its time, focuses the shared frame, and drops the comment's
  **pin on the canvas** (mapped back to board space). 246 tests. Phase 29 review loop complete.

**Phase 28 — Tier-3 effects (in progress).**
- **Slice 1 (done)** — **color-adjustment** effect (`colorAdjust`): brightness / contrast /
  saturation / hue, applied as a fullscreen pass on the layer's rasterized result (in linear,
  unpremultiply→adjust→re-premultiply; SVG-style hue matrix), slotting into the same effect pipeline
  as blur/shadow. Neutral params resolve to a no-op. Inspector "+ Color" with scrubbable rows; the AI
  can author it.
- **Slice 2 (done)** — **track mattes** (alpha / luma, + inverted): a layer is masked by the layer
  directly above it (`Layer.trackMatte` + `SetLayerTrackMatte`). The builder folds the matted layer +
  its matte into one `MatteNode`; the renderer rasterizes both target-aligned and multiplies the
  content's coverage by the matte's alpha or luminance (inverted flips it) — the matte layer isn't
  drawn on its own. Inspector "Matte" picker per layer. 240 tests.
- Remaining Tier-3 (own future phases): displacement/noise, expressions/bindings, particles,
  audio-reactive.

**Asset import (done).** Drag image files from Finder/Desktop (or another app) **onto the canvas** —
they land as an editable image layer at the drop point — and **⌘V paste** an image from the clipboard
(PNG, or any TIFF transcoded to PNG) onto the canvas. Both funnel through one `importImage`:
content-addressed asset (identical bytes dedup to one asset), texture registered, fit-scaled image
layer, one ⌘Z. **SVG** drops/pastes import as **editable vector layers**: a Foundation-only
`SVGPathParser` turns each `<path d="…">` (M/L/H/V/C/S/Q/T/Z, absolute + relative; quadratics raised
to cubics) into our cubic-bezier `PathData`, and `SVGImport` pulls each path's fill — one group with a
path shape layer per element, fit-scaled at the drop point, fully editable. `SVGImport` also covers
the basic **primitives** (rect, circle, ellipse, line, polyline, polygon) and per-element
**`transform`** (translate/scale/rotate/matrix/skew); elliptical **arcs** convert to cubics
(endpoint→center, ≤90° pieces). Imported image assets also get a one-line **vision `subject`**
(`ClaudeImageAnalyzer`, cached) so the AI can reason about them by name. 235 tests.

**Phase 27 — AI quality & evals (in progress).** Learning from examples without fine-tuning:
exemplars become *data the model reads* (retrieval-augmented few-shot), the pattern library is the
editable vocabulary, and an eval harness gates every prompt/example change. Because the AI emits
`AnyCommand` lists (the human write path), generated projects are **fully editable by construction**.
- **Slice 1 (done)** — the **eval harness** (`MotionAI.EvalHarness`), built before the feature
  (ai-pipeline.md §8). A scenario is a start document + prompt with layered checks: layer 1
  (validity — runs the real validate/repair pipeline) and layer 2 (structural — `producesAnimation`,
  `minLayers`, `layerAnimated`, `keyframesInRange`, …). Foundation-only, runs offline against the
  deterministic `HeuristicGenerator` baseline in CI; pass any `MotionGenerator` to eval a live model.
- **Slice 2 (done)** — the **example-learning mechanism**: an `ExemplarLibrary` of authored
  `(intent + tags → command-list)` pairs, retrieved per request by keyword/tag overlap and injected
  as **few-shot exemplars** in the system prompt (`AnthropicClient` retrieves top-K and builds
  `SystemPrompt.text(exemplars:)`). This is how the tool learns from examples *without fine-tuning* —
  exemplars are data the model reads, and the command-list output keeps generated projects fully
  editable. New examples are added by authoring an exemplar (or mining accepted generations); the
  keyword retriever can be swapped for embeddings behind the same interface.
- **Slice 3 (done)** — the **reference-clip taste engine**: raw mov/mp4/gif become taste by being
  analyzed into a `VideoMotionAnalysis` (structured in *our* vocabulary — elements → pattern +
  character + timing + stagger + palette), never used as pixels for generation. `TasteSynthesizer`
  turns an analysis into editable commands / a reusable `Exemplar` (so an ingested clip is retrieved
  like any other example), and `TasteProfile` distills a corpus into house-style doctrine (median
  timing, dominant easing, stagger gap, palette) injected into the system prompt. The analyzer
  (`VideoMotionAnalyzer`) is the data source: a Claude-vision pass and/or a deterministic CV motion
  signature (frame-diff onsets + OKLab palette) — both feed the same offline-tested synthesizer.
- **Slice 4 (done)** — the **vision pass** so the model actually *sees* a clip: `ClipFrameSampler`
  (MotionRender) samples evenly-spaced JPEG frames via AVFoundation; `ClaudeVideoAnalyzer` (MotionAI)
  sends them to Claude as image blocks and gets back a structured `VideoMotionAnalysis` through a
  forced tool. Vision reads on-screen text natively, so this subsumes OCR — no separate engine. The
  analysis flows straight into the already-tested `TasteSynthesizer` / `TasteProfile`.
- **Slice 5 (done)** — the deterministic **CV motion signature** (no model): `MotionSignature`
  (kernel) = a normalized inter-frame activity curve + onset times + OKLab palette, with
  `distance(to:)`. `MotionSignatureExtractor` (MotionRender) builds it from frames, and also renders a
  candidate document to frames and signs it — the **render-compare verifier** that scores a
  synthesized reconstruction against a reference clip ("find the command list whose render best
  matches the clip"), and grounds the vision analyzer's labels in real timing.
- **Slice 6 (done)** — **canvas-snapshot grounding** (§2) and **asset analysis** (§3). In edit mode
  the app renders a downscaled JPEG of the comp at the playhead and sends it as an image block, so
  the model grounds spatial language ("under the logo") in pixels; `GenerationRequest` carries the
  `snapshot` + per-asset `AssetAnalysis` (deterministic OKLab palette + dimensions via `ImagePalette`,
  with a `subject` slot for a vision follow-up), surfaced in the user message. The vocabulary reaches
  the live `AnthropicClient` (image block + ASSETS text) and the server path alike.
- **Slice 7 (done)** — the **"Teach Style from Clips" ingestion UI** (AI ▸ Teach Style…). A clip is
  sampled + vision-analyzed once into a `VideoMotionAnalysis`, then stored in a `TasteStore` —
  **global** (all projects), **per-project** (this document, keyed by id), or a **one-shot** reference
  for the next prompt only. At generation time the active library = built-in + global + project
  exemplars (retrieved few-shot) and the aggregate profile (doctrine) are injected into the live
  client. This is curation/conditioning, **not training** — stores hold only small JSON analyses, and
  removing a clip removes its influence. Persisted app-side; needs a key to analyze. 218 tests.

**Phase 26 — export UI + WebP + GIF craft (done).** A preset-first **export sheet** (export-and-
format.md §3, File ▸ Export… / ⌘E): segmented format picker (MP4 / ProRes / GIF / WebP / PNG-sequence
— WebP offered only where the system encoder exists), the few settings that matter per format (scale
25–200% with a live px readout, fps with a per-format cap, transparent-background toggle for
alpha-capable formats), a live size estimate, and a frame-count/duration readout. One off-main
render path keyed by format honors scale + fps. New **animated WebP** exporter (`WebPExporter`,
gated by `isAvailable`) — the modern GIF replacement. **GIF craft**: a single stable 256-colour
palette built across all frames by **median-cut in OKLab** (perceptually-placed buckets, no per-frame
flicker) applied through a 15-bit nearest-colour LUT with low-amplitude **ordered (Bayer)
dithering**. 183 tests.

**Phase 25 — Lottie export (done; core scope).** A document→document bodymovin translator
(export-and-format.md §4), not a render path — Foundation-only in `MotionKernel`, so the server
exports too. Maps composition metadata, **shape layers** (rect/ellipse with fill/stroke/corner-
radius), **vector paths + trim** (our in/out tangents are Lottie's `i`/`o`; trim → `tm`), **null/
group** layers, full **animated transforms** with cubic-bezier easing, and **layer parenting**.
**Springs** have no Lottie equivalent, so a spring track is **sampled to dense keyframes** at the
comp fps ("visually exact, file grows"). A **compatibility lint** reports per layer exactly what
won't survive — animated shape geometry / gradients / effects, and video (placed as positioned nulls
so the file is always valid, never silently wrong). Also translates **precomp** layers (recursive,
cycle-guarded, into the Lottie `assets` array), **image** layers (embedded as a self-contained
base64 data URI when the bytes are available), and **text** layers (Lottie text document + `fonts`
list). File ▸ Export Lottie (JSON)… surfaces the lint. 179 tests.

**Phase 24 — Tier-2 animations: stroke, trim, gradient (done).** The "wow" set from
properties-and-commands.md §1 Tier 2.
- **Path stroke** — vector paths stroke as well as fill: `PathStroker` ribbons each subpath at
  `strokeWidth` (clamped miter joins). A path is one layer (ordered fill+stroke sub-meshes) so
  effects/blend apply to the unit.
- **Trim paths** — `trimStart`/`trimEnd`/`trimOffset` slice the stroke by arc length for line-drawing
  animations; `trimOffset` wraps the seam on closed paths. Animatable, addressable, inspector rows.
- **Gradient fills** — `GradientFill` (linear/radial, animatable stops + endpoints) on shapes and
  paths, baked into a LUT and sampled in the shape/path fragment (flat draws bind a dummy LUT, so
  the batched path is untouched). Inspector: add/remove, linear↔radial, per-stop color wells. 171 tests.

**Phase 23 — multi-frame canvas (done).** A Figma-style board: a document holds many
**frames**, each frame *is* a `Composition` (its own size, fps, duration, timeline, and layers).
- **Slice 1 (done)** — `AddComposition` / `RemoveComposition` kernel commands; an active-frame model
  (the canvas, timeline, and inspector follow `activeCompId`); the layers panel is **grouped by
  frame** (section per frame, click to focus, "+ Frame", delete); **export targets the active
  frame** so each exports separately.
- **Slice 2 (done)** — frames laid out on an infinite, pan/zoom **board** (every `Composition` gets a
  `boardPosition`), rendered together by reusing the precomp-composite path (each frame is a placed
  `Precomp` with its own background). One global playhead drives every frame's timeline. Pinch /
  zoom-control to zoom, drag the bare workspace to pan, click a frame to focus it; frame outlines +
  name labels overlay the board. `Viewport` generalized to explicit pan/zoom.
- **Slice 3 (done)** — direct manipulation on the board: **drag a frame's title** to reposition it,
  drag the focused frame's **corner handles** to resize (`SetCompositionSetting.boardPosition`; move
  + resize commit as one ⌘Z). **Rename** a frame by double-clicking its board label or its layers-
  panel header (inline field, Return commits / Esc cancels). 161 tests.

**Phase 22 — type-aware inspector (done).** A Figma-style "operate the selected layer" panel keyed to
the layer type, every field reading the resolved value at the playhead and writing one command
(auto-keyframing, with a keyframe diamond):
- **Arrange** — align to comp (6 ways), flip H/V, bring-to-front / send-to-back.
- **Transform** — position, rotation, scale, opacity, **blend mode** (normal/multiply/screen/add/
  lighten — real backdrop-reading composites in linear space).
- **Shape** — W/H size, fill & stroke color wells, stroke width, corner radius.
- **Text** — editable string / font / alignment, size, tracking, **line height** (multi-line),
  fill.
- **Effects** — add/tweak/remove blur, shadow, and **background blur** (frosted glass: blurs the
  composited backdrop within the layer via an encoder-segmented snapshot+blur+masked composite).
- Layer **rename**, image **fit mode**.
New kernel commands: `SetLayerName`, `SetContent`, `SetLayerBlendMode`; generic auto-keyframing
property bindings; `Layer.blendMode` + `TextContent.lineHeight`. 137 tests.

**Phase 21 — correctness & the product promise (done).** Linear-space color compositing
(sRGB-format render targets, so blends/blur/crossfades happen in linear — no dark AA fringing;
white@50% over black is now the correct sRGB 188, not gamma 128). The **preview/export equivalence
test** pins that the offscreen reference and the real export target (a `CVPixelBuffer`-backed
texture) produce identical pixels. **Video now composites into exports** (MP4/ProRes/GIF/PNG), and
**autosave + crash recovery** debounce-writes the live doc to a recovery `.motion` package, reopened
on an unclean relaunch. 129 tests.

**Phase 20 — editor authoring (done).** You can build documents by hand, not just from the demo or
the AI: rectangle/ellipse/text **creation tools** (click-to-place or drag-to-size), **⌘D duplicate**,
**⌘G group / ⇧⌘G ungroup**, context-aware **delete**. Text became a fully canvas-editable layer (a
CoreText measurer gives it an intrinsic size, so it hit-tests/gizmos like any other layer). Added an
`ArkaTests` target — the app layer's first unit coverage.

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
