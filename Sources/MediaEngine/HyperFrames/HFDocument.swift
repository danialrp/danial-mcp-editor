import Foundation

/// Reading and slicing HyperFrames HTML (architecture section 11).
///
/// A HyperFrames composition is an HTML page whose root element carries
/// `data-composition-id`, size, frame rate and duration; elements with
/// `data-start` / `data-duration` appear for that span of the root's time;
/// sub-compositions are hosted by elements with `data-composition-src`; GSAP
/// timelines are registered in `window.__timelines["id"]`. HyperFrames can
/// only render alpha output from time 0, so a slice [s0, s1) is rendered from
/// a copy of the composition shifted by s0: elements are moved or trimmed to
/// the slice and every registered timeline is wrapped so that time 0 of the
/// copy plays time s0 of the original. Written for any composition that
/// follows the model.
public enum HFDocument {
    public struct Root: Sendable, Equatable {
        public var id: String
        public var width: Int
        public var height: Int
        public var fps: Int
        public var duration: Double
    }

    /// A sub-composition and where the root shows it.
    public struct Host: Sendable, Equatable {
        public var id: String
        public var src: String
        public var start: Double
        public var duration: Double?
        public var end: Double { duration.map { start + $0 } ?? .infinity }
    }

    /// Start tags with their attributes.
    struct Tag {
        var range: Range<String.Index>
        var text: String
        func attr(_ name: String) -> String? {
            guard let r = text.range(of: #"\b\#(name)\s*=\s*"([^"]*)""#, options: .regularExpression) else { return nil }
            let m = text[r]
            guard let q = m.firstIndex(of: "\"") else { return nil }
            return String(m[m.index(after: q)..<m.index(before: m.endIndex)])
        }
    }

    static func tags(_ html: String, with attribute: String) -> [Tag] {
        var out: [Tag] = []
        var from = html.startIndex
        while let r = html.range(of: #"<[A-Za-z][^>]*\b\#(attribute)\s*=\s*"[^"]*"[^>]*>"#, options: .regularExpression, range: from..<html.endIndex) {
            out.append(Tag(range: r, text: String(html[r])))
            from = r.upperBound
        }
        return out
    }

    public static func root(_ html: String) -> Root? {
        guard let t = tags(html, with: "data-composition-id").first(where: { $0.attr("data-composition-src") == nil }),
              let id = t.attr("data-composition-id") else { return nil }
        return Root(id: id, width: Int(t.attr("data-width") ?? "") ?? 1080, height: Int(t.attr("data-height") ?? "") ?? 1920,
                    fps: Int(t.attr("data-fps") ?? "") ?? 60, duration: Double(t.attr("data-duration") ?? "") ?? 0)
    }

    public static func hosts(_ html: String) -> [Host] {
        tags(html, with: "data-composition-src").compactMap { t in
            guard let src = t.attr("data-composition-src") else { return nil }
            return Host(id: t.attr("data-composition-id") ?? "", src: src, start: Double(t.attr("data-start") ?? "0") ?? 0,
                        duration: t.attr("data-duration").flatMap(Double.init))
        }
    }

    static func setAttr(_ tag: String, _ name: String, _ value: String) -> String {
        if let r = tag.range(of: #"\b\#(name)\s*=\s*"[^"]*""#, options: .regularExpression) {
            return tag.replacingCharacters(in: r, with: "\(name)=\"\(value)\"")
        }
        let close = tag.hasSuffix("/>") ? tag.index(tag.endIndex, offsetBy: -2) : tag.index(before: tag.endIndex)
        return tag[..<close] + " \(name)=\"\(value)\"" + tag[close...]
    }

    static func num(_ v: Double) -> String { String(format: "%.6f", v) }

