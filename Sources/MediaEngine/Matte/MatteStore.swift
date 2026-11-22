import Accelerate
import AVFoundation
import CoreImage
import CryptoKit
import EditorCore
import EditorKit
import Foundation
import ImageIO
import Vision

/// Makes and keeps person mattes (X-3, architecture section 11).
///
/// A matte belongs to a footage file and follows its source time. It is
/// cached in chunks of source time, each under a hash of what its frames
/// depend on (the file, where the masks come from, the settings), so a
/// chunk is made once and reused by every clip and export that shows it.
///
/// A chunk is a small HEVC file, one frame per source frame, twice as tall
/// as the matte: the tight matte on top, the wide matte below. Each pixel
/// holds the signed distance to the person's outline (128 + 4 per pixel,
/// positive inside), so the compositor cuts, softens and grows the outline
/// with one texture read and no filtering. Masks come from Apple Vision
/// person segmentation or from imported masks (SAM 3 from Edits), and are
/// repaired in time.
public actor MatteStore {
    public struct Chunk: Sendable {
        public var index: Int
        /// Source seconds.
        public var start: Double
        public var end: Double
        public var hash: String
        public var current: URL?
        /// A matte made with older inputs, used until the current one exists.
        public var stale: URL?
    }

    /// Stability of one chunk, frame by frame (source time, overlap with the
    /// frame before, change of area).
    public struct QA: Codable, Sendable {
        public var times: [Double]
        public var iou: [Double]
        public var areaJump: [Double]
        public var coverage: [Double]
    }

    let settings: UserSettingsStore
    private var making: Set<String> = []
    public var onChange: (@Sendable () async -> Void)?

    public init(settings: UserSettingsStore) { self.settings = settings }

    public func setOnChange(_ f: @escaping @Sendable () async -> Void) { onChange = f }

    static let engineVersion = "matte-2"

    public static func cacheFolder(_ a: MediaAsset) -> URL {
        let key = digest(Data("\(a.path)|\(a.fingerprint)".utf8)).prefix(20)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor/mattes/\(key)", isDirectory: true)
    }

    /// Where imported masks of an asset live inside the project package.
    public static func importFolder(package: URL, asset: EntityID) -> URL {
        package.appendingPathComponent("mattes/\(asset.raw)", isDirectory: true)
    }

    static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Imported masks: (source milliseconds, file), sorted.
    static func importedMasks(_ folder: URL) -> [(ms: Double, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { n -> (Double, URL)? in
            guard n.lowercased().hasSuffix(".png"), let ms = Double(n.dropLast(4)) else { return nil }
            return (ms, folder.appendingPathComponent(n))
        }.sorted { $0.0 < $1.0 }
    }

    /// The chunks covering a whole file.
    public func chunks(_ a: MediaAsset, package: URL?) throws -> [Chunk] {
        guard let source = a.matte else { return [] }
        let m = settings.current.matte
        var base = "\(Self.engineVersion)|\(a.path)|\(a.fingerprint)|\(source.rawValue)|\(m.quality)|\(m.maxSize)|\(m.chunkSeconds)|\(m.closeSeconds)|\(m.growSeconds)|\(m.fileQuality)"
        if source == .vision, m.motionFill { base += "|motion \(m.motionThreshold) \(m.motionReach)" }
        if source == .vision, m.visionFps > 0 { base += "|visionFps \(m.visionFps)" }
        if source == .imported {
            guard let package else { throw EditorError(.notFound, "imported mattes need the project package") }
            let folder = Self.importFolder(package: package, asset: a.id)
            let list = Self.importedMasks(folder)
            guard !list.isEmpty else {
                throw EditorError(.notFound, "media \(a.id) uses imported masks but \(folder.path) has none; run matte.import first")
            }
            var parts: [String] = []
            for (_, u) in list {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                parts.append("\(u.lastPathComponent):\(v?.fileSize ?? 0):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            base += "|" + Self.digest(Data(parts.joined(separator: "\n").utf8))
        }
        let cache = Self.cacheFolder(a)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        let total = a.info.duration.seconds
        let length = max(0.5, m.chunkSeconds)
        var out: [Chunk] = []
        var k = 0
        while Double(k) * length < total - 1e-9 {
            let s0 = Double(k) * length, s1 = min(total, s0 + length)
            let hash = String(Self.digest(Data((base + "|\(k)").utf8)).prefix(24))
            let name = String(format: "%05d-", k) + hash + ".mov"
            let older = files.filter { $0.hasPrefix(String(format: "%05d-", k)) && $0 != name && $0.hasSuffix(".mov") }.sorted().last
            out.append(Chunk(index: k, start: s0, end: s1, hash: hash,
                             current: files.contains(name) ? cache.appendingPathComponent(name) : nil,
                             stale: older.map { cache.appendingPathComponent($0) }))
            k += 1
        }
        return out
    }

    /// Indexes of the chunks the project's clips show.
    public static func needed(_ p: Project, asset: EntityID, chunkSeconds: Double) -> Set<Int> {
        var out = Set<Int>()
        let length = max(0.5, chunkSeconds)
        for t in p.tracks {
            for c in t.clips where c.asset == asset {
                let a = Int((c.sourceStart.seconds / length).rounded(.down))
                let b = Int(((c.sourceEnd.seconds - 1e-6) / length).rounded(.down))
                if b >= a { out.formUnion(a...b) }
            }
        }
        return out
    }

    public static func qa(_ chunkFile: URL) -> QA? {
        guard let d = try? Data(contentsOf: chunkFile.deletingPathExtension().appendingPathExtension("json")) else { return nil }
        return try? JSONDecoder().decode(QA.self, from: d)
    }

    /// Makes the chunks that have no current matte (of `only`, or of all
    /// given). Returns the indexes made.
    public func generate(_ a: MediaAsset, package: URL?, only: Set<Int>,
                         progress: @escaping @Sendable (Int, Int, String) async throws -> Void) async throws -> [Int] {
        let todo = try chunks(a, package: package).filter { only.contains($0.index) && $0.current == nil }
        let key = Self.cacheFolder(a).path
        guard !making.contains(key) else { throw EditorError(.conflict, "the matte of \(a.id) is already being made") }
        making.insert(key)
        defer { making.remove(key) }
        let m = settings.current.matte
        let cache = Self.cacheFolder(a)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let imported = a.matte == .imported ? package.map { Self.importedMasks(Self.importFolder(package: $0, asset: a.id)) } : nil
        let counter = Counter()
        let parallel = max(1, m.parallelChunks)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let c = todo[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    try await Self.make(a, c, settings: m, imported: imported, cache: cache)
                    let n = await counter.add()
                    try await progress(n, todo.count, "matte chunk \(c.index + 1) (\(String(format: "%.1f", c.start))-\(String(format: "%.1f", c.end)) s) made")
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

    // MARK: making one chunk

    struct Geometry {
        var rotation: Int
        /// Size of the picture as shown (after the stored rotation).
        var displayWidth: Int
        var displayHeight: Int
        var matteWidth: Int
        var matteHeight: Int
    }

    static func geometry(_ track: AVAssetTrack, maxSize: Int) async throws -> Geometry {
        let size = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let rotation = ((Int((atan2(t.b, t.a) * 180 / .pi).rounded()) % 360) + 360) % 360
        var dw = Int(abs(size.width).rounded()), dh = Int(abs(size.height).rounded())
        if rotation == 90 || rotation == 270 { swap(&dw, &dh) }
        let scale = min(1, Double(maxSize) / Double(max(dw, dh)))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return Geometry(rotation: rotation, displayWidth: dw, displayHeight: dh,
                        matteWidth: even(Double(dw) * scale), matteHeight: even(Double(dh) * scale))
    }

    static func make(_ a: MediaAsset, _ c: Chunk, settings m: UserSettings.MatteSettings,
                     imported: [(ms: Double, url: URL)]?, cache: URL) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: a.path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EditorError(.io, "media \(a.id) has no picture to make a matte from")
        }
        let geo = try await geometry(track, maxSize: m.maxSize)
        let fps = Double(try await track.load(.nominalFrameRate)).nonZero ?? 30
        let r = max(0, Int((m.closeSeconds * fps).rounded())), g = max(0, Int((m.growSeconds * fps).rounded()))
        let pad = 2 * r + g

        // Every frame near the chunk, decoded once: its time and, for Vision, its mask.
        let margin = Double(pad + 2) / fps
        let window = CMTimeRange(start: CMTime(seconds: max(0, c.start - margin), preferredTimescale: 600_000),
                                 end: CMTime(seconds: c.end + margin, preferredTimescale: 600_000))
        let fill = imported == nil && m.motionFill
        let decoded = try await decode(asset, track, window, geo, quality: imported == nil ? m.quality : nil, luma: fill,
                                       fps: fps, visionFps: m.visionFps)
        let all = decoded.times
        let inside = all.indices.filter { all[$0].seconds >= c.start - 1e-9 && all[$0].seconds < c.end - 1e-9 }
        guard let first = inside.first, let last = inside.last else {
            throw EditorError(.io, "no frames of \(a.id) between \(c.start) and \(c.end) s")
        }
        let lo = max(0, first - pad), hi = min(all.count, last + 1 + pad)
        let times = Array(all[lo..<hi])
        let raw: [BitMask]
        if let imported {
            raw = try importedMasks(imported, at: times, geo)
        } else {
            // Over every decoded frame, so each kept frame has both neighbours.
            let masks = fill ? MatteMath.motionFill(decoded.masks, decoded.luma, threshold: Int(m.motionThreshold), reach: m.motionReach)
                : decoded.masks
            raw = Array(masks[lo..<hi])
        }
        let local = (first - lo)..<(last + 1 - lo)
        // One frame more at the front, when there is one, for the QA overlap.
        let extra = local.lowerBound > 0 ? 1 : 0
        let repaired = MatteMath.repair(raw, r: r, g: g, range: (local.lowerBound - extra)..<local.upperBound)
        let tight = Array(repaired.tight.dropFirst(extra)), wide = Array(repaired.wide.dropFirst(extra))

        var qa = QA(times: [], iou: [], areaJump: [], coverage: [])
        let pixels = Double(geo.matteWidth * geo.matteHeight)
        for k in tight.indices {
            let p = k + extra > 0 ? repaired.tight[k + extra - 1] : tight[k]
            let area = Double(tight[k].count), before = Double(p.count)
            qa.times.append(times[local.lowerBound + k].seconds)
            qa.iou.append(MatteMath.iou(tight[k], p))
            qa.areaJump.append(before > 0 ? abs(area - before) / before : (area > 0 ? 1 : 0))
            qa.coverage.append(area / pixels)
        }

        let name = String(format: "%05d-", c.index) + c.hash
        let tmp = cache.appendingPathComponent("\(name)-\(UUID().uuidString).tmp.mov")
        try await write(tight: tight, wide: wide, times: Array(times[local]), start: c.start, end: c.end,
                        geo: geo, quality: m.fileQuality, fps: fps, to: tmp)
        let json = try JSONEncoder().encode(qa)
        try json.write(to: cache.appendingPathComponent(name + ".json"), options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: cache.appendingPathComponent(name + ".mov"))
    }

    static func orientation(_ rotation: Int) -> CGImagePropertyOrientation {
        switch rotation {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

    /// The frames shown in `window`, in order: their track times and, when
    /// `quality` is given, their Vision person masks, upright, at matte size.
    static func decode(_ asset: AVURLAsset, _ track: AVAssetTrack, _ window: CMTimeRange, _ geo: Geometry,
                       quality: String?, luma: Bool = false, fps: Double = 30, visionFps: Double = 0) async throws -> (times: [CMTime], masks: [BitMask], luma: [MatteMath.Luma]) {
        let segments = try await track.load(.segments)
        let start = DecodeStart.earlierStart(track, segments: segments, at: window.start) ?? window.start
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: window.end)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw EditorError(.io, "cannot decode \(asset.url.path): \(reader.error?.localizedDescription ?? "")") }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = switch quality {
        case "fast": .fast
        case "balanced": .balanced
        default: .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let sequence = VNSequenceRequestHandler()
        let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var upright: CVPixelBuffer?
        CVPixelBufferCreate(nil, geo.matteWidth, geo.matteHeight, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &upright)
        guard let upright else { throw EditorError(.io, "out of memory for the matte") }
        var times: [CMTime] = [], masks: [BitMask] = [], lumas: [MatteMath.Luma] = []
        var seen: [Bool] = []
        let visionStep = visionFps > 0 ? 1 / visionFps : 0
        let frameStep = 1 / max(1, fps)
        // Brightness at half the matte size, for the motion fill.
        let step = 2, lw = geo.matteWidth / step, lh = geo.matteHeight / step
        var small = [UInt8](repeating: 0, count: lw * lh * 4)
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard pts >= window.start, pts < window.end, times.last.map({ pts > $0 }) ?? true else { continue }
            times.append(pts)
            guard quality != nil else { continue }
            var image = CIImage(cvPixelBuffer: pb).oriented(orientation(geo.rotation))
            image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(geo.matteWidth) / image.extent.width,
                                                            y: CGFloat(geo.matteHeight) / image.extent.height))
            ci.render(image, to: upright)
            // Vision runs at most `visionFps` times a second, on the first
            // frame of each 1/visionFps of the file (absolute, so chunks
            // agree with one pass); the frames between are filled below.
            let t = pts.seconds
            let wanted = visionStep <= 0 || floor(t / visionStep + 1e-6) != floor((t - frameStep) / visionStep + 1e-6)
            if wanted {
                try sequence.perform([request], on: upright)
                guard let mask = request.results?.first?.pixelBuffer else { throw EditorError(.io, "Vision gave no mask at \(pts.seconds) s") }
                masks.append(scaledMask(mask, geo))
            } else {
                masks.append(BitMask(width: geo.matteWidth, height: geo.matteHeight))
            }
            seen.append(wanted)
            if luma {
                CVPixelBufferLockBaseAddress(upright, .readOnly)
                var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(upright), height: vImagePixelCount(geo.matteHeight),
                                        width: vImagePixelCount(geo.matteWidth), rowBytes: CVPixelBufferGetBytesPerRow(upright))
                small.withUnsafeMutableBytes { b in
                    var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(lh), width: vImagePixelCount(lw), rowBytes: lw * 4)
                    vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
                }
                CVPixelBufferUnlockBaseAddress(upright, .readOnly)
                var v = [UInt8](repeating: 0, count: lw * lh)
                for k in 0..<(lw * lh) {   // BGRA
                    let p = k * 4
                    v[k] = UInt8((Int(small[p + 2]) * 54 + Int(small[p + 1]) * 183 + Int(small[p]) * 19) >> 8)
                }
                lumas.append(MatteMath.Luma(width: lw, height: lh, step: step, values: v))
            }
        }
        if reader.status == .failed { throw EditorError(.io, "decoding failed: \(reader.error?.localizedDescription ?? "")") }
        if quality != nil, let last = seen.lastIndex(of: false), !seen[last...].contains(true) {
            // The window ends between Vision frames: the last frame (still
            // in `upright`) gets its own mask.
            try sequence.perform([request], on: upright)
            if let mask = request.results?.first?.pixelBuffer { masks[masks.count - 1] = scaledMask(mask, geo); seen[seen.count - 1] = true }
        }
        // Frames between Vision frames: the union of the masks either side,
        // so nothing of the person is lost; the time repair and the motion
        // fill follow.
        for i in seen.indices where !seen[i] {
            let before = seen[..<i].lastIndex(of: true), after = seen[(i + 1)...].firstIndex(of: true)
            var m = before.map { masks[$0] } ?? after.map { masks[$0] } ?? masks[i]
            if let b = before, let a = after { for k in m.words.indices { m.words[k] = masks[b].words[k] | masks[a].words[k] } }
            masks[i] = m
        }
        return (times, masks, lumas)
    }

    /// A one-channel mask scaled to matte size and cut at half.
    static func scaledMask(_ pb: CVPixelBuffer, _ geo: Geometry) -> BitMask {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let w = geo.matteWidth, h = geo.matteHeight
        var bytes = [UInt8](repeating: 0, count: w * h)
        return bytes.withUnsafeMutableBufferPointer { b in
            var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            return BitMask(width: w, height: h, bytes: b.baseAddress!, bytesPerRow: w)
        }
    }

    /// Imported masks at the given frame times: the two nearest masks
    /// blended by time and cut at half.
    static func importedMasks(_ list: [(ms: Double, url: URL)], at times: [CMTime], _ geo: Geometry) throws -> [BitMask] {
        guard !list.isEmpty else { throw EditorError(.notFound, "no imported masks") }
        var loaded: [Int: [UInt8]] = [:]
        func load(_ i: Int) throws -> [UInt8] {
            if let v = loaded[i] { return v }
            guard let src = CGImageSourceCreateWithURL(list[i].url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw EditorError(.io, "cannot read mask \(list[i].url.path)")
            }
            let aspect = Double(img.width) / Double(img.height), want = Double(geo.displayWidth) / Double(geo.displayHeight)
            guard abs(aspect / want - 1) < 0.02 else {
                throw EditorError.invalid("mask \(list[i].url.lastPathComponent) is \(img.width)x\(img.height) but the picture is \(geo.displayWidth)x\(geo.displayHeight) as shown; masks must be upright and of the same shape")
            }
            var px = [UInt8](repeating: 0, count: geo.matteWidth * geo.matteHeight)
            px.withUnsafeMutableBytes { b in
                let ctx = CGContext(data: b.baseAddress, width: geo.matteWidth, height: geo.matteHeight, bitsPerComponent: 8,
                                    bytesPerRow: geo.matteWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: geo.matteWidth, height: geo.matteHeight))
            }
            if loaded.count > 6 { loaded.removeAll() }
            loaded[i] = px
            return px
        }
        let ms = list.map(\.ms)
        var out: [BitMask] = []
        for t in times {
            let now = t.seconds * 1000
            var i = 0
            while i + 1 < ms.count, ms[i + 1] <= now { i += 1 }
            let j = min(ms.count - 1, i + 1)
            let w = j == i ? 0 : min(1, max(0, (now - ms[i]) / (ms[j] - ms[i])))
            let a = try load(i), b = try load(j)
            var blend = [UInt8](repeating: 0, count: a.count)
            for k in 0..<a.count { blend[k] = UInt8((Double(a[k]) * (1 - w) + Double(b[k]) * w).rounded()) }
            out.append(blend.withUnsafeBufferPointer { BitMask(width: geo.matteWidth, height: geo.matteHeight, bytes: $0.baseAddress!, bytesPerRow: geo.matteWidth) })
        }
        return out
    }

    /// Writes the chunk file: tight matte on top, wide below, as distances.
    static func write(tight: [BitMask], wide: [BitMask], times: [CMTime], start: Double, end: Double, geo: Geometry,
                      quality: Double, fps: Double, to url: URL) async throws {
        let w = geo.matteWidth, h = geo.matteHeight
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: 2 * h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps.rounded())),
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: 2 * h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw EditorError(.io, "cannot write the matte: \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)
        let origin = CMTime(seconds: start, preferredTimescale: 600_000)
        // Distances for a few frames at a time, on all cores; appended in order.
        let batch = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var k = 0
        while k < tight.count {
            let n = min(batch, tight.count - k)
            var buffers: [CVPixelBuffer] = []
            for _ in 0..<n {
                var pb: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
                if pb == nil {
                    CVPixelBufferCreate(nil, w, 2 * h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
                }
                guard let pb else { throw EditorError(.io, "out of memory for the matte") }
                buffers.append(pb)
            }
            let boxed = Unchecked(buffers)
            DispatchQueue.concurrentPerform(iterations: n) { j in
                let pb = boxed.value[j]
                CVPixelBufferLockBaseAddress(pb, [])
                let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
                let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                MatteMath.signedDistance(tight[k + j], into: y, bytesPerRow: ybpr)
                MatteMath.signedDistance(wide[k + j], into: y + h * ybpr, bytesPerRow: ybpr)
                let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
                memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
                CVPixelBufferUnlockBaseAddress(pb, [])
            }
            for j in 0..<n {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                guard adaptor.append(buffers[j], withPresentationTime: times[k + j] - origin) else {
                    throw EditorError(.io, "matte frame not written: \(writer.error?.localizedDescription ?? "")")
                }
            }
            k += n
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600_000) - origin)
        await writer.finishWriting()
        guard writer.status == .completed else { throw EditorError(.io, "matte not written: \(writer.error?.localizedDescription ?? "")") }
    }

    /// The matte frame of a chunk file nearest to `t` (seconds into the
    /// chunk), as distance codes: tight and wide, each `width` x `height`.
    public static func readFrame(_ url: URL, at t: Double) async throws -> (width: Int, height: Int, tight: [UInt8], wide: [UInt8]) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError(.io, "matte file has no picture") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        reader.add(out)
        reader.startReading()
        var best: CVPixelBuffer?
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if CMSampleBufferGetPresentationTimeStamp(sb).seconds <= t + 1e-6 || best == nil { best = pb } else { break }
        }
        reader.cancelReading()
        guard let pb = best else { throw EditorError(.io, "matte file has no frames") }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h2 = CVPixelBufferGetHeightOfPlane(pb, 0), h = h2 / 2
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        var tight = [UInt8](repeating: 0, count: w * h), wide = tight
        for y in 0..<h {
            for x in 0..<w {
                tight[y * w + x] = base[y * bpr + x]
                wide[y * w + x] = base[(y + h) * bpr + x]
            }
        }
        return (w, h, tight, wide)
    }
}

extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
