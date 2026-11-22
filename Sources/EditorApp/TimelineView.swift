import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// The timeline: a ruler, one row per track and the playhead.
///
/// Click or drag on the ruler or empty space to scrub. Click a clip to select
/// it (Shift adds or removes), drag it to move it, drag near an edge to trim
/// it. A drag counts only past a few pixels; moved and trimmed edges snap to
/// other clips' edges and the playhead, and a trim stops at the neighbouring
/// clip. Cmd-scroll or pinch zooms. Every edit is a tool call, like an agent's.
@MainActor
final class TimelineView: NSView {
    weak var owner: MainWindowController?
    weak var scrollView: NSScrollView? {
        didSet {
            // The track header is pinned to the visible left edge. A scroll
            // copies the old pixels sideways and redraws only the new strip,
            // which left copies of the header across the clips; redraw the
            // whole visible area on every scroll instead.
            guard let clip = scrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            if let o = scrollObserver { NotificationCenter.default.removeObserver(o) }
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsDisplay(self?.visibleRect ?? .zero) }
            }
        }
    }
    private var scrollObserver: NSObjectProtocol?

    private(set) var project: Project?
    private(set) var selection = Set<EntityID>() {
        didSet { if selection != oldValue { owner?.selectionChanged() } }
    }
    /// Sound levels per media file (dB per 10 ms), loaded in the background.
    private var waveforms: [EntityID: [Float]] = [:]
    private var loading = Set<EntityID>()
    /// Pixels per second.
    private var pps: CGFloat = 40
    /// Zoom limits: 6000 px a second shows a 60 fps frame 100 px wide;
    /// 0.02 px a second puts about 14 hours on a laptop screen.
    static let maxPPS: CGFloat = 6000
    static let minPPS: CGFloat = 0.02
    private let header: CGFloat = 96
    private let rulerHeight: CGFloat = 26

    var playhead: Time = .zero {
        didSet {
            guard oldValue != playhead else { return }
            setNeedsDisplay(stripRect(for: oldValue))
            setNeedsDisplay(stripRect(for: playhead))
        }
    }

    private struct Row {
        var track: Track
        var y: CGFloat
        var height: CGFloat
    }
    private var rows: [Row] = []

    /// A time range marked by ⌥-dragging on the ruler; Delete removes it
    /// from every track (timeline.deleteRange).
    var markedRange: (start: Time, end: Time)? { didSet { needsDisplay = true } }

    private enum Drag {
        case mark(from: Time)
        case scrub
        case move(clip: Clip, fromTrack: EntityID, grabOffset: CGFloat)
        case trim(clip: Clip, edge: TrimClip.Edge)
    }
    private var drag: Drag?
    private var dragPoint: CGPoint = .zero
    private var downPoint: CGPoint = .zero
    /// A move or trim starts only once the mouse has gone this far, so a
    /// click never shifts a clip by a frame or two.
    private let dragThreshold: CGFloat = 4
    private var dragStarted = false
    /// Edges and the playhead pull a moved or trimmed edge within this distance.
    private let snapDistance: CGFloat = 8
    /// Where a seek from scrubbing is going; until it lands the player's own
    /// time is behind and must not move the playhead back.
    private(set) var pendingSeek: Time?

    /// Selects clips, as a click would (ui.select, the self-test).
    func select(_ ids: [EntityID]) {
        if ids.isEmpty { markedRange = nil }
        selection = Set(ids)
        needsDisplay = true
    }

    /// Pixels per second, and setting it keeps the playhead in place.
    var pixelsPerSecond: CGFloat {
        get { pps }
        set { zoom(by: newValue / pps) }
    }

    /// Where a time on a track is in this view (for the self-test and
    /// tools that point at the timeline); nil when the track is not shown.
    func point(at t: Time, track: EntityID) -> NSPoint? {
        guard let r = rows.first(where: { $0.track.id == track }) else { return nil }
        return NSPoint(x: x(t), y: r.y + r.height / 2)
    }

    var rulerY: CGFloat { rulerHeight / 2 }

    /// The tracks that hold the selected clips.
    var selectedTracks: [EntityID] {
        guard let p = project else { return [] }
        return p.tracks.filter { t in t.clips.contains { selection.contains($0.id) } }.map(\.id)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: data

    func setProject(_ p: Project?) {
        project = p
        if let p {
            let ids = Set(p.tracks.flatMap { $0.clips.map(\.id) })
            selection = selection.intersection(ids)
        } else {
            selection = []
        }
        relayoutRows()
        loadWaveforms()
        needsDisplay = true
    }

    private func loadWaveforms() {
        guard let p = project else { return }
        let used = Set(p.tracks.flatMap { $0.clips.map(\.asset) })
        for a in p.media where used.contains(a.id) && a.info.audio != nil && waveforms[a.id] == nil && !loading.contains(a.id) {
            loading.insert(a.id)
            Task { [weak self] in
                let e = try? await AnalysisTools.levels.envelope(for: a)
                await MainActor.run {
                    self?.loading.remove(a.id)
                    if let e { self?.waveforms[a.id] = e.rmsDB; self?.needsDisplay = true }
                }
            }
        }
    }

    private func relayoutRows() {
        rows = []
        guard let p = project else { resize(); return }
        // Top layer first, as pictures stack; sound tracks below.
        let ordered = p.tracks.filter { $0.kind != .audio }.reversed() + p.tracks.filter { $0.kind == .audio }
        var y = rulerHeight
        for t in ordered {
            let h: CGFloat = t.kind == .main ? 70 : 46
            rows.append(Row(track: t, y: y, height: h))
            y += h + 2
        }
        resize()
    }

    private func resize() {
        let duration = project?.duration.seconds ?? 0
        let visible = scrollView?.contentSize ?? bounds.size
        let width = max(visible.width, header + CGFloat(duration + 10) * pps)
        let height = max(visible.height, (rows.last.map { $0.y + $0.height } ?? rulerHeight) + 20)
        setFrameSize(NSSize(width: width, height: height))
    }

    // MARK: coordinates

    private func x(_ t: Time) -> CGFloat { header + CGFloat(t.seconds) * pps }

    private func time(atX x: CGFloat) -> Time {
        let rate = project?.settings.frameRate ?? .fps60
        return Time(seconds: max(0, Double((x - header) / pps))).snapped(to: rate)
    }

    private func stripRect(for t: Time) -> NSRect { NSRect(x: x(t) - 8, y: 0, width: 16, height: bounds.height) }

    private func row(atY y: CGFloat) -> Row? { rows.first { y >= $0.y && y < $0.y + $0.height } }

    private func clipRect(_ c: Clip, in r: Row) -> NSRect {
        NSRect(x: x(c.start), y: r.y + 3, width: max(1, CGFloat(c.duration.seconds) * pps), height: r.height - 6)
    }

    private func hit(_ p: CGPoint) -> (Row, Clip)? {
        // The track names cover the left of the visible area.
        guard let r = row(atY: p.y), p.x >= visibleRect.minX + header else { return nil }
        let t = Time(seconds: Double((p.x - header) / pps))
        guard let i = r.track.clipIndex(containing: t) else { return nil }
        return (r, r.track.clips[i])
    }

    // MARK: zoom and scrolling

    func zoom(by factor: CGFloat, anchorX: CGFloat? = nil) {
        guard let sv = scrollView else { return }
        let anchor = anchorX ?? x(playhead)
        let anchorTime = Double((anchor - header) / pps)
        let screenOffset = anchor - sv.contentView.bounds.origin.x
        // From a whole frame many pixels wide down to hours on one screen.
        pps = min(Self.maxPPS, max(Self.minPPS, pps * factor))
        resize()
        let newX = header + CGFloat(anchorTime) * pps - screenOffset
        sv.contentView.scroll(to: NSPoint(x: max(0, newX), y: sv.contentView.bounds.origin.y))
        sv.reflectScrolledClipView(sv.contentView)
        needsDisplay = true
    }

    func zoomToFit() {
        guard let sv = scrollView, let d = project?.duration.seconds, d > 0 else { return }
        pps = min(Self.maxPPS, max(Self.minPPS, (sv.contentSize.width - header - 30) / CGFloat(d)))
        resize()
        sv.contentView.scroll(to: .zero)
        needsDisplay = true
    }

    func keepPlayheadVisible() {
        guard let sv = scrollView else { return }
        let visible = sv.contentView.bounds
        let px = x(playhead)
        if px > visible.maxX - 40 || px < visible.minX + header {
            sv.contentView.scroll(to: NSPoint(x: max(0, px - header - 40), y: visible.origin.y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            zoom(by: e.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1, anchorX: convert(e.locationInWindow, from: nil).x)
        } else {
            super.scrollWheel(with: e)
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, anchorX: convert(e.locationInWindow, from: nil).x)
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        dragPoint = p
        downPoint = p
        dragStarted = false
        drag = nil
        if p.y >= rulerHeight, p.x < visibleRect.minX + header {
            // The track header: its lock, mute and hide buttons; a double
            // click on the name renames the track.
            guard let r = row(atY: p.y) else { return }
            if let b = headerButtons(r).first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(p) }) {
                toggle(b.0, of: r.track)
            } else if e.clickCount == 2 {
                rename(r.track)
            }
            return
        }
        if p.y >= rulerHeight, let (r, c) = hit(p) {
            if e.modifierFlags.contains(.shift) {
                if selection.contains(c.id) { selection.remove(c.id); needsDisplay = true; return }
                selection.insert(c.id)
            } else if !selection.contains(c.id) {
                selection = [c.id]
            }
            let rect = clipRect(c, in: r)
            // A HyperFrames layer is view-only by hand (H-3): selectable, not dragged.
            let viewOnly = (try? project?.asset(c.asset).isHyperFrames) == true
            if !r.track.locked, !viewOnly {
                // Edge zones shrink on short clips so the middle can still be grabbed.
                let edge = min(7, rect.width / 4)
                if p.x - rect.minX < edge { drag = .trim(clip: c, edge: .start) }
                else if rect.maxX - p.x < edge { drag = .trim(clip: c, edge: .end) }
                else { drag = .move(clip: c, fromTrack: r.track.id, grabOffset: p.x - rect.minX) }
            }
        } else if p.y < rulerHeight, e.modifierFlags.contains(.option) {
            let t = time(atX: p.x)
            drag = .mark(from: t)
            markedRange = nil
        } else {
            if !e.modifierFlags.contains(.shift) { selection = [] }
            markedRange = nil
            drag = .scrub
            scrub(to: marker(at: p).map { x($0.time) } ?? p.x)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        dragPoint = convert(e.locationInWindow, from: nil)
        if !dragStarted, hypot(dragPoint.x - downPoint.x, dragPoint.y - downPoint.y) >= dragThreshold { dragStarted = true }
        if case .scrub = drag { scrub(to: dragPoint.x) }
        if case .mark(let from) = drag {
            let t = snapped(time(atX: dragPoint.x), excluding: EntityID(""))
            markedRange = t == from ? nil : (Time.min(from, t), Time.max(from, t))
        }
        autoscroll(with: e)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        guard let d = drag, let owner else { return }
        let p = convert(e.locationInWindow, from: nil)
        if case .scrub = d {} else if case .mark = d {} else if !dragStarted { return }   // a click, not a drag
        switch d {
        case .scrub, .mark:
            break
        case .move(let c, let from, let grab):
            let start = movedStart(c, grab: grab, at: p.x)
            let target = row(atY: p.y)?.track.id ?? from
            guard start != c.start || target != from else { return }
            var args: [String: JSONValue] = ["id": .string(c.id.raw), "start": .number(start.seconds)]
            if target != from { args["track"] = .string(target.raw) }
            Task { await owner.runTool("clip.move", .object(args)) }
        case .trim(let c, let edge):
            let t = trimmedTime(c, edge, at: p.x)
            guard t != (edge == .start ? c.start : c.end) else { return }
            Task { await owner.runTool("clip.trim", .object(["id": .string(c.id.raw), "edge": .string(edge.rawValue), "time": .number(t.seconds)])) }
        }
    }

    private var scrubTask: Task<Void, Never>?
    private func scrub(to px: CGFloat) {
        let t = time(atX: px)
        playhead = t
        pendingSeek = t
        scrubTask?.cancel()
        scrubTask = Task { [weak self] in
            await self?.owner?.runTool("player.seek", .object(["time": .number(t.seconds)]))
            if self?.pendingSeek == t { self?.pendingSeek = nil }
        }
    }

    /// Times an edge snaps to: other clips' edges and the playhead.
    private func snapTargets(excluding id: EntityID) -> [Time] {
        var out = [playhead, .zero] + (project?.markers.map(\.time) ?? [])
        for r in rows { for c in r.track.clips where c.id != id { out += [c.start, c.end] } }
        return out
    }

    /// `t`, pulled to the nearest edge or the playhead when it is close on screen.
    private func snapped(_ t: Time, excluding id: EntityID) -> Time {
        let best = snapTargets(excluding: id).min { abs($0.seconds - t.seconds) < abs($1.seconds - t.seconds) }
        guard let best, abs(CGFloat(best.seconds - t.seconds)) * pps <= snapDistance else { return t }
        return best
    }

    /// Where a trimmed edge goes: snapped, never past the clip's neighbours
    /// on its track (or past its own other edge).
    private func trimmedTime(_ c: Clip, _ edge: TrimClip.Edge, at px: CGFloat) -> Time {
        var t = snapped(time(atX: px), excluding: c.id)
        guard let track = rows.first(where: { $0.track.clips.contains { $0.id == c.id } })?.track,
              let i = track.clips.firstIndex(where: { $0.id == c.id }) else { return t }
        let frame = project?.settings.frameRate.frameDuration ?? Time(ticks: 1)
        if edge == .start {
            if i > 0 { t = Time.max(t, track.clips[i - 1].end) }
            t = Time.min(t, c.end - frame)
        } else {
            if i + 1 < track.clips.count { t = Time.min(t, track.clips[i + 1].start) }
            t = Time.max(t, c.start + frame)
        }
        return t
    }

    /// Where a dragged clip starts: its start or its end snaps, whichever is closer.
    private func movedStart(_ c: Clip, grab: CGFloat, at px: CGFloat) -> Time {
        let start = time(atX: px - grab)
        let byStart = snapped(start, excluding: c.id)
        let byEnd = snapped(start + c.duration, excluding: c.id) - c.duration
        let ds = abs(byStart.seconds - start.seconds), de = abs(byEnd.seconds - start.seconds)
        if byStart != start, ds <= de || byEnd == start { return byStart }
        if byEnd != start, byEnd.ticks >= 0 { return byEnd }
        return start
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        dirty.fill()
        guard let p = project else {
            let s = NSAttributedString(string: "No project open", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
            s.draw(at: NSPoint(x: 20, y: 40))
            return
        }
        let visible = visibleRect
        let t0 = Time(seconds: max(0, Double((dirty.minX - header) / pps)))
        let t1 = Time(seconds: max(0, Double((dirty.maxX - header) / pps)) + 1)

        for r in rows where NSRect(x: dirty.minX, y: r.y, width: dirty.width, height: r.height).intersects(dirty) {
            NSColor(white: r.track.kind == .main ? 0.17 : 0.15, alpha: 1).setFill()
            NSRect(x: dirty.minX, y: r.y, width: dirty.width, height: r.height).fill()
            var i = r.track.firstClipIndex(endingAfter: t0)
            while i < r.track.clips.count, r.track.clips[i].start < t1 {
                drawClip(r.track.clips[i], in: r, project: p)
                i += 1
            }
        }
        drawDragPreview()
        drawRuler(dirty, project: p)
        drawMarkers(dirty, project: p)
        if let m = markedRange {
            let rect = NSRect(x: x(m.start), y: 0, width: x(m.end) - x(m.start), height: bounds.height)
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            rect.fill()
            NSColor.systemBlue.setFill()
            NSRect(x: rect.minX, y: 0, width: rect.width, height: 4).fill()
        }
        // Track names stay at the left edge while scrolling.
        for r in rows {
            let h = NSRect(x: visible.minX, y: r.y, width: header, height: r.height)
            guard h.intersects(dirty) else { continue }
            NSColor(white: 0.1, alpha: 1).setFill()
            h.fill()
            let label = NSAttributedString(string: r.track.name, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
            label.draw(with: NSRect(x: h.minX + 8, y: h.minY + 5, width: header - 14, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            for (flag, rect) in headerButtons(r) { drawHeaderButton(flag, on: r.track, in: rect) }
        }
        // Playhead
        let px = x(playhead)
        NSColor.white.setFill()
        NSRect(x: px - 0.5, y: 0, width: 1.5, height: bounds.height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: px - 6, y: 0))
        tri.line(to: NSPoint(x: px + 6, y: 0))
        tri.line(to: NSPoint(x: px, y: 9))
        tri.close()
        tri.fill()
    }

    private func drawClip(_ c: Clip, in r: Row, project p: Project) {
        let rect = clipRect(c, in: r)
        let hf = (try? p.asset(c.asset).isHyperFrames) == true
        let base: NSColor = switch r.track.kind {
        case _ where hf: NSColor(calibratedRed: 0.78, green: 0.52, blue: 0.18, alpha: 1)
        case .main: NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.75, alpha: 1)
        case .overlay: NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.75, alpha: 1)
        case .audio: NSColor(calibratedRed: 0.25, green: 0.6, blue: 0.45, alpha: 1)
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (r.track.locked ? base.withAlphaComponent(0.5) : base).setFill()
        path.fill()
        if selection.contains(c.id) {
            NSColor.white.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            NSColor(white: 0, alpha: 0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        drawWaveform(c, in: rect, sound: r.track.kind == .audio)
        guard rect.width > 34 else { return }
        let name = (try? p.asset(c.asset).name) ?? c.asset.raw
        var text = hf ? "HyperFrames · \(name) · view-only" : name
        if abs(c.speed - 1) > 0.001 { text += String(format: "  %.2f×", c.speed) }
        let label = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.9), .font: NSFont.systemFont(ofSize: 10)])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: 4, dy: 2)).addClip()
        label.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 4))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Sound level as bars, CapCut-style: 2 px bars with a 1 px gap, each
    /// the loudest 10 ms block it covers. Sound clips get them across their
    /// height, mirrored about the middle; picture clips in a strip along the
    /// bottom. -50 dB and below draws nothing.
    private func drawWaveform(_ c: Clip, in rect: NSRect, sound: Bool) {
        guard let db = waveforms[c.asset], !db.isEmpty else { return }
        let visible = rect.intersection(visibleRect).insetBy(dx: 0, dy: 0)
        guard visible.width > 1 else { return }
        let bar: CGFloat = 2, gap: CGFloat = 1
        let area = sound ? rect.insetBy(dx: 0, dy: 14).offsetBy(dx: 0, dy: 6) : NSRect(x: rect.minX, y: rect.maxY - rect.height * 0.38 - 2, width: rect.width, height: rect.height * 0.38)
        guard area.height > 2 else { return }
        let hop = 0.01
        NSColor(white: 1, alpha: sound ? 0.55 : 0.4).setFill()
        let path = NSBezierPath()
        var x = rect.minX + floor((visible.minX - rect.minX) / (bar + gap)) * (bar + gap)
        while x < visible.maxX {
            let t0 = c.sourceStart.seconds + Double((x - rect.minX) / pps) * c.speed
            let t1 = t0 + Double((bar + gap) / pps) * c.speed
            let i0 = max(0, Int(t0 / hop)), i1 = min(db.count, max(i0 + 1, Int(ceil(t1 / hop))))
            if i0 < db.count {
                let level = db[i0..<i1].max() ?? -120
                let f = CGFloat(max(0, min(1, (level + 50) / 50)))
                let h = max(f > 0 ? 1 : 0, f * area.height)
                if h > 0 {
                    let r = sound ? NSRect(x: x, y: area.midY - h / 2, width: bar, height: h) : NSRect(x: x, y: area.maxY - h, width: bar, height: h)
                    path.appendRoundedRect(r, xRadius: 0.8, yRadius: 0.8)
                }
            }
            x += bar + gap
        }
        path.fill()
    }

    private func drawDragPreview() {
        guard let d = drag else { return }
        switch d {
        case .scrub, .mark: return
        case .move(let c, let from, let grab):
            guard dragStarted, let r = row(atY: dragPoint.y) ?? rows.first(where: { $0.track.id == from }) else { return }
            let start = movedStart(c, grab: grab, at: dragPoint.x)
            let rect = NSRect(x: x(start), y: r.y + 3, width: CGFloat(c.duration.seconds) * pps, height: r.height - 6)
            NSColor(white: 1, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        case .trim(let c, let edge):
            guard dragStarted else { return }
            NSColor.systemYellow.setFill()
            NSRect(x: x(trimmedTime(c, edge, at: dragPoint.x)) - 1, y: rulerHeight, width: 2, height: bounds.height).fill()
        }
    }

    // MARK: track header buttons

    enum TrackFlag: String { case locked, muted, hidden }

    /// The header's buttons, left to right: lock, then sound (main and
    /// audio tracks), then picture (picture tracks).
    private func headerButtons(_ r: Row) -> [(TrackFlag, NSRect)] {
        var flags: [TrackFlag] = [.locked]
        if r.track.kind != .overlay { flags.append(.muted) }
        if r.track.kind != .audio { flags.append(.hidden) }
        let size: CGFloat = 16, y = r.y + r.height - size - 5
        return flags.enumerated().map { i, f in (f, NSRect(x: visibleRect.minX + 8 + CGFloat(i) * (size + 6), y: y, width: size, height: size)) }
    }

    /// Where a track's lock, mute or hide button is (the self-test clicks it).
    func headerButtonPoint(_ track: EntityID, _ f: TrackFlag) -> NSPoint? {
        guard let r = rows.first(where: { $0.track.id == track }), let b = headerButtons(r).first(where: { $0.0 == f }) else { return nil }
        return NSPoint(x: b.1.midX, y: b.1.midY)
    }

    /// The x of a timeline time in this view.
    func xPosition(_ t: Time) -> CGFloat { x(t) }

    private func drawHeaderButton(_ f: TrackFlag, on t: Track, in rect: NSRect) {
        let on: Bool = switch f { case .locked: t.locked; case .muted: t.muted; case .hidden: t.hidden }
        let name: String = switch f {
        case .locked: on ? "lock.fill" : "lock.open"
        case .muted: on ? "speaker.slash.fill" : "speaker.wave.2"
        case .hidden: on ? "eye.slash.fill" : "eye"
        }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: f.rawValue)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) else { return }
        let tint = on ? NSColor.systemOrange : NSColor(white: 0.55, alpha: 1)
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    /// Flips a track's lock, mute or hide through track.set.
    func toggle(_ f: TrackFlag, of t: Track) {
        let value: Bool = switch f { case .locked: !t.locked; case .muted: !t.muted; case .hidden: !t.hidden }
        Task { await owner?.runTool("track.set", .object(["id": .string(t.id.raw), f.rawValue: .bool(value)])) }
    }

    private func rename(_ t: Track) {
        let alert = NSAlert()
        alert.messageText = "Rename track"
        let field = NSTextField(string: t.name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != t.name else { return }
        Task { await owner?.runTool("track.set", .object(["id": .string(t.id.raw), "name": .string(name)])) }
    }

    // MARK: markers

    /// The marker drawn near `p` in the ruler, if any.
    private func marker(at p: CGPoint) -> Marker? {
        guard p.y < rulerHeight, let ms = project?.markers else { return nil }
        return ms.min { abs(x($0.time) - p.x) < abs(x($1.time) - p.x) }.flatMap { abs(x($0.time) - p.x) <= 6 ? $0 : nil }
    }

    private func drawMarkers(_ dirty: NSRect, project p: Project) {
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemYellow, .font: NSFont.systemFont(ofSize: 9, weight: .semibold)]
        for m in p.markers {
            let mx = x(m.time)
            guard mx > dirty.minX - 120, mx < dirty.maxX + 6 else { continue }
            NSColor.systemYellow.setFill()
            let flag = NSBezierPath()
            flag.move(to: NSPoint(x: mx, y: rulerHeight))
            flag.line(to: NSPoint(x: mx, y: rulerHeight - 12))
            flag.line(to: NSPoint(x: mx + 7, y: rulerHeight - 9))
            flag.line(to: NSPoint(x: mx, y: rulerHeight - 6))
            flag.close()
            flag.fill()
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            NSRect(x: mx, y: rulerHeight, width: 1, height: bounds.height - rulerHeight).fill()
            if !m.name.isEmpty { NSAttributedString(string: m.name, attributes: attrs).draw(at: NSPoint(x: mx + 9, y: rulerHeight - 14)) }
        }
    }

    // MARK: right-click menus

    private var menuPoint: CGPoint = .zero

    override func menu(for e: NSEvent) -> NSMenu? {
        let p = convert(e.locationInWindow, from: nil)
        menuPoint = p
        let m = NSMenu()
        func item(_ t: String, _ a: Selector, _ obj: Any? = nil) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: "")
            i.target = self
            i.representedObject = obj
            m.addItem(i)
        }
        if let mk = marker(at: p) {
            item("Go to Marker", #selector(menuGoToMarker(_:)), mk.id.raw)
            item("Remove Marker", #selector(menuRemoveMarker(_:)), mk.id.raw)
            return m
        }
        if p.y < rulerHeight {
            item("Add Marker Here", #selector(menuAddMarker(_:)))
            return m
        }
        if p.x < visibleRect.minX + header, let r = row(atY: p.y) {
            let t = r.track
            item("Rename…", #selector(menuRenameTrack(_:)), t.id.raw)
            item(t.locked ? "Unlock" : "Lock", #selector(menuToggleTrack(_:)), "\(t.id.raw)|locked")
            if t.kind != .overlay { item(t.muted ? "Unmute" : "Mute", #selector(menuToggleTrack(_:)), "\(t.id.raw)|muted") }
            if t.kind != .audio { item(t.hidden ? "Show" : "Hide", #selector(menuToggleTrack(_:)), "\(t.id.raw)|hidden") }
            m.addItem(.separator())
            if t.kind != .main {
                item("Move Up", #selector(menuMoveTrack(_:)), "\(t.id.raw)|up")
                item("Move Down", #selector(menuMoveTrack(_:)), "\(t.id.raw)|down")
            }
            item("Add Overlay Track", #selector(menuAddTrack(_:)), "overlay")
            item("Add Audio Track", #selector(menuAddTrack(_:)), "audio")
            item("Close Gaps", #selector(menuCloseGaps(_:)), t.id.raw)
            if t.kind != .main {
                m.addItem(.separator())
                item("Remove Track…", #selector(menuRemoveTrack(_:)), t.id.raw)
            }
            return m
        }
        if let (_, c) = hit(p) {
            if !selection.contains(c.id) { selection = [c.id]; needsDisplay = true }
            item("Split at Playhead", #selector(menuBinding(_:)), "split")
            item("Copy", #selector(menuBinding(_:)), "copy")
            item("Duplicate", #selector(menuBinding(_:)), "duplicate")
            item("Delete", #selector(menuBinding(_:)), "delete")
            m.addItem(.separator())
            item("Extract Audio", #selector(menuBinding(_:)), "extractAudio")
            item("Freeze Frame at Playhead", #selector(menuBinding(_:)), "freeze")
            if abs(c.speed - 1) > 0.001 { item("Normal Speed", #selector(menuBinding(_:)), "speed1") }
            return m
        }
        item("Paste at Playhead", #selector(menuBinding(_:)), "paste")
        item("Add Marker at Playhead", #selector(menuBinding(_:)), "marker")
        return m
    }

    private func split(_ obj: Any?) -> (EntityID, String)? {
        guard let s = obj as? String, let bar = s.firstIndex(of: "|") else { return nil }
        return (EntityID(String(s[..<bar])), String(s[s.index(after: bar)...]))
    }

    @objc private func menuGoToMarker(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String, let mk = project?.markers.first(where: { $0.id.raw == id }) else { return }
        scrub(to: x(mk.time))
    }
    @objc private func menuRemoveMarker(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String else { return }
        Task { await owner?.runTool("marker.remove", .object(["ids": .array([.string(id)])])) }
    }
    @objc private func menuAddMarker(_ i: NSMenuItem) {
        let t = time(atX: menuPoint.x)
        Task { await owner?.runTool("marker.add", .object(["time": .number(t.seconds)])) }
    }
    @objc private func menuRenameTrack(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String, let t = project?.tracks.first(where: { $0.id.raw == id }) else { return }
        rename(t)
    }
    @objc private func menuToggleTrack(_ i: NSMenuItem) {
        guard let (id, f) = split(i.representedObject), let t = project?.tracks.first(where: { $0.id == id }), let flag = TrackFlag(rawValue: f) else { return }
        toggle(flag, of: t)
    }
    @objc private func menuMoveTrack(_ i: NSMenuItem) {
        guard let (id, dir) = split(i.representedObject), let p = project, let idx = p.tracks.firstIndex(where: { $0.id == id }) else { return }
        // Pictures stack bottom to top (higher index draws on top, shown higher);
        // sound tracks are listed in index order downwards.
        let visualUp = dir == "up"
        let delta = p.tracks[idx].kind == .audio ? (visualUp ? -1 : 1) : (visualUp ? 1 : -1)
        let to = max(0, min(p.tracks.count - 1, idx + delta))
        guard to != idx else { return }
        Task { await owner?.runTool("track.reorder", .object(["id": .string(id.raw), "index": .number(Double(to))])) }
    }
    @objc private func menuAddTrack(_ i: NSMenuItem) {
        guard let kind = i.representedObject as? String else { return }
        Task { await owner?.runTool("track.add", .object(["kind": .string(kind)])) }
    }
    @objc private func menuCloseGaps(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String else { return }
        Task { await owner?.runTool("timeline.closeGaps", .object(["track": .string(id)])) }
    }
    @objc private func menuRemoveTrack(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String, let t = project?.tracks.first(where: { $0.id.raw == id }) else { return }
        var force = false
        if !t.clips.isEmpty {
            let a = NSAlert()
            a.messageText = "Remove the track \"\(t.name)\" and its \(t.clips.count) clips?"
            a.informativeText = "Undo brings them back."
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            force = true
        }
        Task { await owner?.runTool("track.remove", .object(["id": .string(id), "force": .bool(force)])) }
    }
    @objc private func menuBinding(_ i: NSMenuItem) {
        guard let what = i.representedObject as? String, let owner else { return }
        switch what {
        case "split": owner.runBinding(tool: "timeline.split", args: .object(["time": .string("$playhead"), "tracks": .string("$selectedTracks")]))
        case "copy": owner.runBinding(tool: "ui.copy", args: nil)
        case "duplicate": owner.runBinding(tool: "clip.duplicate", args: .object(["ids": .string("$selection")]))
        case "delete": owner.runBinding(tool: "clip.remove", args: .object(["ids": .string("$selection")]))
        case "extractAudio": owner.runBinding(tool: "clip.detachAudio", args: .object(["ids": .string("$selection")]))
        case "freeze": owner.runBinding(tool: "clip.freezeFrame", args: .object(["time": .string("$playhead")]))
        case "speed1": owner.runBinding(tool: "clip.setSpeed", args: .object(["ids": .string("$selection"), "speed": .number(1)]))
        case "paste": owner.runBinding(tool: "clip.copyTo", args: .object(["ids": .string("$copied"), "start": .string("$playhead")]))
        case "marker": owner.runBinding(tool: "marker.add", args: .object(["time": .string("$playhead")]))
        default: break
        }
    }

    // MARK: dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, let owner else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let t = time(atX: max(header, p.x))
        let track = row(atY: p.y)?.track.id
        Task { await owner.importAndAppend(urls, at: t, track: track) }
        return true
    }

    private func drawRuler(_ dirty: NSRect, project p: Project) {
        let r = NSRect(x: dirty.minX, y: 0, width: dirty.width, height: rulerHeight)
        NSColor(white: 0.08, alpha: 1).setFill()
        r.fill()
        // Pick a label step that keeps labels about 80 px apart.
        let steps: [Double] = [1.0 / 60, 1.0 / 30, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400]
        let step = steps.first { $0 * Double(pps) >= 80 } ?? 14400
        var t = (Double((dirty.minX - header) / pps) / step).rounded(.down) * step
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor,
                                                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)]
        while header + CGFloat(t) * pps < dirty.maxX {
            if t >= 0 {
                let px = header + CGFloat(t) * pps
                NSColor(white: 0.35, alpha: 1).setFill()
                NSRect(x: px, y: rulerHeight - 8, width: 1, height: 8).fill()
                NSAttributedString(string: MainWindowController.format(Time(seconds: t)), attributes: attrs)
                    .draw(at: NSPoint(x: px + 3, y: 4))
            }
            t += step
        }
    }
}
