import CoreGraphics
import EditorCore
import EditorKit
import Foundation
import ImageIO

/// HyperFrames tools (H-2): an agent builds, edits, checks, renders and
/// places a composition through these alone.
public enum HyperFramesTools {
    struct Ctx {
        var session: EditorSession
        var asset: MediaAsset
        var composition: HyperFramesHost.Composition
    }

    static func accentJSON(_ a: Accent) -> JSONValue {
        let r = { (v: Double) in JSONValue.number((v * 100).rounded() / 100) }
        return .object([
            "mode": .string(a.mode.rawValue), "stops": .array(a.used.map { .string($0) }), "angle": .number(a.angle),
            "hiPercent": .number(a.hiPercent), "acc": .string(a.acc), "acc2": .string(a.acc2), "accHi": .string(a.accHi),
            "ink": .string(a.ink), "inkContrast": r(a.inkContrast), "darkInkContrast": r(a.inkContrasts.dark),
            "whiteInkContrast": r(a.inkContrasts.white), "glassContrast": r(a.glassContrast),
            "readable": .bool(a.inkContrast >= 4.5), "css": .string(a.css),
        ])
    }

    static func context(_ editor: Editor, _ args: Args) async throws -> Ctx {
        let session = try await editor.requireSession()
        let id = EntityID(try args.requiredString("id"))
        let p = await session.project
        guard let a = p.media.first(where: { $0.id == id }), a.isHyperFrames else {
            let names = p.media.filter(\.isHyperFrames).map(\.id.raw)
            throw EditorError(.notFound, "no HyperFrames composition \(id); compositions: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        return Ctx(session: session, asset: a, composition: try HyperFramesHost.composition(a, package: session.url))
    }

    /// A path inside the composition folder, refusing anything that leaves it.
    static func file(_ c: Ctx, _ rel: String) throws -> URL {
        let clean = rel.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.hasPrefix("/"), !clean.split(separator: "/").contains("..") else {
            throw EditorError.invalid("path is relative to the composition folder, for example index.html or compositions/intro.html", parameter: "path")
        }
        return c.composition.folder.appendingPathComponent(clean)
    }

    static func sliceJSON(_ s: HyperFramesHost.Slice) -> JSONValue {
        .object(["index": .number(Double(s.index)), "start": .number(s.start), "end": .number(s.end),
                 "state": .string(s.current != nil ? "current" : s.stale != nil ? "stale" : "missing"),
                 "frames": .number(Double(s.frames))])
    }

    static func template(width: Int, height: Int, fps: Int, duration: Double) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=\(width), height=\(height)">
          <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: \(width)px; height: \(height)px; overflow: hidden; background: transparent; }
            #root { position: relative; width: \(width)px; height: \(height)px; overflow: hidden; }
            .clip { position: absolute; inset: 0; }
          </style>
        </head>
        <body>
          <div id="root" data-composition-id="main" data-start="0" data-duration="\(duration)" data-width="\(width)" data-height="\(height)" data-fps="\(fps)">
          </div>
          <script>
            const tl = gsap.timeline({ paused: true });
            window.__timelines = window.__timelines || {};
            window.__timelines["main"] = tl;
          </script>
        </body>
        </html>

        """
    }

    /// The asset's info from the composition's root element.
    static func info(_ root: HFDocument.Root) -> MediaInfo {
        MediaInfo(duration: Time(seconds: root.duration),
                  video: VideoInfo(width: root.width, height: root.height, frameRate: Double(root.fps), codec: "hyperframes"), audio: nil)
    }

    /// After index.html changed: size, frame rate or length go into the asset.
    static func refresh(_ c: Ctx) async throws -> JSONValue? {
        let fresh = try HyperFramesHost.composition(c.asset, package: c.session.url)
        let i = info(fresh.root)
        guard i != c.asset.info else { return nil }
        let r = try await c.session.apply([SetMediaPath(id: c.asset.id, path: c.asset.path, name: c.asset.name, fingerprint: c.asset.fingerprint, info: i)])
        return .number(Double(r.revision))
    }

    public static func make(_ media: MediaContext, jobs: JobCenter) -> [Tool] {
        let host = media.hyperframes
        var tools: [Tool] = []
        tools.append(Tool("hf.create", .write, "Create a HyperFrames composition inside the project (a folder with index.html, compositions/ and assets/) and add it to the media pool. Size and frame rate default to the project's.", [
                Parameter("name", .string, "Name", required: true),
                Parameter("duration", .seconds, "Length in seconds", required: true),
                Parameter("width", .integer, "Width; default the project canvas"),
                Parameter("height", .integer, "Height; default the project canvas"),
                Parameter("fps", .integer, "Frame rate; default the project's"),
                Parameter("id", .id, "Id for the composition; one is made if omitted"),
            ]) { editor, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let id = try args.string("id").map { EntityID($0) } ?? .random("hf")
                guard !p.containsID(id) else { throw EditorError(.conflict, "id \(id) is in use") }
                let duration = try args.double("duration")!
                guard duration > 0 else { throw EditorError.invalid("duration must be above 0", parameter: "duration") }
                let w = try args.int("width") ?? p.settings.width, h = try args.int("height") ?? p.settings.height
                let fps = try args.int("fps") ?? p.settings.frameRate.fps
                let rel = "hyperframes/\(id.raw)"
                let folder = session.url.appendingPathComponent(rel, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: folder.path) else { throw EditorError(.conflict, "folder \(rel) exists") }
                for sub in ["compositions", "assets"] {
                    try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
                }
                try template(width: w, height: h, fps: fps, duration: duration).write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                let root = HFDocument.Root(id: "main", width: w, height: h, fps: fps, duration: duration)
                let asset = MediaAsset(id: id, path: rel, name: try args.requiredString("name"), fingerprint: "", info: info(root), kind: .hyperframes)
                let r = try await session.apply([AddMedia(assets: [asset])])
                return .object(["id": .string(id.raw), "folder": .string(folder.path), "revision": .number(Double(r.revision))])
            })
        tools.append(Tool("hf.list", .read, "HyperFrames compositions in the project: size, frame rate, length, folder and how many slices are rendered.") { editor, _ in
                let session = try await editor.requireSession()
                let p = await session.project
                var out: [JSONValue] = []
                for a in p.media where a.isHyperFrames {
                    var o: [String: JSONValue] = ["id": .string(a.id.raw), "name": .string(a.name),
                                                  "folder": .string(session.url.appendingPathComponent(a.path).path)]
                    if let c = try? HyperFramesHost.composition(a, package: session.url) {
                        o["width"] = .number(Double(c.root.width)); o["height"] = .number(Double(c.root.height))
                        o["fps"] = .number(Double(c.root.fps)); o["duration"] = .number(c.root.duration)
                        if let s = try? await host.slices(c, project: p.id) {
                            o["slices"] = .object(["total": .number(Double(s.count)),
                                                   "current": .number(Double(s.filter { $0.current != nil }.count))])
                        }
                    }
                    out.append(.object(o))
                }
                return .object(["compositions": .array(out)])
            })
        tools.append(Tool("hf.get", .read, "One composition: its files, root settings, sub-compositions with their times, and its slices.", [
                Parameter("id", .id, "Composition id", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                let folder = c.composition.folder
                let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?.allObjects as? [URL] ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .map { u -> JSONValue in
                        let rel = String(u.resolvingSymlinksInPath().path.dropFirst(folder.resolvingSymlinksInPath().path.count + 1))
                        return .object(["path": .string(rel), "bytes": .number(Double((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))])
                    }
                let html = (try? String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
                let p = await c.session.project
                return .object([
                    "id": .string(c.asset.id.raw), "folder": .string(folder.path),
                    "root": .object(["width": .number(Double(c.composition.root.width)), "height": .number(Double(c.composition.root.height)),
                                     "fps": .number(Double(c.composition.root.fps)), "duration": .number(c.composition.root.duration)]),
                    "subCompositions": .array(HFDocument.hosts(html).map { .object(["id": .string($0.id), "src": .string($0.src), "start": .number($0.start),
                                                                                    "end": $0.end.isFinite ? .number($0.end) : .null]) }),
                    "files": .array(files),
                    "slices": .array(try await host.slices(c.composition, project: p.id).map(sliceJSON)),
                ])
            })
        tools.append(Tool("hf.readFile", .read, "Read a file of a composition.", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("path", .string, "Path inside the composition folder, for example index.html", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                let url = try file(c, try args.requiredString("path"))
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw EditorError(.notFound, "no text file \(try args.requiredString("path"))") }
                return .object(["path": .string(try args.requiredString("path")), "content": .string(text)])
            })
        tools.append(Tool("hf.writeFile", .manage, "Write a file of a composition (HTML, CSS, JS, or a text asset). Only the slices whose frames depend on it go stale. A change to index.html's size, frame rate or length updates the media pool.", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("path", .string, "Path inside the composition folder", required: true),
                Parameter("content", .string, "Text of the file", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                let url = try file(c, try args.requiredString("path"))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(try args.requiredString("content").utf8).write(to: url, options: .atomic)
                var o: [String: JSONValue] = ["written": .string(url.path)]
                if url.lastPathComponent == "index.html", url.deletingLastPathComponent().path == c.composition.folder.path,
                   let rev = try await refresh(c) { o["revision"] = rev }
                let p = await c.session.project
                let slices = try await host.slices(try HyperFramesHost.composition(c.asset, package: c.session.url), project: p.id)
                o["staleSlices"] = .array(slices.filter { $0.current == nil }.map { .number(Double($0.index)) })
                await media.invalidate()
                return .object(o)
            })
        tools.append(Tool("hf.removeFile", .manage, "Move a file of a composition to the Trash.", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("path", .string, "Path inside the composition folder", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                let url = try file(c, try args.requiredString("path"))
                guard url.lastPathComponent != "index.html" || url.deletingLastPathComponent().path != c.composition.folder.path else {
                    throw EditorError.invalid("index.html is the composition itself; remove the composition from the media pool instead", parameter: "path")
                }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                await media.invalidate()
                return .object(["trashed": .string(url.path)])
            })
        tools.append(Tool("hf.refresh", .write, "Read index.html again after it was edited on disk: size, frame rate and length go into the media pool.", [
                Parameter("id", .id, "Composition id", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                await media.invalidate()
                return .object(["revision": try await refresh(c) ?? .null])
            })
        tools.append(Tool("accent.get", .read, "The project's accent colour for motion graphics as the owner picked it (project.setAccent, or the Accent panel in the app): mode, stops, angle, the derived --acc, --acc2, --acc-hi and --acc-ink, contrast of the ink and on the dark glass (4.5 or more reads well), and the CSS block. Never choose a colour yourself; when there is none, ask the owner to pick one in the Accent panel.") { editor, _ in
                let p = await (try await editor.requireSession()).project
                guard let a = p.accent else { return .object(["accent": .null]) }
                return Self.accentJSON(a)
            })
        tools.append(Tool("accent.writeCSS", .manage, "Write the project's accent as CSS variables into a composition: accent.css with :root { --acc ... } (link it from index.html, or the kit css can import it). Slices that use it render again.", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("path", .string, "File inside the composition; default accent.css"),
            ]) { editor, args in
                let c = try await context(editor, args)
                guard let a = await c.session.project.accent else {
                    throw EditorError(.notFound, "the project has no accent yet; the owner picks it in the Accent panel")
                }
                let url = try file(c, try args.string("path") ?? "accent.css")
                try Data(":root {\n  \(a.css.replacingOccurrences(of: "\n", with: "\n  "))\n}\n".utf8).write(to: url, options: .atomic)
                await media.invalidate()
                return .object(["written": .string(url.path), "css": .string(a.css)])
            })
        tools.append(Tool("accent.export", .manage, "Write the accent as the hyperframes skill's accent_pick.json (mode, stops, angle, hi_pct, acc, acc2, acc_hi, acc_ink, contrasts, css), for the skill's flow.", [
                Parameter("path", .string, "File to write, for example accent/accent_pick.json", required: true),
            ]) { editor, args in
                let p = await (try await editor.requireSession()).project
                guard let a = p.accent else { throw EditorError(.notFound, "the project has no accent yet; the owner picks it in the Accent panel") }
                let url = URL(fileURLWithPath: (try args.requiredString("path") as NSString).expandingTildeInPath)
                let o: [String: JSONValue] = [
                    "mode": .string(a.mode == .gradient ? "grad" : "solid"), "stops": .array(a.used.map { .string($0) }),
                    "angle": a.mode == .gradient ? .number(a.angle) : .null, "hi_pct": .number(a.hiPercent),
                    "acc": .string(a.acc), "acc2": .string(a.acc2), "acc_hi": .string(a.accHi), "acc_ink": .string(a.ink),
                    "ink_contrast": .number((a.inkContrast * 100).rounded() / 100), "glass_contrast": .number((a.glassContrast * 100).rounded() / 100),
                    "css": .string(a.css),
                ]
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(JSONValue.object(o)).write(to: url, options: .atomic)
                return .object(["written": .string(url.path)])
            })
        tools.append(Tool("hf.check", .read, "HyperFrames lint of a composition: errors and warnings.", [
                Parameter("id", .id, "Composition id", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                let r = try await HyperFramesHost.run(editor.settings.current.hyperframes.command + ["lint", c.composition.folder.path],
                                                      env: ["HYPERFRAMES_SKIP_SKILLS": "1", "HYPERFRAMES_NO_TELEMETRY": "1", "DO_NOT_TRACK": "1"], timeout: 600)
                return .object(["ok": .bool(r.status == 0), "output": .string(Self.plain(r.output))])
            })
        tools.append(Tool("hf.snapshot", .read, "A frame of a composition at a time, as an image, rendered by HyperFrames (with transparency).", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("time", .seconds, "Time in the composition", required: true),
                Parameter("path", .string, "Also save the PNG to this file"),
            ]) { editor, args in
                let c = try await context(editor, args)
                let t = try args.double("time")!
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("dme-hfsnap-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: out) }   // the snapshot's own temporary folder
                let r = try await HyperFramesHost.run(editor.settings.current.hyperframes.command
                    + ["snapshot", c.composition.folder.path, "--at", String(t), "--no-end", "-o", out.path],
                    env: ["HYPERFRAMES_SKIP_SKILLS": "1", "HYPERFRAMES_NO_TELEMETRY": "1", "DO_NOT_TRACK": "1"], timeout: 600)
                let png = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "png" }
                guard r.status == 0, let png, let src = CGImageSourceCreateWithURL(png as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    throw EditorError(.io, "HyperFrames snapshot failed: \(Self.plain(r.output).suffix(600))")
                }
                return try MediaTools.imageResult(img, time: Time(seconds: t), path: try args.string("path"))
            })
        tools.append(Tool("hf.place", .write, "Put a composition on the timeline as a layer, usually on an overlay track above the footage. In the window the layer is view-only; change it through its files.", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("track", .id, "Track id (an overlay track)", required: true),
                Parameter("start", .seconds, "Timeline time; default the end of the track"),
                Parameter("from", .seconds, "Composition time to start from; default 0"),
                Parameter("duration", .seconds, "How much of the composition; default the rest of it"),
                Parameter("clip", .id, "Id for the new clip; one is made if omitted"),
            ] + ToolCatalog.writeOptions) { editor, args in
                let c = try await context(editor, args)
                let cmd = AddClip(track: EntityID(try args.requiredString("track")), asset: c.asset.id, start: try args.time("start"),
                                  sourceStart: try args.time("from"), sourceDuration: try args.time("duration"),
                                  id: try args.string("clip").map { EntityID($0) })
                let r = try await c.session.apply([cmd], ifRevision: try args.int("ifRevision"), dryRun: try args.bool("dryRun") ?? false)
                return try JSONValue(encoding: r)
            })
        tools.append(Tool("hf.render", .manage, "Render the slices of a composition that are not current, as a job; the timeline picks each up when done. Only slices whose files changed render again (H-4).", [
                Parameter("id", .id, "Composition id", required: true),
                Parameter("slices", .array(.integer), "Only these slice indexes"),
            ]) { editor, args in
                let c = try await context(editor, args)
                let p = await c.session.project
                let only = try args.values["slices"]?.arrayValue.map { Set($0.compactMap { $0.doubleValue.map { Int($0) } }) }
                let comp = c.composition
                let id = await jobs.start("hyperframes") { ctx in
                    let done = try await host.render(comp, project: p.id, only: only) { n, total, message in
                        try ctx.checkCancelled()
                        await ctx.progress(Double(n) / Double(max(1, total)), message)
                    }
                    await media.invalidate()
                    return .object(["rendered": .array(done.map { .number(Double($0)) })])
                }
                return .object(["jobId": .string(id)])
            })
        tools.append(Tool("hf.status", .read, "The slices of a composition: time range and whether each is current, stale (an older render plays until it is redone) or missing.", [
                Parameter("id", .id, "Composition id", required: true),
            ]) { editor, args in
                let c = try await context(editor, args)
                let p = await c.session.project
                return .object(["slices": .array(try await host.slices(c.composition, project: p.id).map(sliceJSON))])
            })
        return tools
    }

    /// Command output without terminal colour codes.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
