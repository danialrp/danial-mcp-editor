/// Rules for finding pauses to cut, measured on a file's sound level.
/// Defaults are the values of the production flow (requirement E-10).
public struct SilenceRules: Codable, Equatable, Sendable {
    /// Loud speech is this percentile of all 10 ms levels.
    public var speechPercentile: Double = 99.5
    /// Silence is this many dB below loud speech.
    public var silenceBelowSpeechDB: Double = 20
    /// The quiet end of a word (a soft verb ending) lies between the silence
    /// line and this many dB below it, and belongs to the word.
    public var quietTailBelowSilenceDB: Double = 15
    /// A sound this short between two silences is a click, not speech.
    public var clickMaxSeconds: Double = 0.06
    /// Shorter pauses are left alone.
    public var minPause: Double = 0.25
    /// Silence kept after the end of a word.
    public var keepAfterWord: Double = 0.35
    /// Silence kept before the next word.
    public var keepBeforeWord: Double = 0.10

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SilenceRules()
        speechPercentile = try c.decodeIfPresent(Double.self, forKey: .speechPercentile) ?? d.speechPercentile
        silenceBelowSpeechDB = try c.decodeIfPresent(Double.self, forKey: .silenceBelowSpeechDB) ?? d.silenceBelowSpeechDB
        quietTailBelowSilenceDB = try c.decodeIfPresent(Double.self, forKey: .quietTailBelowSilenceDB) ?? d.quietTailBelowSilenceDB
        clickMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .clickMaxSeconds) ?? d.clickMaxSeconds
        minPause = try c.decodeIfPresent(Double.self, forKey: .minPause) ?? d.minPause
        keepAfterWord = try c.decodeIfPresent(Double.self, forKey: .keepAfterWord) ?? d.keepAfterWord
        keepBeforeWord = try c.decodeIfPresent(Double.self, forKey: .keepBeforeWord) ?? d.keepBeforeWord
    }
}

/// A stretch of a clip to remove.
public struct SilenceCut: Codable, Equatable, Sendable {
    public var clip: EntityID
    /// Timeline range, on the frame grid.
    public var start: Time
    public var end: Time
    /// The same range in the media file.
    public var sourceStart: Time
    public var sourceEnd: Time
    /// Length of the whole pause in the file, before padding.
    public var pause: Double
}

/// Finds pauses from a level envelope, the way the production flow does:
/// cut edges always fall in silence, never on sound, and the silence after
/// the last word is never cut.
public enum SilenceFinder {
    /// Pauses in source seconds, each with where the cut may start and end.
    public static func pauses(levelsDB db: [Float], hop: Double, rules r: SilenceRules)
        -> [(start: Double, end: Double, cutFrom: Double, cutTo: Double)] {
        let n = db.count
        guard n > 0 else { return [] }
        let sorted = db.sorted()
        let ref = Double(sorted[min(n - 1, Int(Double(n) * r.speechPercentile / 100))])
        let line = Float(ref - r.silenceBelowSpeechDB)
        let quietLine = line - Float(r.quietTailBelowSilenceDB)
        var zero = db.map { $0 < line }
        // A short sound between two silences counts as silence.
        let click = Int((r.clickMaxSeconds / hop).rounded())
        var i = 0
        while i < n {
            if !zero[i] {
                var j = i
                while j < n, !zero[j] { j += 1 }
                if j - i <= click, i > 0, j < n { for k in i..<j { zero[k] = true } }
                i = j
            } else { i += 1 }
        }
        guard let lastSpeech = zero.lastIndex(of: false) else { return [] }
        var out: [(Double, Double, Double, Double)] = []
        i = 0
        while i < n {
            guard zero[i] else { i += 1; continue }
            var j = i
            while j < n, zero[j] { j += 1 }
            let s = Double(i) * hop, e = Double(j) * hop
            if e - s >= r.minPause, i < lastSpeech {
                // Walk past the quiet end of the word before, and the quiet
                // start of the word after.
                var a = i, b = j
                while a < j, db[a] >= quietLine { a += 1 }
                while b > a, db[b - 1] >= quietLine { b -= 1 }
                let from = i == 0 ? 0 : Double(a) * hop + r.keepAfterWord
                let to = Double(b) * hop - r.keepBeforeWord
                if to - from > 0.02 { out.append((s, e, from, to)) }
            }
            i = j
        }
        return out
    }

    /// Cuts for the clips of a track. `envelopes` gives each media file's
    /// levels; clips without one are skipped. Cuts land on whole frames inside
    /// the pause, so no edge touches sound.
    public static func cuts(track: Track, envelopes: [EntityID: [Float]], hop: Double,
                            rules: SilenceRules, frameRate: FrameRate, within: TimeRange? = nil) -> [SilenceCut] {
        var cache: [EntityID: [(start: Double, end: Double, cutFrom: Double, cutTo: Double)]] = [:]
        var out: [SilenceCut] = []
        let frame = frameRate.frameDuration.ticks
        for c in track.clips {
            if let within, c.end <= within.start || c.start >= within.end { continue }
            guard let db = envelopes[c.asset] else { continue }
            let ps = cache[c.asset] ?? pauses(levelsDB: db, hop: hop, rules: rules)
            cache[c.asset] = ps
            let s0 = c.sourceStart.seconds, s1 = c.sourceEnd.seconds
            for p in ps where p.cutTo > s0 && p.cutFrom < s1 {
                // A pause that runs past the clip's own edge is left to the editor.
                guard p.start >= s0, p.end <= s1 else { continue }
                let from = max(p.cutFrom, s0), to = min(p.cutTo, s1)
                var a = c.start.ticks + Int64(((from - s0) / c.speed * Double(Time.ticksPerSecond)).rounded())
                var b = c.start.ticks + Int64(((to - s0) / c.speed * Double(Time.ticksPerSecond)).rounded())
                a = (a + frame - 1) / frame * frame      // round inward to whole frames
                b = b / frame * frame
                if let within { a = max(a, within.start.ticks); b = min(b, within.end.ticks) }
                guard b - a >= frame else { continue }
                out.append(SilenceCut(clip: c.id, start: Time(ticks: a), end: Time(ticks: b),
                                      sourceStart: c.sourceTime(at: Time(ticks: a)), sourceEnd: c.sourceTime(at: Time(ticks: b)),
                                      pause: ((p.end - p.start) * 100).rounded() / 100))
            }
        }
        return out
    }
}
