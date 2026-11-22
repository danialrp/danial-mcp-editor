import AVFoundation
import EditorCore
import EditorKit
import Foundation

/// Export tools (R-1): presets, the export job, checking a finished file and
/// the segment cache.
public enum ExportTools {
    /// A preset by name with any fields given in `args` changed.
    static func preset(_ editor: Editor, _ args: Args) throws -> ExportPreset {
        let name = try args.requiredString("preset")
        let presets = editor.settings.current.exportPresets
        guard var p = presets[name] else {
            throw EditorError(.notFound, "no export preset \(name); presets: \(presets.keys.sorted().joined(separator: ", "))")
        }
        try override(&p, args)
        return p
    }

    static func override(_ p: inout ExportPreset, _ args: Args) throws {
        if let w = try args.int("width") { p.width = w }
        if let h = try args.int("height") { p.height = h }
        if let f = try args.int("frameRate") {
            guard let r = FrameRate(fps: f) else { throw EditorError.invalid("frameRate must divide 240000, for example 24, 25, 30, 50 or 60", parameter: "frameRate") }
            p.frameRate = r
        }
        if let d = try args.string("dynamicRange") {
            guard let r = DynamicRange(rawValue: d) else { throw EditorError.invalid("dynamicRange is sdr or hlg", parameter: "dynamicRange") }
            p.dynamicRange = r
        }
        if let c = try args.string("videoCodec") {
            guard let v = ExportPreset.VideoCodec(rawValue: c) else {
                throw EditorError.invalid("videoCodec is one of \(ExportPreset.VideoCodec.allCases.map(\.rawValue).joined(separator: ", "))", parameter: "videoCodec")
            }
            p.videoCodec = v
        }
        if let b = try args.double("videoBitrateMbps") { p.videoBitrateMbps = b }
        if let a = try args.string("audioCodec") {
            guard let v = ExportPreset.AudioCodec(rawValue: a) else { throw EditorError.invalid("audioCodec is aac or pcm", parameter: "audioCodec") }
            p.audioCodec = v
        }
        if let k = try args.int("audioBitrateKbps") { p.audioBitrateKbps = k }
        if let c = try args.string("container") {
            guard let v = ExportPreset.Container(rawValue: c) else { throw EditorError.invalid("container is mp4 or mov", parameter: "container") }
            p.container = v
        }
        if let s = try args.string("summary") { p.summary = s }
    }

    static let formatParameters: [Parameter] = [
        Parameter("width", .integer, "Output width; with height, scales the canvas"),
        Parameter("height", .integer, "Output height"),
        Parameter("frameRate", .integer, "Frames per second, for example 30 or 60"),
        Parameter("dynamicRange", .oneOf(DynamicRange.allCases.map(\.rawValue)), "sdr (Rec.709) or hlg (HDR)"),
        Parameter("videoCodec", .oneOf(ExportPreset.VideoCodec.allCases.map(\.rawValue)), "hevc (10-bit), h264 (8-bit), prores422hq or prores4444"),
        Parameter("videoBitrateMbps", .number, "Average video bit rate for HEVC and H.264"),
        Parameter("audioCodec", .oneOf(ExportPreset.AudioCodec.allCases.map(\.rawValue)), "aac or pcm (24-bit, mov only)"),
        Parameter("audioBitrateKbps", .integer, "AAC bit rate, 64 to 512"),
        Parameter("container", .oneOf(ExportPreset.Container.allCases.map(\.rawValue)), "mp4 or mov"),
    ]

