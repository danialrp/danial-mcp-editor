import AppKit
import EditorCore
import EditorKit
import MediaEngine
import UniformTypeIdentifiers
import WebKit

/// The owner's accent colour for motion graphics (the hyperframes skill's
/// colour gate, native): any RGB colour, a two-stop gradient or three free
/// colours, picked on the video's own frame with a live preview of the kit
/// (on the frame, a cinematic scene, a full-screen cutaway). Saving runs
/// project.setAccent, like an agent's call; agents read it with accent.get.
@MainActor
final class AccentPanel: NSView, NSTextFieldDelegate {
    weak var owner: MainWindowController?
    private var project: Project?
    /// The working pick: always three stops, the mode says how many are used.
    private var accent = Accent(mode: .solid, stops: ["#FF2D55", "#7A3CFF", "#2E6BF0"])
    /// The hand-picked light colour, kept while the mix is on.
    private var handHi = "#FFFFFF"
    private var saved: Accent?

    private let mode = NSSegmentedControl(labels: ["Solid", "Gradient", "Three colours"], trackingMode: .selectOne, target: nil, action: nil)
    private let wells = [NSColorWell(style: .expanded), NSColorWell(style: .expanded), NSColorWell(style: .expanded)]
    private let hexes = [NSTextField(), NSTextField(), NSTextField()]
    private var rowLabels: [NSTextField] = []
    private var rows: [NSView] = []
    private let angle = NSSlider(value: 135, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let angleLabel = NSTextField(labelWithString: "135°")
    private var angleRow: NSView!
    private let hiMode = NSSegmentedControl(labels: ["Mix from colour 1", "Pick by hand"], trackingMode: .selectOne, target: nil, action: nil)
    private let hi = NSSlider(value: 72, minValue: 30, maxValue: 95, target: nil, action: nil)
    private let hiLabel = NSTextField(labelWithString: "72%")
    private var hiAutoRow: NSView!
    private let hiWell = NSColorWell(style: .expanded)
    private let hiHex = NSTextField()
    private var hiManualRow: NSView!
    private let blank = NSButton(checkboxWithTitle: "Blank frame", target: nil, action: nil)
    private let metrics = NSTextField(labelWithString: "")
    private let css = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let preview = AccentPreview()
    private var previewHeight: NSLayoutConstraint!
    private var frameTask: Task<Void, Never>?
    private var frameFor: Time?
    /// A picture the owner chose instead of the playhead frame.
    private var ownImage = false

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, _ width: CGFloat = 92) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        return l
    }

    private func button(_ t: String, _ a: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: a)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func dropper(_ tag: Int) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Eyedropper")!, target: self, action: #selector(eyedropper(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.tag = tag
        b.toolTip = "Pick the colour from anywhere on the screen, the video too"
        return b
    }

    private func setUp(_ w: NSColorWell, _ f: NSTextField) {
        w.target = self
        w.action = #selector(wellChanged(_:))
        w.widthAnchor.constraint(equalToConstant: 70).isActive = true
        f.delegate = self
        f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        f.widthAnchor.constraint(equalToConstant: 80).isActive = true
    }

    private func build() {
        let title = NSTextField(labelWithString: "Accent colour for motion graphics")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Pick on the video's own frame with the eyedropper, or in the colour wells. Save makes it the project's accent; HyperFrames compositions take it with accent.writeCSS.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        mode.target = self
        mode.action = #selector(changed)
        mode.selectedSegment = 0
        for i in 0..<3 {
            setUp(wells[i], hexes[i])
            let l = label("Colour \(i + 1)")
            rowLabels.append(l)
            rows.append(NSStackView(views: [l, wells[i], hexes[i], dropper(i)]))
        }
        setUp(hiWell, hiHex)
        angle.target = self; angle.action = #selector(changed)
        hi.target = self; hi.action = #selector(changed)
        hiMode.target = self; hiMode.action = #selector(hiModeChanged)
        hiMode.selectedSegment = 0
        for s in [angle, hi] { s.widthAnchor.constraint(equalToConstant: 150).isActive = true }
        blank.target = self; blank.action = #selector(blankChanged)
        metrics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metrics.maximumNumberOfLines = 4
        css.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        css.isSelectable = true
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)

        angleRow = NSStackView(views: [label("Angle"), angle, angleLabel])
        let hiTitle = NSTextField(labelWithString: "Light variant (--acc-hi)")
        hiTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        hiAutoRow = NSStackView(views: [label("Mix with white"), hi, hiLabel])
        hiManualRow = NSStackView(views: [label("Light colour"), hiWell, hiHex, dropper(3)])
        let readTitle = NSTextField(labelWithString: "Readability")
        readTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        let frameRow = NSStackView(views: [blank, button("Other image…", #selector(otherImage)), button("Playhead frame", #selector(playheadFrame))])
        let buttons = NSStackView(views: [button("Save pick", #selector(save)), button("Copy CSS", #selector(copyCSS)), button("Clear", #selector(clear))])
        let stack = NSStackView(views: [title, hint, mode] + rows + [angleRow, hiTitle, hiMode, hiAutoRow, hiManualRow,
                                        frameRow, preview, readTitle, metrics, css, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 14, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Taller than the window: the panel scrolls.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 600)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            css.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            previewHeight,
        ])
        show()
    }

    override func layout() {
        super.layout()
        let h = AccentPreview.height(forWidth: preview.bounds.width)
        if preview.bounds.width > 0, abs(previewHeight.constant - h) > 0.5 { previewHeight.constant = h }
    }

    // MARK: state

    /// Saved and working pick are the same choice.
    private func same(_ a: Accent?, _ b: Accent) -> Bool {
        guard let a else { return false }
        return a.mode == b.mode && a.used == b.used && (a.mode != .gradient || a.angle == b.angle)
            && a.hiManual == b.hiManual && a.accHi == b.accHi
    }

    private func statusText() -> String {
        saved == nil ? "No accent saved yet." : (same(saved, accent) ? "Saved." : "Not saved yet.")
    }

    func update(project p: Project?) {
        project = p
        if p?.accent != saved {
            saved = p?.accent
            if let a = saved {
                var stops = accent.stops
                for (i, s) in a.used.enumerated() { stops[i] = s }
                accent = Accent(mode: a.mode, stops: stops, angle: a.angle, hiPercent: a.hiPercent, hiColor: a.hiColor)
                if let h = a.hiColor { handHi = h }
            }
            show()
        }
        status.stringValue = statusText()
    }

    /// Shows the frame under the playhead behind the preview shapes.
    func playheadMoved(_ t: Time) {
        guard !ownImage, window != nil, !isHiddenOrHasHiddenAncestor, t != frameFor, let owner else { return }
        frameFor = t
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)   // only once the playhead rests
            guard !Task.isCancelled, let built = owner.runtime.player.built else { return }
            let image = try? await FrameCapture.timelineFrame(built, at: t, maxWidth: 720)
            guard !Task.isCancelled, self?.ownImage == false else { return }
            self?.preview.frame(image)
        }
    }

    private func show() {
        mode.selectedSegment = Accent.Mode.allCases.firstIndex(of: accent.mode) ?? 0
        for i in 0..<3 {
            wells[i].color = Self.color(accent.stops[i])
            hexes[i].stringValue = accent.stops[i]
        }
        angle.doubleValue = accent.angle
        hi.doubleValue = accent.hiPercent
        hiMode.selectedSegment = accent.hiManual ? 1 : 0
        hiWell.color = Self.color(handHi)
        hiHex.stringValue = handHi
        refresh()
    }

    private func refresh() {
        let n = Accent.count(accent.mode)
        for i in 0..<3 { rows[i].isHidden = i >= n }
        rowLabels[0].stringValue = accent.mode == .solid ? "Colour" : accent.mode == .gradient ? "Start colour" : "Colour 1"
        rowLabels[1].stringValue = accent.mode == .gradient ? "End colour" : "Colour 2"
        angleRow.isHidden = accent.mode != .gradient
        hiAutoRow.isHidden = accent.hiManual
        hiManualRow.isHidden = !accent.hiManual
        angleLabel.stringValue = "\(Int(accent.angle))°"
        hiLabel.stringValue = "\(Int(accent.hiPercent))%"
        let c = accent.inkContrasts
        let ok = accent.inkContrast >= 4.5, glassOK = accent.glassContrast >= 4.5
        var lines = [String(format: "Ink %@ on the colour: %.2f:1 %@", accent.ink == Accent.dark ? "dark \(Accent.dark)" : "white", accent.inkContrast, ok ? "✓" : "✗"),
                     String(format: "Dark / white on the colour: %.2f · %.2f", c.dark, c.white),
                     String(format: "Colour on dark glass: %.2f:1 %@", accent.glassContrast, glassOK ? "✓" : "✗")]
        if !ok { lines.append("No ink reaches 4.5 on every colour") }
        metrics.stringValue = lines.joined(separator: "\n")
        metrics.textColor = ok ? .labelColor : .systemRed
        css.stringValue = accent.css
        preview.accent = accent
        if project != nil { status.stringValue = statusText() }
    }

    // MARK: actions

    @objc private func changed() {
        accent.mode = Accent.Mode.allCases[max(0, mode.selectedSegment)]
        accent.angle = angle.doubleValue.rounded()
        accent.hiPercent = hi.doubleValue.rounded()
        refresh()
    }

    @objc private func hiModeChanged() {
        if hiMode.selectedSegment == 1 {
            // Starts from the colour the mix gives now, as the skill's picker does.
            if !accent.hiManual { handHi = accent.accHi }
            accent.hiColor = handHi
        } else {
            accent.hiColor = nil
        }
        show()
    }

    @objc private func blankChanged() { preview.hideKit = blank.state == .on }

    private func set(_ target: Int, _ hex: String) {
        if target == 3 {
            handHi = hex
            accent.hiColor = hex
        } else {
            accent.stops[target] = hex
        }
        show()
    }

    @objc private func wellChanged(_ w: NSColorWell) {
        if w === hiWell { set(3, Self.hex(w.color)) } else if let i = wells.firstIndex(where: { $0 === w }) { set(i, Self.hex(w.color)) }
    }

    @objc private func eyedropper(_ b: NSButton) {
        let target = b.tag
        NSColorSampler().show { [weak self] c in
            guard let c else { return }
            MainActor.assumeIsolated { self?.set(target, Self.hex(c)) }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let rgb = Accent.rgb(f.stringValue) else { show(); return }
        let hex = Accent.hex(rgb.0, rgb.1, rgb.2)
        if f === hiHex { set(3, hex) } else if let i = hexes.firstIndex(where: { $0 === f }) { set(i, hex) }
    }

    @objc private func otherImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary)
        else { return }
        ownImage = true
        frameTask?.cancel()
        preview.frame(image)
    }

    @objc private func playheadFrame() {
        ownImage = false
        frameFor = nil
        if let t = owner?.runtime.player.currentTime { playheadMoved(t) }
    }

    @objc private func save() {
        guard let owner else { return }
        var args: [String: JSONValue] = ["mode": .string(accent.mode.rawValue), "stops": .array(accent.used.map { .string($0) }),
                                         "hiPercent": .number(accent.hiPercent), "hiColor": .string(accent.hiColor ?? "auto")]
        if accent.mode == .gradient { args["angle"] = .number(accent.angle) }
        Task { await owner.runTool("project.setAccent", .object(args)) }
    }

    @objc private func clear() {
        guard let owner else { return }
        Task { await owner.runTool("project.setAccent", .object(["mode": .string("none")])) }
    }

    @objc private func copyCSS() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accent.css, forType: .string)
        status.stringValue = "CSS copied."
    }

    static func color(_ hex: String) -> NSColor {
        guard let (r, g, b) = Accent.rgb(hex) else { return .red }
        return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return Accent.hex(s.redComponent * 255, s.greenComponent * 255, s.blueComponent * 255)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The preview never scrolls itself: the wheel scrolls the panel around it.
private final class PassScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// The kit in the accent, as the skill's picker shows it: on the video's
/// frame (filled pill, liquid-glass card, solid and glass orbs, glass pill,
/// a key word in a big white line, soft dashes), a cinematic scene in the
/// three colours, and a full-screen cutaway in the colour. Drawn by WebKit
/// with the kit's own CSS, so glass, glow and gradient text look as in the
/// render.
@MainActor
final class AccentPreview: NSView, WKNavigationDelegate {
    var accent = Accent(mode: .solid, stops: ["#FF2D55"]) { didSet { push() } }
    var hideKit = false { didSet { run("hideKit(\(hideKit))") } }
    private let web: PassScrollWebView
    private var loaded = false
    private var pending: [String] = []
    private var frameURL: String?

    /// The main stage at most this wide; the other two share a row below it.
    static let mainWidth: CGFloat = 340, gap: CGFloat = 10

    static func height(forWidth w: CGFloat) -> CGFloat {
        let main = min(w, mainWidth), small = (w - gap) / 2
        return (main * 16 / 9 + gap + small * 16 / 9).rounded(.up)
    }

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        web = PassScrollWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        web.loadHTMLString(Self.page, baseURL: nil)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        push()
        if let frameURL { run("setFrame(\(Self.quoted(frameURL)))") }
        run("hideKit(\(hideKit))")
        for js in pending { webView.evaluateJavaScript(js) }
        pending = []
    }

    func frame(_ image: CGImage?) {
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        frameURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        if loaded, let frameURL { web.evaluateJavaScript("setFrame(\(Self.quoted(frameURL)))") }
    }

    private func run(_ js: String) {
        if loaded { web.evaluateJavaScript(js) } else { pending.append(js) }
    }

    private func push() {
        guard loaded else { return }
        let a = accent
        let vars = ["--acc": a.acc, "--acc2": a.acc2, "--acc-hi": a.accHi, "--acc-ink": a.ink,
                    "--ang": "\(Int(a.mode == .gradient ? a.angle : 135))deg", "--c1": a.c1, "--c2": a.c2, "--c3": a.c3]
        let obj = vars.map { "\(Self.quoted($0.key)):\(Self.quoted($0.value))" }.joined(separator: ",")
        web.evaluateJavaScript("setVars({\(obj)})")
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The preview page: the kit's CSS on three 1080 × 1920 stages, scaled to fit.
    static let page = #"""
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <style>
    :root { --acc: #FF0000; --acc2: #FF0000; --acc-hi: #FFB8B8; --acc-ink: #0A0A12; --ang: 135deg;
      --c1: #FF0000; --c2: #FF0000; --c3: #FF0000;
      --acc-grad: linear-gradient(var(--ang), var(--acc), var(--acc2));
      --glow: color-mix(in srgb, var(--acc) 55%, transparent); --glass: rgba(12, 13, 20, .58); }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: transparent; overflow: hidden; font-family: -apple-system, "SF Pro Display", sans-serif; }
    .wrap { display: flex; flex-direction: column; align-items: center; gap: 10px; }
    .row2 { display: flex; gap: 10px; width: 100%; }
    .vp { position: relative; border-radius: 12px; overflow: hidden; background: #000; flex: 0 0 auto; }
    .cap { position: absolute; top: 6px; left: 6px; z-index: 5; font: 700 10px -apple-system, sans-serif; background: rgba(0,0,0,.55); padding: 1px 7px; border-radius: 5px; color: #ddd; }
    .stage { position: absolute; left: 0; top: 0; width: 1080px; height: 1920px; transform-origin: 0 0; overflow: hidden; }
    .stage img.bg { position: absolute; inset: 0; width: 1080px; height: 1920px; object-fit: cover; }
    #stMain { background: #15161c; }
    #stCine { background: #05060D; color: #fff; }
    #stCine .au { position: absolute; border-radius: 50%; filter: blur(120px); opacity: .55; }
    #stCine .w { position: absolute; left: 60px; width: 960px; text-align: center; font-weight: 900; white-space: nowrap; line-height: 1.25; }
    #stCine .gl { text-shadow: 0 0 18px var(--c1), 0 0 60px color-mix(in srgb, var(--c1) 60%, transparent), 0 0 120px color-mix(in srgb, var(--c2) 55%, transparent); }
    #stCine .gr { background: linear-gradient(100deg, var(--c1), var(--c2) 55%, var(--c3)); -webkit-background-clip: text; background-clip: text; color: transparent; filter: drop-shadow(0 0 26px color-mix(in srgb, var(--c2) 75%, transparent)); }
    #stCine .tl { position: absolute; width: 280px; height: 280px; border-radius: 68px; background: linear-gradient(160deg, rgba(255,255,255,.16), rgba(255,255,255,.04)); border: 3px solid rgba(255,255,255,.55); box-shadow: 0 0 40px color-mix(in srgb, var(--c2) 70%, transparent); }
    #stCine .tl i { position: absolute; left: 60px; top: 60px; width: 160px; height: 160px; border-radius: 42px; background: linear-gradient(135deg, var(--c1), var(--c2)); }
    #stCine .nd { position: absolute; width: 150px; height: 150px; border-radius: 75px; background: radial-gradient(circle at 35% 30%, #3A4660, #0B0E1A 64%); border: 5px solid var(--c1); box-shadow: 0 0 26px var(--c1), 0 0 80px color-mix(in srgb, var(--c1) 45%, transparent); text-align: center; line-height: 140px; font-size: 76px; font-weight: 900; }
    #stCine .bx { position: absolute; left: 290px; top: 1560px; width: 500px; height: 150px; border-radius: 34px; background: linear-gradient(100deg, var(--c1), var(--c2)); color: var(--acc-ink); text-align: center; line-height: 150px; font-size: 96px; font-weight: 900; box-shadow: 0 0 40px color-mix(in srgb, var(--c2) 70%, transparent); }
    .k { position: absolute; }
    .k-vio { height: 96px; padding: 0 44px; border-radius: 48px; display: flex; align-items: center; gap: 16px; white-space: nowrap; font-weight: 700; font-size: 46px; background: var(--acc-grad); color: var(--acc-ink); box-shadow: 0 0 34px var(--glow); }
    .k-gl { height: 80px; padding: 0 34px; border-radius: 40px; display: flex; align-items: center; gap: 14px; white-space: nowrap; font-weight: 700; font-size: 38px; color: #fff; background: var(--glass); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); box-shadow: 0 12px 30px rgba(0,0,0,.28); }
    .k-gl svg * { fill: none; stroke: var(--acc); stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round; }
    .k-vio svg * { fill: none; stroke: currentColor; stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round; }
    .k-glass { border-radius: 36px; overflow: hidden; background: var(--glass); backdrop-filter: blur(22px); -webkit-backdrop-filter: blur(22px); box-shadow: 0 30px 70px rgba(0,0,0,.35), 0 0 0 1px rgba(255,255,255,.06); padding: 30px 34px; }
    .k-glass::before, .k-gl::before, .k-orb.g::before { content: ""; position: absolute; inset: 0; border-radius: inherit; padding: 1.5px; pointer-events: none;
      background: linear-gradient(140deg, rgba(255,255,255,.62), rgba(255,255,255,.10) 32%, rgba(255,255,255,.04) 62%, var(--acc) 100%);
      -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0); -webkit-mask-composite: xor; mask-composite: exclude; }
    .gv { background: var(--acc-grad); -webkit-background-clip: text; background-clip: text; color: transparent; }
    .k-orb { border-radius: 50%; background: var(--acc-grad); box-shadow: 0 0 0 9px color-mix(in srgb, var(--acc) 20%, transparent), 0 0 40px var(--glow); }
    .k-orb.g { background: var(--glass); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); box-shadow: 0 12px 30px rgba(0,0,0,.3); }
    .k-orb svg { position: absolute; left: 22%; top: 22%; width: 56%; height: 56%; overflow: visible; }
    .k-orb svg * { fill: none; stroke: var(--acc-ink); stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; }
    .k-orb.g svg * { stroke: var(--acc); }
    .k-t { font-weight: 900; color: #fff; white-space: nowrap; }
    .k-s { font-weight: 500; color: var(--acc-hi); white-space: nowrap; }
    .k-big { left: 40px; right: 40px; text-align: center; font-weight: 900; font-size: 116px; line-height: 160px; white-space: nowrap; color: #fff; text-shadow: 0 4px 30px rgba(0,0,0,.35); }
    .k-big .gv { text-shadow: none; filter: drop-shadow(0 0 20px var(--glow)); }
    .k-dash { fill: none; stroke: var(--acc-hi); stroke-width: 7; stroke-linecap: round; stroke-dasharray: 1 20; filter: blur(1.6px) drop-shadow(0 0 7px var(--glow)); }
    .k-cutsolid { position: absolute; inset: 0; background: var(--acc-grad); }
    .k-cutsolid .k-big { color: var(--acc-ink); text-shadow: none; }
    .hide-k .k, .hide-k svg.lines { display: none; }
    </style></head><body>
    <div class="wrap">
      <div class="vp" id="vpMain"><span class="cap">On the frame</span>
        <div class="stage" id="stMain">
          <img class="bg" id="bgMain" alt="" hidden>
          <svg class="lines" width="1080" height="1920" style="position:absolute;left:0;top:0;overflow:visible"><path class="k-dash" d="M 750 1230 C 780 1290 780 1330 720 1370"/></svg>
          <div class="k k-vio" style="left:50%;top:250px;transform:translateX(-50%)"><svg width="40" height="40" viewBox="0 0 24 24"><path d="M5 12l4 4 10-10"/></svg>Key word 123</div>
          <div class="k k-glass" style="left:50px;top:700px;width:380px">
            <div class="k-t gv" style="font-size:74px;line-height:96px">24%</div>
            <div class="k-t" style="font-size:40px;line-height:58px">Text on glass</div>
            <div class="k-s" style="font-size:30px;line-height:46px">Light subtitle</div>
          </div>
          <div class="k k-orb" style="left:900px;top:720px;width:140px;height:140px"><svg viewBox="0 0 24 24"><path d="M12 3l2.6 5.6 6 .7-4.5 4.1 1.2 6L12 16.4 6.7 19.4l1.2-6L3.4 9.3l6-.7z"/></svg></div>
          <div class="k k-orb g" style="left:900px;top:930px;width:140px;height:140px"><svg viewBox="0 0 24 24"><path d="M4 12h16M12 4v16"/></svg></div>
          <div class="k k-gl" style="left:60px;top:1260px"><svg width="34" height="34" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>Glass pill</div>
          <div class="k k-big" style="top:1460px">This <span class="gv">word</span> matters</div>
        </div>
      </div>
      <div class="row2">
        <div class="vp" id="vpCine"><span class="cap">Cinematic scene</span>
          <div class="stage" id="stCine">
            <div class="au" style="left:-200px;top:150px;width:800px;height:800px;background:var(--c1)"></div>
            <div class="au" style="left:480px;top:650px;width:900px;height:900px;background:var(--c2)"></div>
            <div class="au" style="left:60px;top:1300px;width:700px;height:700px;background:var(--c3);opacity:.4"></div>
            <div class="w gl" style="top:290px;font-size:190px">Word</div>
            <div class="tl" style="left:210px;top:620px"><i></i></div><div class="tl" style="left:590px;top:620px"><i style="background:linear-gradient(135deg,var(--c2),var(--c3))"></i></div>
            <div class="w gr" style="top:960px;font-size:170px">Key</div>
            <svg width="1080" height="1920" style="position:absolute;left:0;top:0"><defs><linearGradient id="cg" x1="0" x2="1"><stop offset="0" stop-color="var(--c1)"/><stop offset=".5" stop-color="var(--c2)"/><stop offset="1" stop-color="var(--c3)"/></linearGradient></defs>
              <path d="M335 1380 H465 M615 1380 H745" stroke="url(#cg)" stroke-width="22" opacity=".8" style="filter:blur(12px)"/><path d="M335 1380 H465 M615 1380 H745" stroke="#fff" stroke-width="7"/></svg>
            <div class="nd" style="left:185px;top:1305px">1</div><div class="nd" style="left:465px;top:1305px;border-color:var(--c2);box-shadow:0 0 26px var(--c2)">2</div><div class="nd" style="left:745px;top:1305px;border-color:var(--c3);box-shadow:0 0 26px var(--c3)">3</div>
            <div class="bx">Box</div>
          </div>
        </div>
        <div class="vp" id="vpCut"><span class="cap">Full-screen cutaway</span>
          <div class="stage" id="stCut">
            <div class="k-cutsolid">
              <div class="k k-big" style="top:700px">Cutaway</div>
              <div class="k k-glass" style="left:50%;top:960px;transform:translateX(-50%);width:640px;text-align:center">
                <div class="k-t" style="font-size:52px;line-height:72px">Glass card</div>
                <div class="k-s" style="font-size:34px;line-height:50px">Subtitle</div>
              </div>
              <div class="k k-orb g" style="left:470px;top:1260px;width:140px;height:140px"><svg viewBox="0 0 24 24"><path d="M5 12l4 4 10-10"/></svg></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <script>
    function setVars(v) { for (const k in v) document.documentElement.style.setProperty(k, v[k]); }
    function setFrame(url) { const i = document.getElementById("bgMain"); i.src = url; i.hidden = false; }
    function hideKit(on) { document.getElementById("stMain").classList.toggle("hide-k", on); }
    function fit() {
      const W = document.documentElement.clientWidth, main = Math.min(W, 340), small = (W - 10) / 2;
      const size = (id, w) => { const vp = document.getElementById(id); vp.style.width = w + "px"; vp.style.height = w * 16 / 9 + "px"; vp.querySelector(".stage").style.transform = "scale(" + (w / 1080) + ")"; };
      size("vpMain", main); size("vpCine", small); size("vpCut", small);
    }
    new ResizeObserver(fit).observe(document.documentElement); fit();
    </script>
    </body></html>
    """#
}
