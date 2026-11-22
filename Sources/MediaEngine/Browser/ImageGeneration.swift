import AppKit
import EditorCore
import EditorKit
import Foundation

/// One image from the image site (Google AI Studio by default), the way the
/// owner works (B-2, B-3): a fresh session for every image, so the site
/// stays fast and a failed image is never revised in its own chat; the next
/// try starts clean with the whole prompt. When the site answers with an
/// error, which Google's image models often do, the same request runs again
/// in a fresh session, up to `retries` times. The site's controls come from
/// `browser.imageSite`.
extension BrowserHost {
    public struct ImageRequest: Sendable {
        public var prompt: String
        public var files: [URL] = []
        /// Model id, for example gemini-3-pro-image; default from settings.
        public var model: String?
        /// Run settings by their label, for example "Aspect ratio": "9:16",
        /// "Resolution": "4K". Settings not given keep their defaults.
        public var options: [String: String] = [:]
        public var timeout: Double = 300
        public var retries: Int?

        public init(prompt: String) { self.prompt = prompt }
    }

    public struct ImageResult: Sendable {
        public var data: Data
        public var width: Int
        public var height: Int
        public var seconds: Double
        public var tries: Int
        public var page: String?
        public var steps: [String]
    }

    struct Element {
        var ref: String
        var role: String
        var name: String
        var checked: Bool
        var value: String?
        var size: [Int]?
    }

    func elements() async throws -> [Element] {
        let r = try await read(limit: 3000, textLimit: 0)
        return (r.objectValue?["elements"]?.arrayValue ?? []).compactMap { v in
            guard let o = v.objectValue, let ref = o["ref"]?.stringValue else { return nil }
            return Element(ref: ref, role: o["role"]?.stringValue ?? "", name: o["name"]?.stringValue ?? "",
                           checked: o["checked"]?.boolValue ?? false, value: o["value"]?.stringValue,
                           size: o["size"]?.arrayValue?.compactMap { $0.doubleValue.map { Int($0) } })
        }
    }

    /// The first element matching, waiting for it a moment.
    func element(within seconds: Double = 10, _ what: String, _ match: @escaping (Element) -> Bool) async throws -> Element {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let e = try await elements().first(where: match) { return e }
            try await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < end
        throw EditorError(.notFound, "no \(what) on the page; the site may have changed: read it and update browser.imageSite")
    }

