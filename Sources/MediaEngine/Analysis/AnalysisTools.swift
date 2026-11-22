import AVFoundation
import EditorCore
import EditorKit
import Foundation

/// Sound analysis tools: levels, loudness, silence finding and automatic
/// cuts, voice normalisation.
public enum AnalysisTools {
    /// Shared by the tools and the timeline's waveforms.
    public static let levels = LevelCache()

    public static func make(_ media: MediaContext) -> [Tool] {
        let editor = media.editor

        /// Silence rules from settings, with any overrides from the call.
        @Sendable func rules(_ args: Args) throws -> SilenceRules {
            var r = editor.settings.current.cutRules.silence
            if let o = args.values["rules"], o != .null {
                var base = try JSONValue(encoding: r).objectValue ?? [:]
                for (k, v) in o.objectValue ?? [:] {
                    guard base[k] != nil else { throw EditorError.invalid("rules has no \(k); rules are \(base.keys.sorted().joined(separator: ", "))", parameter: "rules") }
                    base[k] = v
                }
                r = try JSONValue.object(base).decode(SilenceRules.self)
            }
            return r
        }

        @Sendable func findCuts(_ args: Args) async throws -> (Project, Int, [SilenceCut], SilenceRules) {
            let session = try await editor.requireSession()
            let p = await session.project
            let ti = try args.string("track").map { try p.trackIndex(EntityID($0)) } ?? p.mainTrackIndex()
            let r = try rules(args)
            var env: [EntityID: [Float]] = [:]
            for id in Set(p.tracks[ti].clips.map(\.asset)) {
                let a = try p.asset(id)
                if a.info.audio != nil { env[id] = try await levels.envelope(for: a).rmsDB }
            }
            var within: TimeRange?
            if args.has("start") || args.has("end") {
                within = TimeRange(start: try args.time("start") ?? .zero, end: try args.time("end") ?? p.duration)
            }
            let cuts = SilenceFinder.cuts(track: p.tracks[ti], envelopes: env, hop: LevelEnvelope.hop, rules: r,
                                          frameRate: p.settings.frameRate, within: within)
            return (p, ti, cuts, r)
        }

        let finderParams = [
            Parameter("track", .id, "Track id; default the main track"),
            Parameter("start", .seconds, "Only this part of the timeline: start"),
            Parameter("end", .seconds, "Only this part of the timeline: end"),
            Parameter("rules", .object, "Override some cut rules for this call, for example {\"minPause\": 0.4}; the rest come from settings.cutRules.silence"),
        ]

        return [
            Tool("audio.levels", .read, "Sound level of a media file over time: RMS and peak in dBFS, plus the level of loud speech. Computed once per file and cached.", [
                Parameter("asset", .id, "Media asset id", required: true),
                Parameter("sourceStart", .seconds, "From this time in the file; default 0"),
                Parameter("sourceEnd", .seconds, "To this time in the file; default the end"),
                Parameter("points", .integer, "Number of values to return, 10 to 5000; default 1000. Each is the loudest of its stretch"),
            ]) { _, args in
                let p = await (try await editor.requireSession()).project
                let a = try p.asset(EntityID(try args.requiredString("asset")))
                let e = try await levels.envelope(for: a)
                let hop = LevelEnvelope.hop
                let i0 = max(0, Int((try args.double("sourceStart") ?? 0) / hop))
                let i1 = min(e.rmsDB.count, Int((try args.double("sourceEnd") ?? e.duration) / hop))
                guard i1 > i0 else { throw EditorError.invalid("the range is empty", parameter: "sourceEnd") }
                let points = min(5000, max(10, try args.int("points") ?? 1000))
                let per = max(1, (i1 - i0 + points - 1) / points)
                var rms: [JSONValue] = [], peak: [JSONValue] = []
                for s in stride(from: i0, to: i1, by: per) {
                    let e1 = min(i1, s + per)
                    rms.append(.number(Double(e.rmsDB[s..<e1].max()!).rounded()))
                    peak.append(.number(Double(e.peakDB[s..<e1].max()!).rounded()))
                }
                return .object([
                    "asset": .string(a.id.raw), "sourceStart": .number(Double(i0) * hop), "step": .number(Double(per) * hop),
                    "speechLevelDB": .number(Double(e.speechLevelDB).rounded()), "rmsDB": .array(rms), "peakDB": .array(peak),
                ])
            },
            Tool("audio.loudness", .read, "Integrated loudness (LUFS, ITU-R BS.1770), loudest 3 s and highest sample peak. Of a media file, or of the timeline as it sounds with all gains and fades.", [
                Parameter("asset", .id, "Media asset id; omit to measure the timeline"),
                Parameter("start", .seconds, "Start (file time with asset, timeline time without)"),
                Parameter("end", .seconds, "End"),
            ]) { _, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let start = try args.time("start") ?? .zero
                if let id = try args.string("asset") {
                    let a = try p.asset(EntityID(id))
                    let end = try args.time("end") ?? a.info.duration
                    let l = try await Loudness.measure(AVURLAsset(url: URL(fileURLWithPath: a.path)),
                                                       range: CMTimeRange(start: cm(start), end: cm(end)))
                    return try JSONValue(encoding: l)
                }
                let built = try await media.composition()
                let end = try args.time("end") ?? built.duration
                let l = try await Loudness.measure(built.composition, range: CMTimeRange(start: cm(start), end: cm(end)), audioMix: built.audioMix)
                return try JSONValue(encoding: l)
            },
            Tool("audio.findSilence", .read, "Pauses a track's clips would lose under the cut rules, without changing anything. Cut edges fall in silence on whole frames; the silence after the last word and pauses at clip edges are kept.", finderParams) { _, args in
                let (_, _, cuts, r) = try await findCuts(args)
                let removed = cuts.reduce(0.0) { $0 + ($1.end - $1.start).seconds }
                return .object([
                    "count": .number(Double(cuts.count)),
                    "removedSeconds": .number((removed * 100).rounded() / 100),
                    "rules": try JSONValue(encoding: r),
                    "cuts": try JSONValue(encoding: cuts),
                ])
            },
            Tool("audio.applySilenceCuts", .write, "Find pauses under the cut rules and remove them in one undoable step, then set the short sound fade at every join.", finderParams + [
                Parameter("joinFade", .seconds, "Fade on each side of every cut; default settings.cutRules.joinFade"),
                Parameter("dryRun", .boolean, "Show what would be cut without cutting"),
            ]) { _, args in
                let session = try await editor.requireSession()
                let (p, ti, cuts, _) = try await findCuts(args)
                guard !cuts.isEmpty else { return .object(["count": .number(0), "revision": .number(Double(await session.revision))]) }
                let track = p.tracks[ti].id
                // Back to front, so earlier cuts do not move later ones.
                var commands: [any EditorCommand] = cuts.reversed().map {
                    DeleteRange(start: $0.start, end: $0.end, ripple: true, tracks: [track])
                }
                let fade = try args.time("joinFade") ?? Time(seconds: editor.settings.current.cutRules.joinFade)
                commands.append(SetJoinFades(duration: fade, track: track))
                let r = try await session.apply(commands, dryRun: try args.bool("dryRun") ?? false)
                let removed = cuts.reduce(0.0) { $0 + ($1.end - $1.start).seconds }
                return .object([
                    "count": .number(Double(cuts.count)), "removedSeconds": .number((removed * 100).rounded() / 100),
                    "revision": .number(Double(r.revision)), "dryRun": .bool(r.dryRun),
                ])
            },
            Tool("audio.normalize", .write, "Set one gain on every clip of a track so the track reaches a loudness target without its peaks passing a ceiling, whichever comes first. Measured on the track alone.", [
                Parameter("track", .id, "Track id; default the main track"),
                Parameter("targetLUFS", .number, "Loudness target; default settings.cutRules.voiceLoudnessLUFS (-16)"),
                Parameter("peakCeilingDB", .number, "Highest peak allowed; default settings.cutRules.voicePeakCeilingDB (-1)"),
                Parameter("dryRun", .boolean, "Measure and show the gain without setting it"),
            ]) { _, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let ti = try args.string("track").map { try p.trackIndex(EntityID($0)) } ?? p.mainTrackIndex()
                guard !p.tracks[ti].clips.isEmpty else { throw EditorError.invalid("the track has no clips") }
                // Measure the track alone, at 0 dB.
                var solo = p
                var t = p.tracks[ti]
                t.muted = false
                for i in t.clips.indices { t.clips[i].gainDB = 0; t.clips[i].muted = false }
                solo.tracks = [t]
                let built = try await media.composition(for: solo)
                let l = try await Loudness.measure(built.composition, audioMix: built.audioMix)
                let rules = editor.settings.current.cutRules
                let target = try args.double("targetLUFS") ?? rules.voiceLoudnessLUFS
                let ceiling = try args.double("peakCeilingDB") ?? rules.voicePeakCeilingDB
                var gain = min(target - l.integratedLUFS, ceiling - l.samplePeakDBFS)
                gain = (gain * 2).rounded(.down) / 2   // 0.5 dB steps, never over
                gain = min(24, max(-60, gain))
                let r = try await session.apply([SetClipAudio(ids: t.clips.map(\.id), gainDB: gain)], dryRun: try args.bool("dryRun") ?? false)
                return .object([
                    "measured": try JSONValue(encoding: l), "gainDB": .number(gain),
                    "expectedLUFS": .number(((l.integratedLUFS + gain) * 10).rounded() / 10),
                    "expectedPeakDBFS": .number(((l.samplePeakDBFS + gain) * 10).rounded() / 10),
                    "revision": .number(Double(r.revision)), "dryRun": .bool(r.dryRun),
                ])
            },
        ]
    }
}
