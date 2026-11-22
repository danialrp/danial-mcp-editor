import AVFoundation
import EditorCore

/// A composition made from one source file with many cuts and a speed change,
/// plus where the source's sync marks (start of every second) land after editing.
struct CutComposition {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition
    let segments: Int
    /// Composition times, in seconds, where each sync mark starts.
    let marks: [Double]
    let buildSeconds: Double
}

/// Deterministic pseudo-random numbers, so every run cuts the same way.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func cmTime(_ t: Time) -> CMTime { CMTime(value: t.ticks, timescale: Int32(Time.ticksPerSecond)) }

/// Builds kept frame ranges: `cuts` removed gaps of 1-4 frames, none touching a
/// sync mark (frames 0-3 of every second, plus one frame of margin each side).
func keptRanges(totalFrames: Int64, cuts: Int, fps: Int64, seed: UInt64) -> [Range<Int64>] {
    // Shrink the average segment until the requested number of cuts fits.
    var avg = max(3, totalFrames / Int64(cuts + 1))
    while true {
        let r = keptRanges(totalFrames: totalFrames, cuts: cuts, fps: fps, seed: seed, avg: avg)
        if r.count > cuts || avg <= 3 { return r }
        avg -= 1
    }
}

private func keptRanges(totalFrames: Int64, cuts: Int, fps: Int64, seed: UInt64, avg: Int64) -> [Range<Int64>] {
    var rng = SplitMix64(state: seed)
    func protected(_ f: Int64) -> Bool { let m = f % fps; return m >= fps - 1 || m <= 4 }
    var kept: [Range<Int64>] = []
    var start: Int64 = 0, f: Int64 = 0
    while f < totalFrames {
        let segLen = Int64.random(in: 2...max(2, avg * 2 - 4), using: &rng)
        f = min(totalFrames, f + segLen)
        if f >= totalFrames || kept.count >= cuts { break }
        let gap = Int64.random(in: 1...4, using: &rng)
        let gapRange = f..<min(totalFrames, f + gap)
        if gapRange.contains(where: protected) { continue }
        kept.append(start..<f)
        start = gapRange.upperBound
        f = start
    }
    kept.append(start..<totalFrames)
    return kept
}

func buildCutComposition(source url: URL, cuts: Int, speed: Double, renderSize: CGSize? = nil,
                         seed: UInt64 = 1) async throws -> CutComposition {
    let t0 = Date()
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let vSrc = try await asset.loadTracks(withMediaType: .video).first!
    let aSrc = try await asset.loadTracks(withMediaType: .audio).first
    let fps = Int64((try await vSrc.load(.nominalFrameRate)).rounded())
    let natural = try await vSrc.load(.naturalSize)
    let duration = try await asset.load(.duration)
    let rate = FrameRate(fps: Int(fps))!
    let totalFrames = Int64((duration.seconds * Double(fps)).rounded(.down))

    let comp = AVMutableComposition()
    let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let aTrack = aSrc.flatMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }

    let ranges = cuts > 0 ? keptRanges(totalFrames: totalFrames, cuts: cuts, fps: fps, seed: seed)
                          : [0..<totalFrames]
    var cursor = Time.zero
    var marks: [Double] = []
    for r in ranges {
        let srcStart = rate.time(ofFrame: r.lowerBound)
        let srcDur = rate.time(ofFrame: Int64(r.count))
        let range = CMTimeRange(start: cmTime(srcStart), duration: cmTime(srcDur))
        try vTrack.insertTimeRange(range, of: vSrc, at: cmTime(cursor))
        if let aSrc, let aTrack { try aTrack.insertTimeRange(range, of: aSrc, at: cmTime(cursor)) }
        let outDur = Time(ticks: Int64((Double(srcDur.ticks) / speed).rounded()))
        if speed != 1 {
            comp.scaleTimeRange(CMTimeRange(start: cmTime(cursor), duration: cmTime(srcDur)),
                                toDuration: cmTime(outDur))
        }
        for f in r where f % fps == 0 {
            let offset = Double((rate.time(ofFrame: f) - srcStart).ticks) * Double(outDur.ticks) / Double(srcDur.ticks)
            marks.append((Double(cursor.ticks) + offset) / Double(Time.ticksPerSecond))
        }
        cursor = cursor + outDur
    }

    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = MetalCompositor.self
    vc.frameDuration = CMTime(value: 1, timescale: Int32(fps))
    vc.renderSize = renderSize ?? natural
    let instr = AVMutableVideoCompositionInstruction()
    instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
    instr.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)]
    vc.instructions = [instr]

    return CutComposition(composition: comp, videoComposition: vc, segments: ranges.count,
                          marks: marks, buildSeconds: Date().timeIntervalSince(t0))
}