    /// Sets a run setting (a list) to the option with that exact name.
    func setOption(_ label: String, _ option: String) async throws {
        let box = try await element("setting \(label)") { $0.name.lowercased() == label.lowercased() && ["combobox", "listbox", "button"].contains($0.role) }
        try await click(box.ref)
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            let opts = try await elements().filter { $0.role == "option" || $0.role == "menuitemradio" }
            if let o = opts.first(where: { $0.name.lowercased() == option.lowercased() }) {
                try await click(o.ref)
                return
            }
            if !opts.isEmpty {
                try? await press("escape")
                throw EditorError.invalid("\(label) has no option \(option); options: \(opts.map(\.name).joined(separator: ", "))")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw EditorError(.notFound, "the list \(label) did not open")
    }

    /// The page text, to spot the site's error messages.
    func pageText() async throws -> String {
        try await read(limit: 0, textLimit: 20_000).objectValue?["text"]?.stringValue ?? ""
    }

    public func generateImage(_ r: ImageRequest, progress: @escaping @Sendable (String) async -> Void) async throws -> ImageResult {
        let site = settings.current.browser.imageSite
        let tries = max(1, (r.retries ?? site.retries) + 1)
        let t0 = Date()
        var steps: [String] = []
        var lastError = ""
        for attempt in 1...tries {
            do {
                if attempt > 1 {
                    // Errors that come back to back are often the site throttling:
                    // wait longer before each new try.
                    let waits = site.retryWaitSeconds
                    let wait = waits.isEmpty ? 0 : waits[min(attempt - 2, waits.count - 1)]
                    await progress("try \(attempt) of \(tries) in \(Int(wait)) s after: \(lastError)")
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                }
                var result = try await generateOnce(r, site: site, steps: &steps, progress: progress)
                result.seconds = Date().timeIntervalSince(t0)
                result.tries = attempt
                return result
            } catch let e as SiteError {
                lastError = e.message
                steps.append("try \(attempt): \(e.message)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A page that did not load or a control that did not show up:
                // also worth a fresh try.
                lastError = (error as? EditorError)?.message ?? error.localizedDescription
                steps.append("try \(attempt): \(lastError)")
            }
        }
        throw EditorError(.conflict, "the site failed \(tries) times; last: \(lastError). Steps: \(steps.joined(separator: "; "))")
    }

    /// The site's own failure for one try: worth trying again.
    struct SiteError: Error { var message: String }

    private func generateOnce(_ r: ImageRequest, site: UserSettings.ImageSiteRecipe, steps: inout [String],
                              progress: @escaping @Sendable (String) async -> Void) async throws -> ImageResult {
        let model = r.model ?? site.model
        guard let url = URL(string: site.url.replacingOccurrences(of: "{model}", with: model)) else {
            throw EditorError.invalid("browser.imageSite.url is not an address")
        }
        if webView == nil { try await open(profile: nil, layout: nil, url: nil) }
        // Always a fresh session: one image per session (see the type's note).
        try await newSession(url: url)
        steps.append("fresh session, model \(model)")
        await progress("session open")
        let prompt = try await element(within: 30, "prompt box") { $0.name.lowercased().hasPrefix(site.prompt.lowercased()) }

        var options = site.defaults
        for (k, v) in r.options { options[k] = v }
        for (label, option) in options.sorted(by: { $0.key < $1.key }) {
            try await setOption(label, option)
            steps.append("\(label): \(option)")
        }
        if !r.files.isEmpty {
            let insert = try await element("insert button") { $0.role == "button" && $0.name.lowercased().hasPrefix(site.insert.lowercased()) }
            try await click(insert.ref, trusted: true)
            let upload = try await element("upload item") { $0.name.lowercased().hasPrefix(site.upload.lowercased()) }
            try await attach(upload.ref, files: r.files)
            steps.append("attached \(r.files.map(\.lastPathComponent).joined(separator: ", "))")
            try await Task.sleep(nanoseconds: 2_000_000_000)   // let the uploads finish
        }
        await progress("options set")

        // Images already on the page (the inputs) are not the result.
        let before = Set(try await elements().filter { $0.role == "img" }.map(\.ref))
        // The site only accepts what a person types and clicks.
        try await type(prompt.ref, text: r.prompt, keys: true)
        let run = try await element("run button") { $0.role == "button" && $0.name.lowercased().hasPrefix(site.run.lowercased()) }
        try await click(run.ref, trusted: true)
        steps.append("run")
        await progress("generating")

        // Done when the site has stopped working (draft images it shows
        // while thinking are not the result) and a generated image is there.
        let started = Date()
        let end = started.addingTimeInterval(r.timeout)
        var sawBusy = false
        var idleSince: Date?
        while Date() < end {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let els = try await elements()
            let busy = els.contains { $0.role == "button" && $0.name.localizedCaseInsensitiveContains(site.busy) }
            sawBusy = sawBusy || busy
            let text = try await pageText()
            if let e = site.errors.first(where: { text.localizedCaseInsensitiveContains($0) }) {
                throw SiteError(message: e)
            }
            guard !busy, sawBusy || Date().timeIntervalSince(started) > 10 else { continue }
            let images = els.filter { $0.role == "img" && !before.contains($0.ref) && ($0.size?.max() ?? 0) >= site.minResultSize
                && (site.resultName.isEmpty || $0.name.hasPrefix(site.resultName)) }
            if let best = images.max(by: { ($0.size?.reduce(1, *) ?? 0) < ($1.size?.reduce(1, *) ?? 0) }) {
                await progress("saving")
                let (data, _) = try await resultData(ref: best.ref, download: nil)
                steps.append("image \(best.size?.map(String.init).joined(separator: "x") ?? "")")
                return ImageResult(data: data, width: best.size?.first ?? 0, height: best.size?.last ?? 0, seconds: 0, tries: 1,
                                   page: webView?.url?.absoluteString, steps: steps)
            }
            // The model can finish before a large picture has loaded on the
            // page: wait for it a while before calling it a failure.
            if sawBusy {
                idleSince = idleSince ?? Date()
                if Date().timeIntervalSince(idleSince!) > site.resultWaitSeconds {
                    throw SiteError(message: "the site finished without an image")
                }
            }
        }
        throw SiteError(message: "no image after \(Int(r.timeout)) s")
    }
}
