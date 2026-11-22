import CoreGraphics
import EditorCore
import EditorKit
import Foundation

/// Person matte tools (X-3): an agent turns a footage file's matte on,
/// imports masks made elsewhere, makes the matte, reads its stability and
/// looks at its worst frames.
public enum MatteTools {
    static func footage(_ p: Project, _ id: EntityID) throws -> MediaAsset {
        guard let a = p.media.first(where: { $0.id == id }), a.kind == .file, a.info.video != nil else {
            throw EditorError(.notFound, "no footage file \(id) in the media pool")
        }
        return a
    }

    /// Footage with a matte: the one asked for, or every one the timeline uses.
    static func targets(_ p: Project, _ args: Args) throws -> [MediaAsset] {
        if let id = try args.string("id") {
            let a = try footage(p, EntityID(id))
            guard a.matte != nil else {
                throw EditorError.invalid("media \(id) has no matte; turn it on with media.setMatte (source vision or imported)", parameter: "id")
            }
            return [a]
        }
        let used = Set(p.tracks.flatMap { $0.clips.map(\.asset) })
        return p.media.filter { $0.matte != nil && used.contains($0.id) }
    }

    /// Where a source time of a file is shown on the timeline.
    static func timelineTimes(_ p: Project, asset: EntityID, source t: Double) -> [Double] {
        var out: [Double] = []
        for track in p.tracks {
            for c in track.clips where c.asset == asset && c.sourceStart.seconds <= t && t < c.sourceEnd.seconds {
                out.append(c.start.seconds + (t - c.sourceStart.seconds) * c.duration.seconds / max(c.sourceDuration.seconds, 1e-9))
            }
        }
        return out
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }

    public static func make(_ media: MediaContext, jobs: JobCenter) -> [Tool] {
        let store = media.mattes
        var tools: [Tool] = []
        tools.append(Tool("matte.import", .manage, "Copy person masks made elsewhere (for example SAM 3 from Edits' trackObject with saveMasks) into the project and use them as the file's matte. The folder holds one PNG per mask, named by its source millisecond (1234.png), upright, the shape of the picture; white is the person.", [
                Parameter("id", .id, "Footage media id", required: true),
                Parameter("folder", .string, "Folder of mask PNGs", required: true),
            ] + ToolCatalog.writeOptions) { editor, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let a = try footage(p, EntityID(try args.requiredString("id")))
                let src = URL(fileURLWithPath: (try args.requiredString("folder") as NSString).expandingTildeInPath, isDirectory: true)
                let list = MatteStore.importedMasks(src)
                guard !list.isEmpty else {
                    throw EditorError(.notFound, "no masks in \(src.path); files must be PNGs named by source millisecond, for example 1234.png")
                }
                let dst = MatteStore.importFolder(package: session.url, asset: a.id)
                let fm = FileManager.default
                if fm.fileExists(atPath: dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) }
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for (_, u) in list { try fm.copyItem(at: u, to: dst.appendingPathComponent(u.lastPathComponent)) }
                let r = try await session.apply([SetMediaMatte(id: a.id, source: MatteSource.imported.rawValue)],
                                                ifRevision: try args.int("ifRevision"), dryRun: try args.bool("dryRun") ?? false)
                await media.invalidate()
                return .object(["masks": .number(Double(list.count)), "from": .number(list.first!.ms / 1000), "to": .number(list.last!.ms / 1000),
                                "folder": .string(dst.path), "revision": .number(Double(r.revision))])
            })
        tools.append(Tool("matte.generate", .manage, "Make the person matte of footage, as a job: only the chunks the timeline shows and that are not made yet. Without id, every footage file with a matte on the timeline. The timeline picks each chunk up when done.", [
                Parameter("id", .id, "Footage media id"),
                Parameter("chunks", .array(.integer), "Only these chunk indexes"),
            ]) { editor, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let assets = try targets(p, args)
                guard !assets.isEmpty else { throw EditorError.invalid("no footage on the timeline has a matte; turn one on with media.setMatte") }
                let only = try args.values["chunks"]?.arrayValue.map { Set($0.compactMap { $0.doubleValue.map { Int($0) } }) }
                let seconds = editor.settings.current.matte.chunkSeconds
                let package = session.url
                let id = await jobs.start("matte") { ctx in
                    var made: [String: JSONValue] = [:]
                    for (n, a) in assets.enumerated() {
                        let want = only ?? MatteStore.needed(p, asset: a.id, chunkSeconds: seconds)
                        let done = try await store.generate(a, package: package, only: want) { k, total, message in
                            try ctx.checkCancelled()
                            await ctx.progress((Double(n) + Double(k) / Double(max(1, total))) / Double(assets.count), "\(a.name): \(message)")
                        }
                        made[a.id.raw] = .array(done.map { .number(Double($0)) })
                    }
                    await media.invalidate()
                    return .object(["made": .object(made)])
                }
                return .object(["jobId": .string(id)])
            })
        tools.append(Tool("matte.status", .read, "The person matte of footage: where it comes from, which chunks the timeline needs and whether each is made, and its stability over those chunks: overlap of each frame with the one before (IoU; 1 is identical), change of area, and the worst frames with where the timeline shows them. Look at the worst frames with matte.snapshot before using the matte.", [
                Parameter("id", .id, "Footage media id; default every footage file with a matte on the timeline"),
                Parameter("worst", .integer, "How many worst frames to list; default 12"),
            ]) { editor, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let seconds = editor.settings.current.matte.chunkSeconds
                var out: [JSONValue] = []
                for a in try targets(p, args) {
                    var o: [String: JSONValue] = ["id": .string(a.id.raw), "name": .string(a.name), "source": .string(a.matte!.rawValue)]
                    let needed = MatteStore.needed(p, asset: a.id, chunkSeconds: seconds)
                    do {
                        let chunks = try await store.chunks(a, package: session.url).filter { needed.contains($0.index) }
                        o["chunks"] = .array(chunks.map { c in
                            .object(["index": .number(Double(c.index)), "start": .number(c.start), "end": .number(c.end),
                                     "state": .string(c.current != nil ? "current" : c.stale != nil ? "stale" : "missing")])
                        })
                        var rows: [(t: Double, iou: Double, jump: Double)] = []
                        for c in chunks { if let url = c.current, let qa = MatteStore.qa(url) {
                            for i in qa.times.indices { rows.append((qa.times[i], qa.iou[i], qa.areaJump[i])) }
                        } }
                        if !rows.isEmpty {
                            let iou = rows.map(\.iou), jump = rows.map(\.jump)
                            o["stability"] = .object([
                                "frames": .number(Double(rows.count)),
                                "iouMin": .number(iou.min()!), "iou1Percent": .number(percentile(iou, 0.01)), "iouMedian": .number(percentile(iou, 0.5)),
                                "areaJumpMax": .number(jump.max()!), "areaJump99Percent": .number(percentile(jump, 0.99)),
                            ])
                            o["worstFrames"] = .array(rows.sorted { $0.iou < $1.iou }.prefix(try args.int("worst") ?? 12).map { r in
                                .object(["sourceTime": .number(r.t), "iou": .number(r.iou), "areaJump": .number(r.jump),
                                         "timelineTimes": .array(timelineTimes(p, asset: a.id, source: r.t).map { .number($0) })])
                            })
                        }
                    } catch let e as EditorError {
                        o["problem"] = .string(e.message)
                    }
                    out.append(.object(o))
                }
                return .object(["mattes": .array(out)])
            })
        tools.append(Tool("matte.snapshot", .read, "Frames of footage with its person matte drawn on them: the tight matte's outline in green, the wide one in red. Give source times (for example the worst frames from matte.status).", [
                Parameter("id", .id, "Footage media id", required: true),
                Parameter("sourceTimes", .array(.seconds), "Source times in the file", required: true),
                Parameter("path", .string, "Also save the PNG to this file"),
            ]) { editor, args in
                let session = try await editor.requireSession()
                let p = await session.project
                guard let a = try targets(p, args).first else { throw EditorError.invalid("no matte", parameter: "id") }
                let times = (args.values["sourceTimes"]?.arrayValue ?? []).compactMap(\.doubleValue)
                guard !times.isEmpty, times.count <= 24 else { throw EditorError.invalid("give 1 to 24 source times", parameter: "sourceTimes") }
                let chunks = try await store.chunks(a, package: session.url)
                var images: [(Time, CGImage)] = []
                for t in times {
                    guard let c = chunks.first(where: { $0.start <= t && t < $0.end }), let url = c.current ?? c.stale else {
                        throw EditorError(.notFound, "the matte at \(t) s is not made yet; run matte.generate")
                    }
                    let m = try await MatteStore.readFrame(url, at: t - c.start)
                    let frame = try await FrameCapture.sourceFrame(path: a.path, at: Time(seconds: t), maxWidth: m.width)
                    guard let img = outlined(frame, m) else { throw EditorError(.io, "cannot draw the matte") }
                    images.append((Time(seconds: t), img))
                }
                let sheet = images.count == 1 ? images[0].1 : FrameCapture.sheet(images, columns: min(4, images.count))
                guard let sheet else { throw EditorError(.io, "cannot draw the sheet") }
                return try MediaTools.imageResult(sheet, time: images.count == 1 ? images[0].0 : nil, path: try args.string("path"))
            })
        return tools
    }

    /// The frame at matte size with both outlines drawn.
    static func outlined(_ frame: CGImage, _ m: (width: Int, height: Int, tight: [UInt8], wide: [UInt8])) -> CGImage? {
        let w = m.width, h = m.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        func edge(_ codes: [UInt8], _ x: Int, _ y: Int) -> Bool {
            let inside = codes[y * w + x] > 128
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, (codes[ny * w + nx] > 128) != inside { return true }
            }
            return false
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4   // bitmap memory runs top to bottom, like the matte
                if edge(m.wide, x, y) { px[i] = 255; px[i + 1] = 40; px[i + 2] = 40; px[i + 3] = 255 }
                if edge(m.tight, x, y) { px[i] = 40; px[i + 1] = 255; px[i + 2] = 40; px[i + 3] = 255 }
            }
        }
        return ctx.makeImage()
    }
}