    public static func make(_ media: MediaContext, jobs: JobCenter) -> [Tool] {
        [
            Tool("export.listPresets", .read, "Export presets: shipped delivery formats and saved ones. Size, frame rate or dynamic range left out mean the project's own.") { editor, _ in
                let presets = editor.settings.current.exportPresets
                return .object(["presets": .object(try presets.mapValues { try JSONValue(encoding: $0) })])
            },
            Tool("export.savePreset", .manage, "Save an export preset, starting from an existing one and changing the given fields.", [
                Parameter("name", .string, "Name of the new or changed preset", required: true),
                Parameter("from", .string, "Preset to start from; default the one named name"),
                Parameter("summary", .string, "One line describing the preset"),
            ] + formatParameters) { editor, args in
                let name = try args.requiredString("name").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw EditorError.invalid("name must not be empty", parameter: "name") }
                let presets = editor.settings.current.exportPresets
                let fromName = try args.string("from") ?? name
                guard var p = presets[fromName] else { throw EditorError(.notFound, "no export preset \(fromName) to start from") }
                try override(&p, args)
                let issues = p.problems()
                guard issues.isEmpty else { throw EditorError.invalid(issues.joined(separator: "; ")) }
                try editor.settings.update { $0.exportPresets[name] = p }
                return .object(["saved": .string(name), "preset": try JSONValue(encoding: p)])
            },
            Tool("export.start", .manage, "Export the open project to a file, as a job (job_wait or export_status follow it). Segments already rendered for the same frames are reused, so running it again after an interruption continues, and after a small edit only changed parts are rendered.", [
                Parameter("path", .string, "Output file; .mp4 or .mov to match the container", required: true),
                Parameter("preset", .string, "Export preset (export_listPresets), for example reel or lesson", required: true),
                Parameter("overwrite", .boolean, "Replace an existing file (it goes to the Trash)"),
            ] + formatParameters) { editor, args in
                let session = try await editor.requireSession()
                let p = try preset(editor, args)
                let issues = p.problems()
                guard issues.isEmpty else { throw EditorError.invalid("export settings: " + issues.joined(separator: "; ")) }
                var url = URL(fileURLWithPath: (try args.requiredString("path") as NSString).expandingTildeInPath)
                if url.pathExtension.isEmpty { url.appendPathExtension(p.container.rawValue) }
                guard url.pathExtension.lowercased() == p.container.rawValue else {
                    throw EditorError.invalid("the file ends in .\(url.pathExtension) but the container is \(p.container.rawValue)", parameter: "path")
                }
                guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
                    throw EditorError(.notFound, "folder \(url.deletingLastPathComponent().path) does not exist")
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    guard try args.bool("overwrite") == true else {
                        throw EditorError(.conflict, "\(url.path) exists; pass overwrite true to replace it (the old file goes to the Trash)")
                    }
                }
                let (project, revision) = await (session.project, session.revision)
                let options = editor.settings.current.export
                let target = url
                let replace = try args.bool("overwrite") == true
                let id = await jobs.start("export") { ctx in
                    let tmpTarget = target.deletingLastPathComponent().appendingPathComponent(".dme-out-\(UUID().uuidString).\(p.container.rawValue)")
                    let report = try await ExportEngine.run(project: project, revision: revision, preset: p, options: options,
                                                            to: tmpTarget, media: media) { done, total, message in
                        try ctx.checkCancelled()
                        await ctx.progress(0.95 * Double(done) / Double(max(1, total)), message)
                    }
                    if FileManager.default.fileExists(atPath: target.path) {
                        guard replace else { throw EditorError(.conflict, "\(target.path) appeared during the export; nothing was replaced") }
                        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                    }
                    try FileManager.default.moveItem(at: tmpTarget, to: target)
                    var r = report
                    r.path = target.path
                    return try JSONValue(encoding: r)
                }
                return .object(["jobId": .string(id), "path": .string(url.path), "preset": try JSONValue(encoding: p)])
            },
            Tool("export.status", .read, "An export job: progress, which segment, and when done the report (segments rendered and reused, frames, timings).", [
                Parameter("jobId", .string, "Job id from export_start", required: true),
            ]) { _, args in
                try JSONValue(encoding: try await jobs.info(try args.requiredString("jobId")))
            },
            Tool("export.verify", .read, "Check a finished file: container, codec, size, frame rate, frame count, duration, colour tags, bit depth and sound, and how it compares with the open project.", [
                Parameter("path", .string, "File to check", required: true),
            ]) { editor, args in
                let url = URL(fileURLWithPath: (try args.requiredString("path") as NSString).expandingTildeInPath)
                var facts = try await ExportVerify.inspect(url)
                if let session = await editor.session {
                    let p = await session.project
                    let expected = p.duration.seconds
                    let got = facts["duration"]?.doubleValue ?? 0
                    let frame = 1.0 / Double(facts["frameRate"]?.doubleValue ?? Double(p.settings.frameRate.fps))
                    facts["project"] = .object([
                        "duration": .number(expected),
                        "durationMatches": .bool(abs(got - expected) <= frame + 0.0001),
                    ])
                }
                return .object(facts)
            },
            Tool("export.cacheInfo", .read, "Size of the export segment cache, per project.") { _, _ in
                let root = ExportEngine.cacheRoot
                let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                var out: [String: JSONValue] = [:]
                for d in dirs where d.hasDirectoryPath {
                    let files = (FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
                    let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                    out[d.lastPathComponent] = .object(["files": .number(Double(files.count)), "megabytes": .number((Double(bytes) / 1e6).rounded())])
                }
                return .object(["folder": .string(root.path), "projects": .object(out)])
            },
            Tool("export.clearCache", .manage, "Move cached export segments to the Trash, for one project or all. The next export renders everything again.", [
                Parameter("project", .string, "Project id; default all projects"),
            ]) { _, args in
                let target = try args.string("project").map { ExportEngine.cacheRoot.appendingPathComponent($0) } ?? ExportEngine.cacheRoot
                guard FileManager.default.fileExists(atPath: target.path) else { return .object(["cleared": .bool(false)]) }
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                return .object(["cleared": .bool(true), "folder": .string(target.path)])
            },
        ]
    }
}

