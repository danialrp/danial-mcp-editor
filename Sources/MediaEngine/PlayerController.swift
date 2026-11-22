import AVFoundation
import EditorCore
import EditorKit
import Foundation

/// The one player of the open project. It follows the project: after every
/// change the composition is rebuilt and swapped in at the same playhead, so
/// what plays is always the current edit. The app shows its picture; agents
/// drive it through the `player` tools.
@MainActor
public final class PlayerController {
    public let player = AVPlayer()
    public private(set) var built: BuiltComposition?
    public private(set) var revision = -1
    public private(set) var lastError: String?
    /// Called on the main actor after each rebuild.
    public var onRebuild: (() -> Void)?

    /// Whether the display showing the picture has HDR; nil without a window.
    /// The app keeps it current (see `refreshPreviewRange`).
    public private(set) var displayHDR: Bool?
    /// Whether the timeline being played shows HDR footage.
    private var hdrFootage = false
    /// The preview mode the last rebuild was asked for, whether it worked or not.
    private var builtMode: MediaContext.PreviewMode?

    private let media: MediaContext
    private var watcher: Task<Void, Never>?
    private var observedSession: UUID?

    public init(media: MediaContext) {
        self.media = media
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Starts following the open project, if it is not followed already.
    public func follow() async {
        guard let session = await media.editor.session else {
            watcher?.cancel()
            watcher = nil
            observedSession = nil
            player.replaceCurrentItem(with: nil)
            built = nil
            revision = -1
            return
        }
        let id = session.instanceID
        if id == observedSession {
            // Catch up at once if an edit has not been picked up yet.
            let behind = await session.revision != revision
            if behind || previewMode != builtMode { await rebuild() }
            return
        }
        observedSession = id
        watcher?.cancel()
        await rebuild()
        let changes = await session.changes()
        watcher = Task { [weak self] in
            for await _ in changes {
                await self?.rebuild()
            }
        }
    }

    /// Whether an HLG project plays as SDR now: the setting and the display decide.
    public var showsSDR: Bool { media.editor.settings.current.preview.showsSDR(displayHDR: displayHDR, hdrFootage: hdrFootage) }

    /// How the player shows the project now: range and gamma.
    public var previewMode: MediaContext.PreviewMode {
        .init(sdr: showsSDR, gamma: media.editor.settings.current.preview.gamma)
    }

    /// The gamma SDR is shown with; nil while the picture is HLG.
    public var previewGamma: UserSettings.PreviewSettings.Gamma? { previewRange == .sdr ? built?.gamma : nil }

    /// The range of the picture being played.
    public var previewRange: DynamicRange? { built.map { $0.hdr && !$0.sdrPreview ? .hlg : .sdr } }

    /// Takes the display the picture is on and shows the range and gamma that apply.
    /// Cheap when nothing changed, so the app calls it on its timer: that
    /// catches a window moved to another screen, HDR switched in System
    /// Settings and a changed setting alike.
    public func refreshPreviewRange(displayHDR hdr: Bool?) {
        if let hdr { displayHDR = hdr }
        guard observedSession != nil, let last = builtMode else { return }
        let now = previewMode
        guard now != last else { return }
        builtMode = now   // once per change, also when the build fails
        Task { await rebuild() }
    }

    /// The rebuild running now; the next one waits for it.
    private var rebuildChain: Task<Void, Never>?

    /// Rebuilds the composition and keeps the playhead and the play state.
    /// Rebuilds run one after another: two at once would read the playhead
    /// of an item still seeking (0) and move it back to the start.
    public func rebuild() async {
        let previous = rebuildChain
        let task = Task { @MainActor in
            await previous?.value
            await self.rebuildNow()
        }
        rebuildChain = task
        await task.value
    }

    private func rebuildNow() async {
        if let session = await media.editor.session { hdrFootage = await session.project.showsHDRFootage }
        let mode = previewMode
        builtMode = mode
        do {
            let built = try await media.composition(preview: mode)
            if let old = self.built, old.composition === built.composition, player.currentItem != nil {
                // Only looks changed: the compositor already reads the new
                // values; a paused frame is drawn again with them.
                if player.rate == 0 { redrawFrame() }
                self.revision = await media.editor.session?.revision ?? -1
                lastError = nil
                onRebuild?()
                return
            }
            let wasPlaying = player.rate != 0
            let now = player.currentTime()
            // A seek still on its way wins over where the old item stood:
            // replacing the item cancels it, and the owner (or an agent)
            // asked for that time last.
            let keep = wanted.map(cm) ?? (now.isNumeric ? now : .zero)
            // Until the new item has landed there, this is where the playhead is.
            wanted = time(keep)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            let end = cm(built.duration)
            self.built = built
            let target = time(CMTimeMinimum(keep, end))
            if await exactSeek(target), let w = wanted, w >= target { wanted = nil }
            if wasPlaying { player.play() }
            self.revision = await media.editor.session?.revision ?? -1
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        onRebuild?()
    }

    /// Draws the paused frame again (after its looks changed): a new copy of
    /// the same video composition makes the player ask the compositor again.
    public func redrawFrame() {
        guard let item = player.currentItem, let vc = built?.videoComposition else { return }
        item.videoComposition = vc.mutableCopy() as? AVVideoComposition
        // A new item still settling on its frame (just rebuilt) may skip the
        // new composition; a seek to the same frame makes it draw for sure.
        if item.status != .readyToPlay || wanted != nil { return }
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Shows looks that are not applied yet (a colour slider being dragged)
    /// on the current frame, without touching the project.
    public func previewLooks(_ looks: [Look]) {
        guard let built else { return }
        built.setLooks(looks)
        if player.rate == 0 { redrawFrame() }
    }

    /// The playhead: where a seek or a rebuild still on its way is going,
    /// else where the player stands. While an item is being replaced the
    /// player itself reads 0 for a moment; the playhead never jumps there.
    public var currentTime: Time { player.rate == 0 ? wanted ?? rawTime : rawTime }

    /// Where the player's current item actually stands.
    private var rawTime: Time { time(player.currentTime()) }

    /// Frames the display skipped since the current item started, as the
    /// player reports them. Only meaningful while a window shows the picture.
    public var droppedFrames: Int {
        player.currentItem?.accessLog()?.events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) } ?? 0
    }
    public var isPlaying: Bool { player.rate != 0 }
    public var duration: Time { built?.duration ?? .zero }

    public func play(rate: Float = 1) {
        if currentTime >= duration - Time(seconds: 0.05) { player.seek(to: .zero) }
        player.rate = rate
    }

    public func pause() { player.pause() }

    public func togglePlay() { isPlaying ? pause() : play() }

    /// Where the last seek is going until it has landed; a rebuild in the
    /// meantime goes there instead of back to the old time.
    private var wanted: Time?

    /// Moves the playhead to an exact frame.
    public func seek(_ t: Time) async {
        let rate = built?.frameRate ?? .fps60
        let asked = Time.max(.zero, t.snapped(to: rate))
        // An edit not picked up yet may change the length (a seek right
        // after adding a long clip): the rebuild clamps to the new end.
        let behind = await media.editor.session?.revision != revision
        if behind { wanted = asked }
        let target = Time.min(asked, duration)
        if !behind { wanted = target }
        if await exactSeek(target), wanted == target { wanted = nil }
    }

    /// Counts seeks, so one still stepping gives way to a newer one.
    private var seeks = 0

    /// Seeks to a frame. Leading frames of open-GOP video (see `DecodeStart`)
    /// do not decode when jumped to, so there the player seeks to where
    /// in-order decoding can start and steps forward to the frame.
    /// False when the seek was cancelled (by a newer seek or a new item).
    @discardableResult
    private func exactSeek(_ target: Time) async -> Bool {
        seeks += 1
        let this = seeks
        guard let built, let from = built.inOrderStart(at: target), from < target else {
            return await player.seek(to: cm(target), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard await player.seek(to: cm(from), toleranceBefore: .zero, toleranceAfter: .zero) else { return false }
        // Step one decoded frame at a time: a squeezed lead-in holds frames
        // closer together than the project frame rate, so a step count
        // computed from the frame rate would stop short (measured).
        let slack = Time(ticks: 240)   // 1 ms
        var steps = 0
        while rawTime < target - slack, steps < 600, let item = player.currentItem {
            let before = rawTime
            item.step(byCount: 1)
            steps += 1
            // A step lands asynchronously; wait for it (at most 100 ms).
            var waited = 0
            while rawTime == before, waited < 50 {
                try? await Task.sleep(nanoseconds: 2_000_000)
                waited += 1
            }
            guard this == seeks else { return false }
            if rawTime == before { break }
        }
        guard this == seeks else { return false }
        // A step can pass a cut that starts on such a frame, or not move in
        // an item still loading (measured: one frame late, or at 0). The
        // playhead still belongs on the target; the app draws that frame's
        // exact picture over the player (FrameCapture).
        if rawTime > target + slack || rawTime < target - slack {
            return await player.seek(to: cm(target), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        return true
    }

    public func step(frames: Int) async {
        let rate = built?.frameRate ?? .fps60
        await seek(currentTime + Time(ticks: rate.frameDuration.ticks * Int64(frames)))
    }

    public enum Jump: String, CaseIterable, Sendable { case start, end, previousEdge, nextEdge }

    /// Start or end of the timeline, or the nearest clip edge before or after
    /// the playhead.
    public func jump(_ j: Jump, in project: Project, tracks: [EntityID]? = nil) async {
        switch j {
        case .start: await seek(.zero)
        case .end: await seek(duration)
        case .previousEdge, .nextEdge:
            let chosen = project.tracks.filter { t in
                if let tracks { return tracks.contains(t.id) }
                return t.kind == .main
            }
            var edges = Set<Int64>([0, project.duration.ticks])
            for t in chosen { for c in t.clips { edges.insert(c.start.ticks); edges.insert(c.end.ticks) } }
            let now = currentTime.ticks
            let target = j == .nextEdge ? edges.filter { $0 > now }.min() : edges.filter { $0 < now }.max()
            if let target { await seek(Time(ticks: target)) }
        }
    }
}

extension Project {
    /// Whether a visible track shows HLG or PQ footage.
    var showsHDRFootage: Bool {
        let hdr = [kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ].map { $0 as String }
        let assets = Set(media.filter { $0.info.video?.transfer.map(hdr.contains) == true }.map(\.id))
        guard !assets.isEmpty else { return false }
        return tracks.contains { t in t.kind != .audio && !t.hidden && t.clips.contains { assets.contains($0.asset) } }
    }
}

extension MediaTools {
    public static func playerTools(_ player: PlayerController) -> [Tool] {
        @Sendable func state() async -> JSONValue {
            await MainActor.run {
                .object([
                    "time": .number(player.currentTime.seconds),
                    "playing": .bool(player.isPlaying),
                    "duration": .number(player.duration.seconds),
                    "revision": .number(Double(player.revision)),
                    "previewGamma": player.previewGamma.map { .string($0.rawValue) } ?? .null,
                    "previewRange": player.previewRange.map { .string($0.rawValue) } ?? .null,
                    "displayHDR": player.displayHDR.map { .bool($0) } ?? .null,
                    "droppedFrames": .number(Double(player.droppedFrames)),
                    "error": player.lastError.map { .string($0) } ?? .null,
                ])
            }
        }
        return [
            Tool("player.state", .read, "Playhead time, whether it is playing, length, the revision it shows and the preview range: an HLG project plays as sdr unless it has HDR footage and the display has HDR (setting preview.dynamicRange: auto, project or sdr); previewGamma is how SDR is shown (setting preview.gamma: video as CapCut and plain players, edits as Edits in an SDR project, with lighter shadows); export is affected by neither.") { _, _ in
                await player.follow()
                return await state()
            },
            Tool("player.play", .read, "Start playback from the playhead. Not recorded in the history.", [
                Parameter("rate", .number, "Speed; default 1"),
            ]) { _, args in
                await player.follow()
                let rate = Float(try args.double("rate") ?? 1)
                await player.play(rate: rate)
                return await state()
            },
            Tool("player.pause", .read, "Pause playback.") { _, _ in
                await player.follow()
                await player.pause()
                return await state()
            },
            Tool("player.toggle", .read, "Play if paused, pause if playing (the space bar).") { _, _ in
                await player.follow()
                await player.togglePlay()
                return await state()
            },
            Tool("player.step", .read, "Move the playhead by whole frames; negative goes back.", [
                Parameter("frames", .integer, "Frames to move, for example 1 or -10", required: true),
            ]) { _, args in
                await player.follow()
                await player.step(frames: try args.int("frames")!)
                return await state()
            },
            Tool("player.seek", .read, "Move the playhead to a time (snapped to a frame).", [
                Parameter("time", .seconds, "Timeline time", required: true),
            ]) { _, args in
                await player.follow()
                await player.seek(try args.time("time")!)
                return await state()
            },
            Tool("player.jump", .read, "Move the playhead to the start, the end, or the previous or next clip edge.", [
                Parameter("to", .oneOf(PlayerController.Jump.allCases.map(\.rawValue)), "start, end, previousEdge or nextEdge", required: true),
                Parameter("tracks", .array(.id), "Tracks whose clip edges count; default the main track"),
            ]) { editor, args in
                await player.follow()
                guard let j = PlayerController.Jump(rawValue: try args.requiredString("to")) else {
                    throw EditorError.invalid("to must be start, end, previousEdge or nextEdge", parameter: "to")
                }
                let p = await (try await editor.requireSession()).project
                let tracks = try args.strings("tracks")?.map { EntityID($0) }
                await player.jump(j, in: p, tracks: tracks)
                return await state()
            },
        ]
    }
}
