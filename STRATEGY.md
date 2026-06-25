# Arka — Competitive Strategy

*Snapshot: June 2026. Based on two adversarially-verified research passes (Figma; Rive / LottieFiles /
Jitter). **Time-sensitive** — pricing and AI features in this space change monthly. Items that
couldn't be first-party-verified are flagged.*

## TL;DR

The market shifted decisively **this week**: at **Config 2026 (open beta June 24, 2026)** Figma
launched **Figma Motion** — a real keyframe timeline with springs/easing and an **AI agent that
generates keyframes from prompts**. A timeline, springs, and prompt-to-motion are now **table
stakes**, not differentiators (Figma *and* Jitter both ship prompt-to-motion).

Arka's durable, hard-to-copy wedges narrow to three:
1. **Native render/export fidelity** — Metal, linear-color/OKLab, **ProRes 4444 + alpha**, OKLab-GIF,
   WebP, PNG-seq.
2. **Lottie + production handoff** — shipped today; Figma's Lottie is "planned," not launched.
3. **The taste engine** — learns a brand's motion style from **example project files _and_ reference
   videos** (vision analysis), emitting **editable command lists**. No rival surfaced an equivalent.

**Invest hardest in #3.** It is the least copyable. Treat #1/#2 as a moat to exploit *while it
lasts* — Figma has stated Lottie/more formats are coming.

## Positioning

> **Design in Figma, finish motion in Arka.**

Do **not** fight Figma for "basic motion in the design file" — you lose the distribution/convenience
war. Win the segment a *motion feature inside a design tool* won't prioritize: **dedicated motion
craft + production handoff + an AI taste engine**. Be the motion layer **on top of** the ecosystem
(import designs, output Lottie/ProRes/video, learn the brand's style, review on the web) rather than a
competitor for the canvas.

## Competitive landscape

| Player | What it is | AI motion | Export / runtime | Relation to Arka |
|---|---|---|---|---|
| **Figma Motion** | Keyframe timeline inside Figma (open beta 6/24/26) | Agent → keyframes "grounded in components/tokens" | MP4/GIF/WEBM/Animated SVG + CSS/JSON/React/motion.dev. **No Lottie/alpha at launch** | **Biggest structural threat** (distribution); don't fight head-on |
| **Jitter** | Browser, action/template motion for marketing | **"Animate with AI"** prompt-to-effect (shipped 5/13/26), credit-gated | MP4/MOV/WebM/GIF/**Lottie**, 4K/120fps, **ProRes 4444 alpha** | **Most direct competitor** — benchmark against it |
| **LottieFiles** | Web Lottie tool + hosting/handoff ecosystem | Motion Copilot, Prompt-to-Vector, Prompt-to-State-Machine | Lottie JSON/dotLottie, GIF/MP4/MOV/WebM, **CDN hosting** | **Best interop/partner** — distribution, not rival |
| **Rive** | Interactive state-machine engine + runtimes | (MCP/AI-tool connectors) | `.riv` via MIT runtimes on ~14 platforms | **Orthogonal** — different category; interop/non-overlap |

### Threat-vs-wedge, per rival
- **Figma** — Threat: AI motion where every designer already is. Wedge: Lottie *today*, ProRes/alpha,
  native fidelity, learn-from-video taste, not bound to a design seat.
- **Jitter** — Threat: directly overlaps Arka's output *and* AI wedge (transparent/4K video, Lottie,
  prompt-to-motion all exist). Wedge: native Metal vs. browser, OKLab-GIF/WebP/PNG-seq breadth,
  **editable command-list** output, taste-from-project-files-and-video (Jitter's is prompt-to-effect,
  browser-bound, credit-metered).
- **LottieFiles** — Not head-on; Arka already exports Lottie, so their CDN/hosting/handoff is a
  **distribution channel**. Partner: Arka authors broadcast-grade + Lottie, they distribute/embed.
- **Rive** — Live interactive runtime content (`.riv`), not render-and-export. No deliverable overlap.

## Roadmap implications

1. **Double down on the taste engine** (the moat). Reference-video → brand motion style is the one
   capability no competitor showed. Priorities: ingestion UX, retrieval quality, the render-compare
   verifier, and eval coverage so taste is measurable, not vibes.
2. **Protect the export/fidelity lead while it lasts.** Keep Lottie fidelity ahead of Figma's
   forthcoming exporter; keep ProRes-4444-alpha / OKLab-GIF as the "ships to broadcast" story.
3. **Lean into interop, not lock-in.** Strengthen Figma/SVG import and **LottieFiles handoff**
   (verify round-trip fidelity into their hosting/runtimes).
4. **Make the AI difference legible.** "Editable command list vs. editable keyframes" is currently an
   *unproven* advantage — demonstrate it (e.g. re-prompt/refine/restyle flows that Figma's
   token-grounded keyframes can't match), or it won't register with users.

## Top risks

1. **Figma's export gaps are explicitly temporary.** Lottie is "planned"; if Lottie + alpha land in
   months, the format wedge narrows hard → lean on the taste engine, not formats.
2. **AI differentiation unproven.** Is editable-command-list output perceptibly better than Figma's
   token-grounded keyframes? Unanswered by research; it's the make-or-break question for the AI wedge.
3. **Distribution asymmetry** (Figma) is structural and not closeable head-on → "complement, not
   compete."

## What's NOT verified (handle with care)
- **Exact 2026 dollar prices** for Jitter and LottieFiles (Jitter's page renders amounts as "--";
  LottieFiles via third parties). Tier *structures* and *AI-feature existence* are confirmed; **AI
  output quality is unbenchmarked** for every rival.
- LottieFiles facts lean on search-indexed text + third-party reviews (their pages block automated
  fetch); export-format/cap details are slightly softer.
- "Most direct competitor / best partner" rankings are analyst inference from verified product facts.
- No rival showed Arka's **taste-from-video**, **multi-frame board**, or **web review (timeline
  comments + board pins)** — but absence-of-evidence was not exhaustively searched.

## Key sources
Figma: [Introducing Figma Motion](https://www.figma.com/blog/introducing-figma-motion/),
[Config 2026 what's new](https://help.figma.com/hc/en-us/articles/39582753756695-What-s-new-from-Config-2026),
[Explore Figma Motion](https://help.figma.com/hc/en-us/articles/41274629073303-Explore-Figma-Motion),
[pricing](https://www.figma.com/pricing/).
Rive: [rive.app](https://rive.app/), [pricing](https://rive.app/pricing), [runtimes](https://rive.app/runtimes).
LottieFiles: [Lottie Creator](https://lottiefiles.com/lottie-creator), [AI](https://lottiefiles.com/ai).
Jitter: [product](https://jitter.video/product/),
[Animate with AI changelog](https://jitter.video/changelog/2026-05-13-animate-with-ai/),
[Lottie](https://jitter.video/lottie-animations/), [pricing](https://jitter.video/pricing/).
