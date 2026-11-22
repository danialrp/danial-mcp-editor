import CoreGraphics
import EditorCore
import EditorKit
import Foundation
import ImageIO

/// Browser tools (B-2 to B-5): an agent drives the built-in browser that the
/// owner watches, and saves generated images into the project.
public enum BrowserTools {
    @Sendable static func url(_ s: String) throws -> URL {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: t.contains("://") || t.hasPrefix("about:") ? t : "https://" + t), u.host != nil || u.scheme == "about" else {
            throw EditorError.invalid("\(s) is not an address", parameter: "url")
        }
        return u
    }

    @MainActor static func state(_ host: BrowserHost) -> JSONValue {
        .object(["profile": host.profile.map { .string($0) } ?? .null, "layout": .string(host.layout.rawValue),
                 "url": host.webView?.url.map { .string($0.absoluteString) } ?? .null,
                 "title": host.webView?.title.map { .string($0) } ?? .null,
                 "profiles": .array(host.profiles.map { .string($0) })])
    }

    /// File type from the first bytes.
    static func imageExtension(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return "heic" }
        return nil
    }


    /// Writes a result into the project (images/), a composition's assets, or a folder.
    static func save(_ data: Data, suggested: String, editor: Editor, args: Args) async throws -> JSONValue {
        var folder: URL
        if let f = try args.string("folder") {
            folder = URL(fileURLWithPath: (f as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let session = try await editor.requireSession()
            folder = session.url.appendingPathComponent("images", isDirectory: true)
            if let comp = try args.string("composition") {
                let p = await session.project
                guard let a = p.media.first(where: { $0.id == EntityID(comp) && $0.isHyperFrames }) else {
                    throw EditorError(.notFound, "no HyperFrames composition \(comp)")
                }
                folder = session.url.appendingPathComponent(a.path, isDirectory: true).appendingPathComponent("assets", isDirectory: true)
            }
        }
        let ext = imageExtension(data) ?? ((suggested as NSString).pathExtension.isEmpty ? "bin" : (suggested as NSString).pathExtension)
        var base = (try args.string("name") ?? (suggested as NSString).deletingPathExtension)
            .replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.count > 80 { base = "result" }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) { file = folder.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1 }
        try data.write(to: file, options: .atomic)
        var o: [String: JSONValue] = ["saved": .string(file.path), "bytes": .number(Double(data.count))]
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            o["width"] = (props[kCGImagePropertyPixelWidth] as? Int).map { .number(Double($0)) } ?? .null
            o["height"] = (props[kCGImagePropertyPixelHeight] as? Int).map { .number(Double($0)) } ?? .null
        }
        // Into the media pool, so it can go on the timeline (clip.add).
        if try args.bool("addToPool") ?? (try args.string("composition") == nil), let session = await editor.session,
           AVMediaProber.stillInfo(file) != nil || ext == "mp4" || ext == "mov" {
            let info = try await editor.prober.probe(file)
            let asset = MediaAsset(id: .random("media"), path: file.path, name: file.lastPathComponent,
                                   fingerprint: try Editor.fingerprint(file), info: info,
                                   kind: info.video?.codec.hasPrefix("image/") == true ? .image : .file)
            _ = try await session.apply([AddMedia(assets: [asset])])
            o["mediaId"] = .string(asset.id.raw)
        }
        return .object(o)
    }

    public static func make(_ host: BrowserHost, jobs: JobCenter) -> [Tool] {
        var tools: [Tool] = []
        tools.append(Tool("browser.open", .manage, "Open the built-in browser in a profile (each keeps its own sign-ins) and show it in the sidebar or its own window, so the owner sees every step. Sign-in is the owner's; ask them to sign in when a page needs it.", [
                Parameter("profile", .string, "Profile name; default the default profile. A new name makes a new profile"),
                Parameter("layout", .oneOf(BrowserHost.Layout.allCases.map(\.rawValue)), "sidebar, window or hidden; default unchanged"),
                Parameter("url", .string, "Address to open; default the home page for a new session"),
            ]) { _, args in
                let target = try args.string("url").map(url)
                let layout = try args.string("layout").flatMap(BrowserHost.Layout.init(rawValue:))
                try await host.open(profile: try args.string("profile"), layout: layout, url: target)
                return await state(host)
            })
        tools.append(Tool("browser.close", .manage, "Hide the browser. The page and the sign-ins stay.") { _, _ in
                await host.close()
                return await state(host)
            })
        tools.append(Tool("browser.newSession", .manage, "A fresh page in the same profile: the sign-ins stay, the page and its history go. Use it to generate again from a clean start.", [
                Parameter("url", .string, "Address; default the home page"),
            ]) { _, args in
                try await host.newSession(url: try args.string("url").map(url))
                return await state(host)
            })
        tools.append(Tool("browser.navigate", .manage, "Go to an address, or back, forward or reload.", [
                Parameter("url", .string, "Address, or back, forward or reload", required: true),
            ]) { _, args in
                let to = try args.requiredString("url")
                if ["back", "forward", "reload"].contains(to) { try await host.go(to) } else { try await host.navigate(try url(to)) }
                return await state(host)
            })
        tools.append(Tool("browser.read", .read, "The page: address, title, its visible text, and its elements (buttons, fields, links, images) with references to act on. References stay the same while the element exists; read again after the page changes.", [
                Parameter("limit", .integer, "Most elements to list; default 300"),
                Parameter("textLimit", .integer, "Most characters of page text; default 4000"),
            ]) { _, args in
                try await host.read(limit: try args.int("limit") ?? 300, textLimit: try args.int("textLimit") ?? 4000)
            })
        tools.append(Tool("browser.html", .read, "The markup of an element (or the page body), shortened: for working out a page that browser.read does not explain.", [
                Parameter("ref", .string, "Element reference; default the body"),
                Parameter("limit", .integer, "Most characters; default 6000"),
            ]) { _, args in
                .object(["html": .string(try await host.html(try args.string("ref"), limit: try args.int("limit") ?? 6000))])
            })
        tools.append(Tool("browser.click", .manage, "Click an element by its reference.", [
                Parameter("ref", .string, "Element reference from browser.read", required: true),
                Parameter("trusted", .boolean, "Send a real mouse click, for pages that ignore scripted clicks"),
            ]) { _, args in
                try await host.click(try args.requiredString("ref"), trusted: try args.bool("trusted") ?? false)
                return await state(host)
            })
        tools.append(Tool("browser.type", .manage, "Type text into a field or editable area (a prompt box). Replaces what is there unless append. Never types into a password field.", [
                Parameter("ref", .string, "Element reference", required: true),
                Parameter("text", .string, "Text", required: true),
                Parameter("append", .boolean, "Add to what is there"),
                Parameter("submit", .boolean, "Press Return afterwards"),
                Parameter("keys", .boolean, "Type with real key presses, for pages that only accept what a person types"),
            ]) { _, args in
                try await host.type(try args.requiredString("ref"), text: try args.requiredString("text"),
                                    append: try args.bool("append") ?? false, submit: try args.bool("submit") ?? false,
                                    keys: try args.bool("keys") ?? false)
                return await state(host)
            })
        tools.append(Tool("browser.select", .manage, "Choose an option of a list element.", [
                Parameter("ref", .string, "Element reference", required: true),
                Parameter("option", .string, "Option text or value", required: true),
            ]) { _, args in
                try await host.select(try args.requiredString("ref"), option: try args.requiredString("option"))
                return await state(host)
            })
        tools.append(Tool("browser.key", .manage, "Press a key in the page: return, escape or tab.", [
                Parameter("key", .oneOf(["return", "escape", "tab"]), "Key", required: true),
            ]) { _, args in
                try await host.press(try args.requiredString("key"))
                return await state(host)
            })
        tools.append(Tool("browser.attachFiles", .manage, "Give files (input images) to the page: to a file field directly, through the file chooser a button or menu item opens (it is clicked for you), or with drop: true onto a drop area.", [
                Parameter("ref", .string, "Element reference: a file field, an upload button or a drop area", required: true),
                Parameter("files", .array(.string), "File paths", required: true),
                Parameter("drop", .boolean, "Drop the files on the element instead of opening its chooser"),
            ]) { _, args in
                let files = (args.values["files"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                try await host.attach(try args.requiredString("ref"), files: files, drop: try args.bool("drop") ?? false)
                return await state(host)
            })
        tools.append(Tool("browser.waitFor", .read, "Wait until text appears on the page, an element appears (or goes, with gone), or a download finishes.", [
                Parameter("text", .string, "Text to wait for"),
                Parameter("ref", .string, "Element reference to wait for"),
                Parameter("gone", .boolean, "Wait for the text or element to go instead"),
                Parameter("download", .boolean, "Wait for a download to finish"),
                Parameter("timeout", .seconds, "Most seconds to wait; default 60"),
            ]) { _, args in
                let text = try args.string("text"), ref = try args.string("ref"), download = try args.bool("download") ?? false
                guard text != nil || ref != nil || download else { throw EditorError.invalid("give text, ref or download") }
                let s = try await host.waitFor(text: text, ref: ref, gone: try args.bool("gone") ?? false, download: download,
                                               timeout: try args.double("timeout") ?? 60)
                return .object(["waited": .number(s)])
            })
        tools.append(Tool("browser.capture", .read, "An image of the visible page or of one element, to look at results.", [
                Parameter("ref", .string, "Element reference; default the visible page"),
                Parameter("path", .string, "Also save the PNG to this file"),
            ]) { _, args in
                let img = try await host.capture(try args.string("ref"))
                return try MediaTools.imageResult(img, time: nil, path: try args.string("path"))
            })
        tools.append(Tool("browser.listResults", .read, "Generated images on the page (large images, with references) and downloads.") { _, _ in
                try await host.results()
            })
        tools.append(Tool("browser.saveResult", .manage, "Save a result into the project (or a folder): a download (name) or an image on the page (ref). The image on a page can be a smaller preview (Gemini shows 1024 px, its download button gives 2048 px): for full size click the site's download button, wait for the download, then save it by name. It goes to the project's images folder, or into a HyperFrames composition's assets for a cover.", [
                Parameter("ref", .string, "Image reference from browser.listResults"),
                Parameter("download", .string, "Download name from browser.listResults"),
                Parameter("name", .string, "File name without extension; default from the source"),
                Parameter("composition", .id, "HyperFrames composition id: save into its assets folder"),
                Parameter("folder", .string, "Save into this folder instead (for example a post folder)"),
                Parameter("addToPool", .boolean, "Also add it to the media pool (mediaId in the result) so it can go on the timeline; default true unless saved into a composition"),
            ]) { editor, args in
                let (data, suggested) = try await host.resultData(ref: try args.string("ref"), download: try args.string("download"))
                return try await save(data, suggested: suggested, editor: editor, args: args)
            })
        tools.append(Tool("browser.generateImage", .manage, "Generate one image on the image site (Google AI Studio, Nano Banana Pro, 4K by default) as a job: a fresh session every time (one image per session keeps the site fast; a failed image is never revised in its chat: call this again with the whole improved prompt), the run settings, input images, the prompt typed and run like a person, and the full-size image saved into the project. When the site answers with an error it tries again in a fresh session by itself. Look at the saved file before using it.", [
                Parameter("prompt", .string, "The whole prompt", required: true),
                Parameter("files", .array(.string), "Input images to upload"),
                Parameter("aspectRatio", .string, "As the site lists it, for example 1:1, 9:16, 16:9, 4:5, 21:9"),
                Parameter("resolution", .string, "1K, 2K or 4K; default from settings (4K)"),
                Parameter("model", .string, "Model id; default from settings (gemini-3-pro-image)"),
                Parameter("options", .object, "Other run settings by label, for example {\"Thinking level\": \"High\"}"),
                Parameter("retries", .integer, "Tries after a site error; default from settings"),
                Parameter("timeout", .seconds, "Most seconds to wait per try; default 300"),
                Parameter("name", .string, "File name without extension"),
                Parameter("composition", .id, "HyperFrames composition id: save into its assets folder"),
                Parameter("folder", .string, "Save into this folder instead"),
                Parameter("addToPool", .boolean, "Also add the image to the media pool (mediaId in the result) so it can go on the timeline; default true unless saved into a composition"),
            ]) { editor, args in
                var r = BrowserHost.ImageRequest(prompt: try args.requiredString("prompt"))
                r.files = (args.values["files"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                for f in r.files where !FileManager.default.isReadableFile(atPath: f.path) { throw EditorError(.notFound, "cannot read \(f.path)") }
                r.model = try args.string("model")
                for (k, v) in args.values["options"]?.objectValue ?? [:] { if let s = v.stringValue { r.options[k] = s } }
                if let a = try args.string("aspectRatio") { r.options["Aspect ratio"] = a }
                if let res = try args.string("resolution") { r.options["Resolution"] = res }
                r.retries = try args.int("retries")
                r.timeout = try args.double("timeout") ?? 300
                let request = r
                let id = await jobs.start("image") { ctx in
                    let result = try await host.generateImage(request) { message in await ctx.progress(0.5, message) }
                    var saved = try await save(result.data, suggested: "image", editor: editor, args: args)
                    if case .object(var o) = saved {
                        o["seconds"] = .number(result.seconds)
                        o["tries"] = .number(Double(result.tries))
                        o["page"] = result.page.map { .string($0) } ?? .null
                        o["steps"] = .array(result.steps.map { .string($0) })
                        saved = .object(o)
                    }
                    return saved
                }
                return .object(["jobId": .string(id)])
            })
        return tools
    }
}
