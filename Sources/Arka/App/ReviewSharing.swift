#if os(macOS)
import Foundation
import MotionKernel
import MotionRender
import MotionAI

/// Share for playback-level review (multiplayer.md): export the board or active frame to Lottie,
/// upload it to ArkaServer, and get a viewer link. Then fetch the comments viewers leave and let the
/// creator jump to each on the timeline. Reuses the Lottie export (Phase 25) — the viewer plays it
/// with lottie-web, so there's no second renderer.
extension DocumentModel {
    /// Server base; override with `ARKA_SERVER_URL` (default local dev server).
    var reviewServerBase: String {
        ProcessInfo.processInfo.environment["ARKA_SERVER_URL"] ?? "http://127.0.0.1:8080"
    }

    @MainActor
    func shareForReview(board: Bool) async {
        guard let (data, meta, frameID) = lottieToShare(board: board) else {
            shareStatus = "Nothing to share."; return
        }
        shareStatus = "Sharing…"
        do {
            let upload = ShareUpload(meta: meta, lottieJSON: String(decoding: data, as: UTF8.self))
            var req = URLRequest(url: URL(string: "\(reviewServerBase)/share")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONEncoder().encode(upload)
            let (respData, _) = try await URLSession.shared.data(for: req)
            struct ShareResponse: Decodable { let id: String; let viewer: String }
            let resp = try JSONDecoder().decode(ShareResponse.self, from: respData)
            lastShareID = resp.id
            lastShareURL = "\(reviewServerBase)\(resp.viewer)"
            sharedFrameID = frameID
            reviewComments = []
            shareStatus = "Shared — link copied."
        } catch {
            shareStatus = "Share failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func fetchReviewComments() async {
        guard let id = lastShareID else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "\(reviewServerBase)/share/\(id)/comments")!)
            reviewComments = try JSONDecoder().decode([ReviewComment].self, from: data)
        } catch {
            shareStatus = "Couldn’t load comments: \(error.localizedDescription)"
        }
    }

    /// Seek the playhead to a comment and surface its pin on the canvas (mapped back to board space).
    func goToComment(_ c: ReviewComment) {
        playback.seek(to: c.time)
        if let frameID = sharedFrameID, frameID != activeCompId { setActiveFrame(frameID) }
        if let pin = c.pin {
            // Pins are in the shared comp's coords; map back to board space for the canvas overlay.
            let origin = sharedFrameID.flatMap { document.composition($0)?.boardPosition } ?? boardBounds().origin
            activeReviewPin = pin + origin
        } else {
            activeReviewPin = nil
        }
    }

    // MARK: Lottie for the chosen scope

    private func lottieToShare(board: Bool) -> (Data, ShareMeta, EntityID?)? {
        if board {
            return boardLottie()
        }
        guard let comp = mainComp,
              let data = try? LottieExporter.export(document, compId: comp.id, assetData: assetBytes).json
        else { return nil }
        let meta = ShareMeta(name: comp.name, width: comp.size.x, height: comp.size.y,
                             duration: comp.duration, fps: comp.fps, scope: comp.name)
        return (data, meta, comp.id)
    }

    /// Synthesize a board composition (one precomp layer per frame at its board position) and export
    /// *that* to Lottie — so the whole board plays as a single animation.
    private func boardLottie() -> (Data, ShareMeta, EntityID?)? {
        guard !frames.isEmpty else { return nil }
        let bounds = boardBounds()
        let fps = mainComp?.fps ?? 60
        let duration = frames.map(\.duration).max() ?? 5
        var layers: [Layer] = []
        var key: SortKey? = nil
        for f in frames {
            key = SortKey.between(key, nil)
            let pos = f.boardPosition - bounds.origin
            layers.append(Layer(id: EntityID("share_\(f.id)"), name: f.name, sortKey: key!,
                                content: .precomp(PrecompContent(compositionId: f.id)),
                                transform: Transform(anchor: .static(.zero), position: .static(pos))))
        }
        let boardComp = Composition(id: "share_board", name: "Board", size: bounds.size,
                                    fps: fps, duration: duration, layers: layers)
        var doc = document
        doc.compositions.append(boardComp)
        guard let data = try? LottieExporter.export(doc, compId: "share_board", assetData: assetBytes).json
        else { return nil }
        let meta = ShareMeta(name: "Board", width: bounds.size.x, height: bounds.size.y,
                             duration: duration, fps: fps, scope: "board")
        return (data, meta, nil)
    }
}
#endif
