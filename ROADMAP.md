# Arka — Strategy Roadmap

*Derived from [STRATEGY.md](STRATEGY.md) (June 2026). Premise: after Figma Motion (Config 2026), a
timeline + springs + prompt-to-motion are **commodity**. Every phase below must be something a motion
*feature inside a design tool* won't do. Ordered by defensibility — moat first, time-boxed advantage
next, funnel last.*

**North star:** *Figma is where you design; Arka is where motion gets brand-smart, production-grade,
and shipped.*

---

## Phase S1 — The Taste Engine as the product *(the moat)*
**Goal:** "Teach Arka your brand's motion from examples + reference clips → get on-brand, fully
editable projects." The headline feature, not a setting.

**Figma contrast:** Figma grounds AI keyframes in *one file's* components/tokens. Arka learns a
**brand's motion language across many examples and reference videos** and applies it — only possible
because our AI emits editable command lists and we ingest video. Figma has neither.

Built ✅
- Reference-clip taste engine: vision analyzer, `VideoMotionAnalysis`, `TasteSynthesizer`,
  `TasteProfile`, `TasteStore`, "Teach Style" ingestion UI.
- CV `MotionSignature` + render-compare extractor (the verifier).
- Few-shot exemplar retrieval + eval harness.

To build ◻︎
- **Closed-loop generation** — generate → render → signature-compare vs the brand's references →
  pick best / auto-refine. *(S1.1: `TasteLoop` core ✅ — generator/renderer-agnostic, scored
  candidates + feedback refine, unit-tested. Next: wire the real Metal `CandidateScorer` in the app.)*
- Verify the **live vision ingestion** path end-to-end; polish the Style Library UX.
- **Embedding retrieval** behind the existing interface (replace keyword scoring).
- **Taste-adherence evals** in CI; a visible "Style: <brand>" indicator on generations.

---

## Phase S2 — Production handoff *(the moat while it lasts)*
**Goal:** ship-to-product **and** broadcast **and** code — press the export lead before Figma closes it.

**Figma contrast:** Figma deferred Lottie ("planned") and has no alpha/ProRes; it's MP4/GIF/WEBM +
code only. Arka ships Lottie + ProRes-4444-alpha today.

Built ✅
- Lottie export; ProRes-4444-alpha, OKLab-GIF, WebP, PNG-seq, MP4; export sheet.

To build ◻︎
- **Lottie fidelity hardening + LottieFiles round-trip** (validate the interop-partner thesis).
- **Code export** (CSS / JS / motion.dev, maybe SwiftUI) to neutralize Figma's handoff edge.
- Keep ProRes/alpha/OKLab as the "ships to broadcast" story.

---

## Phase S3 — Interop: "design in Figma, finish in Arka" *(turn their reach into our funnel)*
**Goal:** start where designers already are; bring a Figma frame in, animate it, hand off.

**Figma contrast:** complement the canvas instead of competing for it.

Built ✅
- SVG import (paths, primitives, transforms); raster import.

To build ◻︎
- **Figma import** (frames/components → Arka document) via REST/plugin.
- The funnel: import → taste-engine animate → Lottie/video/code handoff.

---

## Phase S4 — Motion review without a Figma seat *(polish; already seeded)*
**Goal:** stakeholder review on the web, motion-specific, no seat required.

**Figma contrast:** timeline-anchored comments + board pins any viewer opens in a browser.

Built ✅
- Web playback review (lottie-web), share board/frame, timeline comments + board pins, creator panel.

To build ◻︎
- Persistence for the share store; resolve/reply; viewer identity; share-flow polish.

---

## Sequencing
1. **S1** — only *uncopyable* wedge, most parts built → highest leverage. **Start here.**
2. **S2** — time-boxed; value erodes when Figma ships Lottie/alpha → bank it now.
3. **S3** — unlocks the funnel once there's something worth finishing-in-Arka.
4. **S4** — lowest urgency; already functional, partly overlaps Figma's strength.
