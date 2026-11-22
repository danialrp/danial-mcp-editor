import AVFoundation
import CryptoKit
import EditorCore
import EditorKit
import Foundation
import VideoToolbox

/// Renders HyperFrames compositions in slices and keeps them (H-1, H-4).
///
/// Each slice of a composition is cached under a hash of exactly what its
/// frames depend on: the root page, the sub-compositions it shows during the
/// slice, every other file of the folder (styles, scripts, fonts, images),
/// the HyperFrames version and the render settings. Editing a
/// sub-composition changes only the slices that show it, and only those are
/// rendered again. Slices are rendered by the HyperFrames command line
/// (headless Chrome, chosen in test 5), as ProRes 4444, then stored as HEVC
/// with alpha, which plays in hardware and is small.
public actor HyperFramesHost {
    public struct Slice: Sendable {
        public var index: Int
        public var start: Double
        public var end: Double
        public var hash: String
        /// The render for the current hash, if done.
        public var current: URL?
        /// An older render of the same slice, played until the current one exists.
        public var stale: URL?
        public var frames: Int
    }

    public struct Composition: Sendable {
        public var asset: EntityID
        public var folder: URL
        public var root: HFDocument.Root
        /// Rendered in two passes (`#back`, `#front`), stacked in each slice
        /// file: the back pass on top, the front pass below.
        public var depth = false
        /// When the person's outline is lit (composition seconds).
        public var edges: [ClosedRange<Double>] = []
    }

    let settings: UserSettingsStore
    private var version: String?
    private var rendering: Set<String> = []
    /// Called after slices were rendered, so the player can pick them up.
    public var onChange: (@Sendable () async -> Void)?

    public init(settings: UserSettingsStore) { self.settings = settings }

    public func setOnChange(_ f: @escaping @Sendable () async -> Void) { onChange = f }

    static let engineVersion = "hf-slices-2"

    public static func cacheFolder(project: EntityID, asset: EntityID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor/hyperframes/\(project.raw)/\(asset.raw)", isDirectory: true)
    }

    // MARK: reading

    public static func composition(_ a: MediaAsset, package: URL) throws -> Composition {
        let folder = package.appendingPathComponent(a.path, isDirectory: true)
        let index = folder.appendingPathComponent("index.html")
        guard let html = try? String(contentsOf: index, encoding: .utf8) else {
            throw EditorError(.notFound, "composition \(a.id) has no index.html at \(index.path)")
        }
        guard let root = HFDocument.root(html) else {
            throw EditorError.invalid("index.html of \(a.id) has no root element with data-composition-id")
        }
        return Composition(asset: a.id, folder: folder, root: root, depth: HFDocument.isDepth(html), edges: HFDocument.edges(html))
    }

    /// The HyperFrames version the command runs, asked once.
    func hfVersion() async -> String {
        if let version { return version }
        let r = (try? await Self.run(settings.current.hyperframes.command + ["--version"], timeout: 300))?.output ?? "unknown"
        let v = r.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
        version = v
        return v
    }

    /// Slices of a composition with their hashes and renders.
    public func slices(_ c: Composition, project: EntityID) async throws -> [Slice] {
        let hf = settings.current.hyperframes
        let fps = Double(c.root.fps)
        let total = (c.root.duration * fps).rounded() / fps
        let length = max(1 / fps, (hf.sliceSeconds * fps).rounded() / fps)
        let html = try String(contentsOf: c.folder.appendingPathComponent("index.html"), encoding: .utf8)
        let hosts = HFDocument.hosts(html)
        let shared = try sharedDigest(c.folder, hosted: Set(hosts.map(\.src)))
        let base = "\(Self.engineVersion)|\(await hfVersion())|\(c.root.width)x\(c.root.height)@\(c.root.fps)|\(hf.quality)|\(hf.sliceQuality)|\(c.depth ? "depth" : "flat")|" + shared
            + "|" + Self.digest(Data(html.utf8))
        var subDigest: [String: String] = [:]
        for h in hosts where subDigest[h.src] == nil {
            subDigest[h.src] = Self.digest((try? Data(contentsOf: c.folder.appendingPathComponent(h.src))) ?? Data())
        }
        let cache = Self.cacheFolder(project: project, asset: c.asset)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        var out: [Slice] = []
        var s0 = 0.0, k = 0
        while s0 < total - 1e-9 {
            let s1 = min(total, s0 + length)
            var key = base + "|\(Self.num(s0))-\(Self.num(s1))"
            for h in hosts where h.start < s1 && h.end > s0 { key += "|\(h.src)@\(h.start):\(subDigest[h.src] ?? "")" }
            let hash = Self.digest(Data(key.utf8))
            let name = String(format: "%04d-", k) + hash.prefix(24) + ".mov"
            let older = files.filter { $0.hasPrefix(String(format: "%04d-", k)) && $0 != name && $0.hasSuffix(".mov") }.sorted().last
            out.append(Slice(index: k, start: s0, end: s1, hash: String(hash.prefix(24)),
                             current: files.contains(name) ? cache.appendingPathComponent(name) : nil,
                             stale: older.map { cache.appendingPathComponent($0) },
                             frames: Int(((s1 - s0) * fps).rounded())))
            s0 = s1
            k += 1
        }
        return out
    }

    /// Digest of the folder's files other than index.html and the hosted
    /// sub-compositions. Large files count by size and date, small ones by content.
    func sharedDigest(_ given: URL, hosted: Set<String>) throws -> String {
        // Resolved, so paths below it compare equal (/var is /private/var).
        let folder = given.resolvingSymlinksInPath()
        let skip: Set<String> = [".hyperframes", "renders", "work", ".git", "node_modules"]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return "" }
        var parts: [String] = []
        for case let url as URL in e {
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(folder.path.count + 1))
            if let first = rel.split(separator: "/").first, skip.contains(String(first)) || first.hasPrefix(".") { e.skipDescendants(); continue }
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard v.isRegularFile == true, rel != "index.html", !hosted.contains(rel) else { continue }
            let size = v.fileSize ?? 0
            if size < 2_000_000, let d = try? Data(contentsOf: url) { parts.append("\(rel):\(Self.digest(d))") }
            else { parts.append("\(rel):\(size):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)") }
        }
        return Self.digest(Data(parts.sorted().joined(separator: "\n").utf8))
    }

    static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func num(_ v: Double) -> String { String(format: "%.6f", v) }

    // MARK: rendering

    /// Renders the slices that have no current render (or only `only`).
    /// Returns the indexes rendered.
    public func render(_ c: Composition, project: EntityID, only: Set<Int>? = nil,
                       progress: @escaping @Sendable (Int, Int, String) async throws -> Void) async throws -> [Int] {
        let all = try await slices(c, project: project)
        let todo = all.filter { s in (only.map { $0.contains(s.index) } ?? true) && s.current == nil }
        let key = "\(project.raw)/\(c.asset.raw)"
        guard !rendering.contains(key) else { throw EditorError(.conflict, "composition \(c.asset) is already rendering") }
        rendering.insert(key)
        defer { rendering.remove(key) }
        let hf = settings.current.hyperframes
        let cache = Self.cacheFolder(project: project, asset: c.asset)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("work"), withIntermediateDirectories: true)
        let parallel = max(1, hf.parallelSlices)
        let total = todo.count
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let s = todo[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    // The HyperFrames renderer (a headless Chrome) fails now and
                    // then for no reason in the composition: try again.
                    var attempt = 0
                    while true {
                        do {
                            try await Self.renderSlice(c, s, settings: hf, parallel: parallel > 1, cache: cache)
                            break
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            attempt += 1
                            if attempt > max(0, hf.retries) { throw error }
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                    }
                    let n = await counter.add()
                    try await progress(n, total, "slice \(s.index + 1) (\(Self.num(s.start))-\(Self.num(s.end)) s) rendered")
                }
            }
            for _ in 0..<min(parallel, todo.count) { launch() }
            while try await group.next() != nil { if next < todo.count { launch() } }
        }
        if !todo.isEmpty { await onChange?() }
        return todo.map(\.index)
    }

    private actor Counter {
        var n = 0
        func add() -> Int { n += 1; return n }
    }

    /// One slice: a shifted copy of the composition, rendered by HyperFrames
    /// with alpha, checked for its frame count and stored as HEVC with alpha.
    static func renderSlice(_ c: Composition, _ s: Slice, settings hf: UserSettings.HyperFramesSettings,
                            parallel: Bool, cache: URL) async throws {
        let work = cache.appendingPathComponent("work/\(String(format: "%04d", s.index))-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }   // render intermediates: the copies and the ProRes files
        var env = ["HYPERFRAMES_SKIP_SKILLS": "1", "HYPERFRAMES_NO_TELEMETRY": "1", "DO_NOT_TRACK": "1"]
        if parallel { env["HYPERFRAMES_RENDER_LOCK"] = "off" }
        var renders: [URL] = []
        for pass in c.depth ? ["back", "front"] : [nil] {
            let dir = work.appendingPathComponent(pass ?? "page", isDirectory: true)
            try makeSliceCopy(c, s, into: dir, pass: pass)
            let prores = work.appendingPathComponent("\(pass ?? "page").mov")
            let r = try await run(hf.command + ["render", dir.path, "--format", "mov", "--fps", String(c.root.fps), "-q", hf.quality,
                                                "--workers", "1", "--quiet", "-o", prores.path], env: env, timeout: 3600)
            guard r.status == 0, FileManager.default.fileExists(atPath: prores.path) else {
                throw EditorError(.io, "HyperFrames could not render slice \(s.index)\(pass.map { " (\($0) pass)" } ?? ""): \(r.output.suffix(800))")
            }
            renders.append(prores)
        }
        let tmp = cache.appendingPathComponent("work/\(UUID().uuidString).mov")
        let n = try await encodeAlpha(renders, to: tmp, quality: hf.sliceQuality, fps: c.root.fps)
        guard n == s.frames else {
            throw EditorError(.io, "slice \(s.index) came out with \(n) frames instead of \(s.frames)")
        }
        try FileManager.default.moveItem(at: tmp, to: cache.appendingPathComponent(String(format: "%04d-", s.index) + s.hash + ".mov"))
    }

    /// Writes the slice copy: index.html and the sub-compositions it shows
    /// are rewritten, everything else is linked.
    static func makeSliceCopy(_ c: Composition, _ s: Slice, into dir: URL, pass: String? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = try String(contentsOf: c.folder.appendingPathComponent("index.html"), encoding: .utf8)
        let hosts = HFDocument.hosts(html)
        let rewritten = Set(hosts.map(\.src))
        for name in try fm.contentsOfDirectory(atPath: c.folder.path) where name != "index.html" && !name.hasPrefix(".")
            && !["renders", "work", "node_modules"].contains(name) {
            let src = c.folder.appendingPathComponent(name)
            if rewritten.contains(where: { $0.hasPrefix(name + "/") }) {
                // A folder holding sub-compositions: rebuild it with links.
                try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
                for f in try fm.contentsOfDirectory(atPath: src.path) where !rewritten.contains("\(name)/\(f)") {
                    try fm.createSymbolicLink(at: dir.appendingPathComponent("\(name)/\(f)"), withDestinationURL: src.appendingPathComponent(f))
                }
            } else {
                try fm.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: src)
            }
        }
        let dur = s.end - s.start
        var page = HFDocument.withoutFootagePreview(HFDocument.shifted(html, offset: s.start, duration: dur))
        if let pass { page = HFDocument.forPass(page, pass) }
        try page.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        for h in hosts {
            let target = dir.appendingPathComponent(h.src)
            guard !fm.fileExists(atPath: target.path), let sub = try? String(contentsOf: c.folder.appendingPathComponent(h.src), encoding: .utf8) else { continue }
            let a = max(h.start, s.start), b = min(h.end, s.end)
            let text: String
            if b > a {
                text = HFDocument.shifted(sub, offset: max(0, s.start - h.start), duration: b - a, rootStart: a - s.start)
            } else {
                text = sub   // not shown in this slice; the host is moved past the end
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    /// ProRes 4444 to HEVC with alpha, in hardware. Several renders of the
    /// same length are stacked top to bottom in one picture. Returns the
    /// frame count.
    static func encodeAlpha(_ sources: [URL], to dst: URL, quality: Double, fps: Int) async throws -> Int {
        var readers: [(AVAssetReader, AVAssetReaderTrackOutput)] = []
        var size = CGSize.zero
        for src in sources {
            let asset = AVURLAsset(url: src)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError(.io, "the HyperFrames render has no picture") }
            size = try await track.load(.naturalSize)
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { throw EditorError(.io, "cannot read the HyperFrames render") }
            readers.append((reader, out))
        }
        let w = Int(size.width), h = Int(size.height), parts = readers.count
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: w, AVVideoHeightKey: h * parts,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: quality,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h * parts,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw EditorError(.io, "cannot convert the HyperFrames render") }
        writer.startSession(atSourceTime: .zero)
        var frames = 0
        while true {
            try Task.checkCancellation()
            let samples = readers.map { $0.1.copyNextSampleBuffer() }
            guard let first = samples.first, let first else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            var out: CVPixelBuffer?
            if parts == 1, let pb = CMSampleBufferGetImageBuffer(first) {
                out = pb
            } else {
                if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
                guard let out else { throw EditorError(.io, "out of memory for the slice") }
                CVPixelBufferLockBaseAddress(out, [])
                let dst = CVPixelBufferGetBaseAddress(out)!, dbpr = CVPixelBufferGetBytesPerRow(out)
                for (k, sb) in samples.enumerated() {
                    guard let sb, let pb = CMSampleBufferGetImageBuffer(sb) else {
                        CVPixelBufferUnlockBaseAddress(out, [])
                        throw EditorError(.io, "the passes of a slice differ in length")
                    }
                    CVPixelBufferLockBaseAddress(pb, .readOnly)
                    let src = CVPixelBufferGetBaseAddress(pb)!, sbpr = CVPixelBufferGetBytesPerRow(pb)
                    for y in 0..<h { memcpy(dst + (k * h + y) * dbpr, src + y * sbpr, min(dbpr, sbpr)) }
                    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                }
                CVPixelBufferUnlockBaseAddress(out, [])
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard adaptor.append(out!, withPresentationTime: pts) else { throw EditorError(.io, "slice not written: \(writer.error?.localizedDescription ?? "")") }
            frames += 1
        }
        for (reader, _) in readers where reader.status == .failed {
            throw EditorError(.io, "reading the render failed: \(reader.error?.localizedDescription ?? "")")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw EditorError(.io, "slice not written: \(writer.error?.localizedDescription ?? "")") }
        return frames
    }

    // MARK: running the command line

    struct RunResult: Sendable { var status: Int32; var output: String }

    /// Runs a program with a login shell's PATH (npx lives under Homebrew).
    static func run(_ argv: [String], env extra: [String: String] = [:], timeout: Double) async throws -> RunResult {
        guard let first = argv.first else { throw EditorError.invalid("settings.hyperframes.command is empty") }
        let p = Process()
        if first.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: first)
            p.arguments = Array(argv.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
        }
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)).joined(separator: ":")
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let collected = Unchecked(NSMutableData())
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collected.value.append(d) }
        }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Task.isCancelled || Date() > deadline { p.terminate(); break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collected.value.append(rest) }
        try Task.checkCancellation()
        return RunResult(status: p.terminationStatus, output: String(decoding: collected.value as Data, as: UTF8.self))
    }
}
