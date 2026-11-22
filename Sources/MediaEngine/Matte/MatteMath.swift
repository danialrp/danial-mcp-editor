import Foundation

/// A person mask, one bit per pixel, rows packed into 64-bit words.
struct BitMask: Sendable, Equatable {
    let width: Int
    let height: Int
    var words: [UInt64]

    var wordsPerRow: Int { (width + 63) / 64 }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        words = [UInt64](repeating: 0, count: ((width + 63) / 64) * height)
    }

    /// From 8-bit values: set where the value is above `threshold`.
    init(width: Int, height: Int, bytes: UnsafePointer<UInt8>, bytesPerRow: Int, threshold: UInt8 = 127) {
        self.init(width: width, height: height)
        let wpr = wordsPerRow
        words.withUnsafeMutableBufferPointer { w in
            for y in 0..<height {
                let row = bytes + y * bytesPerRow
                for x in 0..<width where row[x] > threshold {
                    w[y * wpr + x >> 6] |= 1 << UInt64(x & 63)
                }
            }
        }
    }

    subscript(x: Int, y: Int) -> Bool {
        get { words[y * wordsPerRow + x >> 6] & (1 << UInt64(x & 63)) != 0 }
        set {
            let i = y * wordsPerRow + x >> 6
            if newValue { words[i] |= 1 << UInt64(x & 63) } else { words[i] &= ~(1 << UInt64(x & 63)) }
        }
    }

    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }
}

enum MatteMath {
    /// Repair in time, so the matte can
    /// only err on the safe side:
    /// 1. closing (largest over ±r frames, then smallest over ±r): a body
    ///    part dropped for a few frames is filled back in, a real movement is
    ///    not smeared;
    /// 2. the wide matte is the union over ±g frames of the closed one: round
    ///    a fast, blurred hand it is a little larger, never smaller.
    /// Frames past either end repeat the end frame. Returns tight and wide
    /// masks for `range` (indexes into `raw`); every value depends only on
    /// raw frames within 2r + g of it, so chunks that carry that many extra
    /// frames on each side give exactly what one pass over the file gives.
    static func repair(_ raw: [BitMask], r: Int, g: Int, range: Range<Int>) -> (tight: [BitMask], wide: [BitMask]) {
        let n = raw.count
        precondition(n > 0 && range.lowerBound >= 0 && range.upperBound <= n)
        // Each stage reads its input at clamped indexes.
        func clamp(_ i: Int) -> Int { min(n - 1, max(0, i)) }
        func fold(_ get: (Int) -> BitMask, _ at: Int, _ radius: Int, or: Bool) -> BitMask {
            var out = get(clamp(at))
            guard radius > 0 else { return out }
            out.words.withUnsafeMutableBufferPointer { o in
                for j in (at - radius)...(at + radius) where j != at {
                    get(clamp(j)).words.withUnsafeBufferPointer { s in
                        if or { for k in 0..<o.count { o[k] |= s[k] } } else { for k in 0..<o.count { o[k] &= s[k] } }
                    }
                }
            }
            return out
        }
        var dil: [Int: BitMask] = [:]
        for i in clamp(range.lowerBound - g - r)...clamp(range.upperBound - 1 + g + r) { dil[i] = fold({ raw[$0] }, i, r, or: true) }
        var clo: [Int: BitMask] = [:]
        for i in clamp(range.lowerBound - g)...clamp(range.upperBound - 1 + g) { clo[i] = fold({ dil[$0]! }, i, r, or: false) }
        var tight: [BitMask] = [], wide: [BitMask] = []
        for i in range {
            tight.append(clo[i]!)
            wide.append(fold({ clo[$0]! }, i, g, or: true))
        }
        return (tight, wide)
    }

    /// Brightness of a frame at a reduced size, for `motionFill`.
    struct Luma: Sendable {
        let width: Int
        let height: Int
        /// Matte pixels per luma pixel along each side.
        let step: Int
        var values: [UInt8]
    }