    /// The page shifted by `offset` and cut to `duration`: the root lasts
    /// `duration` (and starts at `rootStart`), every other timed element is
    /// moved by `-offset` and trimmed to the slice (or moved past its end when
    /// it falls outside), and registered timelines are wrapped.
    public static func shifted(_ html: String, offset: Double, duration: Double, rootStart: Double = 0) -> String {
        var out = html
        let rootTag = tags(html, with: "data-composition-id").first { $0.attr("data-composition-src") == nil }
        // Rewrite timed tags from the end so earlier ranges stay valid.
        for t in tags(html, with: "data-start").reversed() {
            var tag = t.text
            if let r = rootTag, r.range == t.range {
                tag = setAttr(tag, "data-start", num(rootStart))
                tag = setAttr(tag, "data-duration", num(duration))
            } else {
                let st = Double(t.attr("data-start") ?? "0") ?? 0
                let du = t.attr("data-duration").flatMap(Double.init)
                let en = du.map { st + $0 } ?? .infinity
                let a = max(st, offset), b = min(en, offset + duration)
                if b <= a {
                    // Outside the slice: shown after it ends, so never in it.
                    tag = setAttr(tag, "data-start", num(duration + 1))
                    tag = setAttr(tag, "data-duration", num(0.001))
                } else {
                    tag = setAttr(tag, "data-start", num(a - offset))
                    if du != nil || b < .infinity { tag = setAttr(tag, "data-duration", num(b - a)) }
                }
            }
            out.replaceSubrange(t.range, with: tag)
        }
        // The root's tag may carry no data-start at all.
        if let r = rootTag, r.attr("data-start") == nil, let now = tags(out, with: "data-composition-id").first(where: { $0.attr("data-composition-src") == nil }) {
            var tag = setAttr(now.text, "data-start", num(rootStart))
            tag = setAttr(tag, "data-duration", num(duration))
            out.replaceSubrange(now.range, with: tag)
        }
        return wrapTimelines(out, offset: offset, duration: duration)
    }

    // MARK: depth compositions (phase 8)

    /// A depth composition has an element `#back` (drawn behind the person)
    /// and an element `#front`, and hides one of them when `<html>` carries
    /// the class `pass-front` or `pass-back`. It is rendered in two passes.
    public static func isDepth(_ html: String) -> Bool {
        html.range(of: #"\bid\s*=\s*"back""#, options: .regularExpression) != nil
            && html.range(of: #"\bid\s*=\s*"front""#, options: .regularExpression) != nil
    }

    /// The moments the person's outline is lit, from `const EDGE = [[start, end], ...];`.
    public static func edges(_ html: String) -> [ClosedRange<Double>] {
        guard let r = html.range(of: #"const\s+EDGE\s*=\s*(\[[\s\S]*?\]\s*\])\s*;"#, options: .regularExpression) else { return [] }
        let text = String(html[r])
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"),
              let v = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [[Double]] else { return [] }
        return v.compactMap { $0.count >= 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
    }

    /// The page for one pass: `<html>` gets the class `pass-back` or `pass-front`.
    public static func forPass(_ html: String, _ pass: String) -> String {
        guard let r = html.range(of: #"<html\b[^>]*>"#, options: .regularExpression) else { return html }
        var tag = String(html[r])
        if let c = tag.range(of: #"\bclass\s*=\s*"([^"]*)""#, options: .regularExpression) {
            let old = String(tag[c])
            let q = old.firstIndex(of: "\"")!
            tag.replaceSubrange(c, with: old[...q] + "pass-\(pass) " + old[old.index(after: q)...])
        } else {
            tag = String(tag.dropLast()) + " class=\"pass-\(pass)\">"
        }
        return html.replacingCharacters(in: r, with: tag)
    }

    /// Without `<video id="src">`: the footage placed in a composition only
    /// to preview it in HyperFrames Studio. The layer never carries it.
    public static func withoutFootagePreview(_ html: String) -> String {
        html.replacingOccurrences(of: #"\s*<video\b[^>]*\bid\s*=\s*"src"[^>]*>(\s*</video>)?"#, with: "", options: .regularExpression)
    }

    /// `window.__timelines["k"] = tl;` becomes a paused master timeline whose
    /// time t plays tl at offset + t.
    static func wrapTimelines(_ js: String, offset: Double, duration: Double) -> String {
        let pattern = #"window\.__timelines(?:\[\s*["']([^"']+)["']\s*\]|\.([A-Za-z_$][\w$]*))\s*=\s*([A-Za-z_$][\w$]*)\s*;"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return js }
        var out = js
        for m in re.matches(in: js, range: NSRange(js.startIndex..., in: js)).reversed() {
            guard let whole = Range(m.range, in: js), let v = Range(m.range(at: 3), in: js) else { continue }
            let key = Range(m.range(at: 1), in: js).map { String(js[$0]) } ?? Range(m.range(at: 2), in: js).map { String(js[$0]) } ?? "main"
            let tl = String(js[v])
            let wrapped = "window.__timelines[\"\(key)\"] = (function () { const m = gsap.timeline({ paused: true }); "
                + "m.fromTo(\(tl), { time: \(num(offset)) }, { time: \(num(offset + duration)), duration: \(num(duration)), ease: \"none\", immediateRender: false }, 0); "
                + "\(tl).time(\(num(offset))); return m; })();"
            out.replaceSubrange(Range(m.range, in: out) ?? whole, with: wrapped)
        }
        return out
    }
}