/// Facts about a media file, read without decoding the picture.
public enum ExportVerify {
    public static func inspect(_ url: URL) async throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditorError(.notFound, "no file at \(url.path)") }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var o: [String: JSONValue] = [
            "path": .string(url.path),
            "megabytes": .number((Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1e4).rounded() / 100),
            "duration": .number(try await asset.load(.duration).seconds),
        ]
        if let v = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await v.load(.naturalSize)
            o["width"] = .number(Double(size.width))
            o["height"] = .number(Double(size.height))
            o["frameRate"] = .number(Double(try await v.load(.nominalFrameRate)).rounded())
            o["bitRateMbps"] = .number((Double(try await v.load(.estimatedDataRate)) / 1e4).rounded() / 100)
            if let fd = try await v.load(.formatDescriptions).first {
                o["codec"] = .string(fourCC(CMFormatDescriptionGetMediaSubType(fd)))
                let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
                o["primaries"] = .string(ext[kCVImageBufferColorPrimariesKey as String] as? String ?? "untagged")
                o["transfer"] = .string(ext[kCVImageBufferTransferFunctionKey as String] as? String ?? "untagged")
                o["matrix"] = .string(ext[kCVImageBufferYCbCrMatrixKey as String] as? String ?? "untagged")
                if let bits = ext["BitsPerComponent"] as? Int { o["bitDepth"] = .number(Double(bits)) }
            }
            o["frames"] = .number(Double(try await countSamples(asset, v)))
        }
        if let a = try await asset.loadTracks(withMediaType: .audio).first, let fd = try await a.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            o["audio"] = .object([
                "codec": .string(fourCC(asbd.mFormatID)),
                "sampleRate": .number(asbd.mSampleRate),
                "channels": .number(Double(asbd.mChannelsPerFrame)),
                "duration": .number(try await a.load(.timeRange).duration.seconds),
            ])
        }
        return o
    }

    /// Frames in a video track, counted from its samples (nothing decoded).
    static func countSamples(_ asset: AVAsset, _ track: AVAssetTrack) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.startReading()
        var n = 0
        while let sb = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
        return n
    }

    static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespaces) ?? "\(v)"
    }
}