    /// Gives back to a Vision mask what moves fast next to the body: a hand
    /// or fingertips blurred by motion, which Vision often leaves out. A
    /// pixel is moving in frame i when it differs by more than `threshold`
    /// from both frame i - 1 and frame i + 1 (so the wall a hand has just
    /// left is not taken). Moving pixels are kept when they are connected to
    /// the mask, at most `reach` matte pixels from it. Ends of the list,
    /// with one neighbour only, are left as they are. Each frame depends on
    /// its two neighbours only.
    static func motionFill(_ masks: [BitMask], _ luma: [Luma], threshold: Int, reach: Double) -> [BitMask] {
        precondition(masks.count == luma.count)
        guard masks.count > 2, let l0 = luma.first, l0.width > 0, l0.height > 0 else { return masks }
        let w = l0.width, h = l0.height, step = l0.step, n = w * h
        let maxSteps = max(1, Int((reach / Double(step)).rounded()))
        var out = masks
        var moving = [Bool](repeating: false, count: n)
        var inside = [Bool](repeating: false, count: n)
        var dist = [Int32](repeating: -1, count: n)
        var queue: [Int] = []
        queue.reserveCapacity(n / 8)
        for i in 1..<(masks.count - 1) {
            let a = luma[i - 1].values, b = luma[i].values, c = luma[i + 1].values
            guard a.count == n, b.count == n, c.count == n else { continue }
            let m = masks[i]
            var any = false
            // Moving now: differs from both neighbours. The mask is read at
            // the centre of each luma cell.
            a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in c.withUnsafeBufferPointer { pc in
                moving.withUnsafeMutableBufferPointer { mv in
                    for k in 0..<n {
                        let v = Int(pb[k])
                        let mo = abs(v - Int(pa[k])) > threshold && abs(v - Int(pc[k])) > threshold
                        mv[k] = mo
                        any = any || mo
                    }
                }
            } } }
            guard any else { continue }
            let half = step / 2
            m.words.withUnsafeBufferPointer { words in
                inside.withUnsafeMutableBufferPointer { ins in
                    let wpr = m.wordsPerRow
                    for y in 0..<h {
                        let my = min(m.height - 1, y * step + half)
                        for x in 0..<w {
                            let mx = min(m.width - 1, x * step + half)
                            ins[y * w + x] = words[my * wpr + mx >> 6] & (1 << UInt64(mx & 63)) != 0
                        }
                    }
                }
            }
            // Drop single noisy pixels (fewer than 2 moving neighbours), and
            // seed the search with body cells next to moving ones.
            queue.removeAll(keepingCapacity: true)
            var added: [Int] = []
            moving.withUnsafeMutableBufferPointer { mv in inside.withUnsafeBufferPointer { ins in dist.withUnsafeMutableBufferPointer { d in
                for k in 0..<n { d[k] = -1 }
                for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                    let k = y * w + x
                    guard mv[k] else { continue }
                    var cnt = 0
                    for o in [-w - 1, -w, -w + 1, -1, 1, w - 1, w, w + 1] where mv[k + o] { cnt += 1 }
                    if cnt < 2 { mv[k] = false }
                } }
                for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                    let k = y * w + x
                    guard ins[k], mv[k - 1] || mv[k + 1] || mv[k - w] || mv[k + w] else { continue }
                    d[k] = 0
                    queue.append(k)
                } }
                // Grow through moving cells, at most `maxSteps` from the body.
                var head = 0
                while head < queue.count {
                    let k = queue[head]; head += 1
                    let x = k % w, y = k / w, next = d[k] + 1
                    guard next <= maxSteps else { continue }
                    for (j, ok) in [(k - 1, x > 0), (k + 1, x < w - 1), (k - w, y > 0), (k + w, y < h - 1)] where ok {
                        if d[j] < 0, !ins[j], mv[j] { d[j] = next; queue.append(j); added.append(j) }
                    }
                }
            } } }
            guard !added.isEmpty else { continue }
            for k in added {
                let x0 = (k % w) * step, y0 = (k / w) * step
                for y in y0..<min(m.height, y0 + step) { for x in x0..<min(m.width, x0 + step) { out[i][x, y] = true } }
            }
        }
        return out
    }

    /// Largest distance kept, in matte pixels, and code values per pixel.
    static let maxDistance: Float = 31.75
    static let codesPerPixel: Float = 4

    /// Signed distance from each pixel centre to the mask's edge, in pixels:
    /// positive inside, negative outside, the edge itself half way between
    /// an inside and an outside pixel. Exact (Felzenszwalb and Huttenlocher),
    /// clamped to `maxDistance`, written as 8-bit codes 128 + 4 d into `out`.
    static func signedDistance(_ m: BitMask, into out: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) {
        let w = m.width, h = m.height
        let big: Float = 1e9
        var toOutside = [Float](repeating: 0, count: w * h)
        var toInside = [Float](repeating: 0, count: w * h)
        toOutside.withUnsafeMutableBufferPointer { a in
            toInside.withUnsafeMutableBufferPointer { b in
                for y in 0..<h {
                    for x in 0..<w {
                        let inside = m[x, y]
                        a[y * w + x] = inside ? big : 0
                        b[y * w + x] = inside ? 0 : big
                    }
                }
                squaredEDT(a.baseAddress!, w, h)
                squaredEDT(b.baseAddress!, w, h)
                for y in 0..<h {
                    let row = out + y * bytesPerRow
                    for x in 0..<w {
                        let i = y * w + x
                        let d: Float = a[i] > 0 ? (a[i].squareRoot() - 0.5) : -(b[i].squareRoot() - 0.5)
                        let c = 128 + max(-maxDistance, min(maxDistance, d)) * codesPerPixel
                        row[x] = UInt8(max(0, min(255, c.rounded())))
                    }
                }
            }
        }
    }

    /// Distance in pixels from an 8-bit code.
    static func distance(code: UInt8) -> Float { (Float(code) - 128) / codesPerPixel }

    /// Squared Euclidean distance transform in place: zeros are the targets.
    static func squaredEDT(_ f: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int) {
        let n = max(w, h)
        let line = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let res = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let v = UnsafeMutablePointer<Int>.allocate(capacity: n)
        let z = UnsafeMutablePointer<Float>.allocate(capacity: n + 1)
        defer { line.deallocate(); res.deallocate(); v.deallocate(); z.deallocate() }
        for x in 0..<w {
            for y in 0..<h { line[y] = f[y * w + x] }
            edt1(line, h, res, v, z)
            for y in 0..<h { f[y * w + x] = res[y] }
        }
        for y in 0..<h {
            let row = f + y * w
            for x in 0..<w { line[x] = row[x] }
            edt1(line, w, res, v, z)
            for x in 0..<w { row[x] = res[x] }
        }
    }

    /// One dimension of the transform: lower envelope of parabolas.
    private static func edt1(_ f: UnsafeMutablePointer<Float>, _ n: Int, _ d: UnsafeMutablePointer<Float>,
                             _ v: UnsafeMutablePointer<Int>, _ z: UnsafeMutablePointer<Float>) {
        var k = 0
        v[0] = 0
        z[0] = -.infinity
        z[1] = .infinity
        if n > 1 {
            for q in 1..<n {
                var s: Float
                repeat {
                    let p = v[k]
                    s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * (q - p))
                    if s <= z[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = .infinity
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            d[q] = Float((q - p) * (q - p)) + f[p]
        }
    }

    /// Overlap of two masks (intersection over union); 1 when both are empty.
    static func iou(_ a: BitMask, _ b: BitMask) -> Double {
        var i = 0, u = 0
        for k in 0..<a.words.count {
            i += (a.words[k] & b.words[k]).nonzeroBitCount
            u += (a.words[k] | b.words[k]).nonzeroBitCount
        }
        return u == 0 ? 1 : Double(i) / Double(u)
    }
}
