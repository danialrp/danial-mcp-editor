import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// The owner's accent colour for motion graphics (the hyperframes skill's
/// colour gate, native): any RGB colour or a two-stop gradient, picked on the
/// video's own frame with a live preview of the kit's shapes. Saving runs
/// project.setAccent, like an agent's call; agents read it with accent.get.
@MainActor
final class AccentPanel: NSView, NSTextFieldDelegate {
    weak var owner: MainWindowController?
    private var project: Project?
    private var accent = Accent(mode: .solid, stops: ["#FF2D55", "#7A3CFF"])
    private var saved: Accent?

    private let mode = NSSegmentedControl(labels: ["Solid", "Gradient"], trackingMode: .selectOne, target: nil, action: nil)
    private let well1 = NSColorWell(style: .expanded), well2 = NSColorWell(style: .expanded)
    private let hex1 = NSTextField(), hex2 = NSTextField()
    private let angle = NSSlider(value: 135, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let angleLabel = NSTextField(labelWithString: "135°")
    private let hi = NSSlider(value: 72, minValue: 30, maxValue: 95, target: nil, action: nil)
    private let hiLabel = NSTextField(labelWithString: "72%")
    private let metrics = NSTextField(labelWithString: "")
    private let css = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let preview = AccentPreview()
    private var row2: NSView!
    private var angleRow: NSView!
    private var frameTask: Task<Void, Never>?
    private var frameFor: Time?

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

    private func build() {
        let title = NSTextField(labelWithString: "Accent colour for motion graphics")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Pick on the video's own frame: the colour wells have an eyedropper (the loupe in the colour panel). Save makes it the project's accent; HyperFrames compositions take it with accent.writeCSS.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        mode.target = self
        mode.action = #selector(changed)
        mode.selectedSegment = 0
        for w in [well1, well2] { w.target = self; w.action = #selector(wellChanged(_:)); w.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        for f in [hex1, hex2] { f.delegate = self; f.font = .monospacedSystemFont(ofSize: 11, weight: .regular); f.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        angle.target = self; angle.action = #selector(changed)
        hi.target = self; hi.action = #selector(changed)
        for s in [angle, hi] { s.widthAnchor.constraint(equalToConstant: 150).isActive = true }
        metrics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metrics.maximumNumberOfLines = 3
        css.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        css.isSelectable = true
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        preview.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let row1 = NSStackView(views: [label("Colour"), well1, hex1])
        row2 = NSStackView(views: [label("Colour 2"), well2, hex2])
        angleRow = NSStackView(views: [label("Angle"), angle, angleLabel])
        let hiRow = NSStackView(views: [label("Light variant"), hi, hiLabel])
        let buttons = NSStackView(views: [button("Save pick", #selector(save)), button("Copy CSS", #selector(copyCSS)), button("Clear", #selector(clear))])
        let stack = NSStackView(views: [title, hint, mode, row1, row2, angleRow, hiRow, preview, metrics, css, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            css.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        show()
    }

    // MARK: state

    func update(project p: Project?) {
        project = p
        if p?.accent != saved {
            saved = p?.accent
            if let a = saved { accent = a }
            show()
        }
        status.stringValue = saved == nil ? "No accent saved yet." : (saved == accent ? "Saved." : "Not saved yet.")
    }

    /// Shows the frame under the playhead behind the preview shapes.
    func playheadMoved(_ t: Time) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, t != frameFor, let owner else { return }
        frameFor = t
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)   // only once the playhead rests
            guard !Task.isCancelled, let built = owner.runtime.player.built else { return }
            let image = try? await FrameCapture.timelineFrame(built, at: t, maxWidth: 640)
            guard !Task.isCancelled else { return }
            self?.preview.frame(image)
        }
    }

    private func show() {
        mode.selectedSegment = accent.mode == .gradient ? 1 : 0
        let stops = accent.stops + Array(repeating: accent.stops.first ?? "#FF2D55", count: max(0, 2 - accent.stops.count))
        well1.color = Self.color(stops[0])
        well2.color = Self.color(stops[1])
        hex1.stringValue = stops[0]
        hex2.stringValue = stops[1]
        angle.doubleValue = accent.angle
        hi.doubleValue = accent.hiPercent
        refresh()
    }

    private func refresh() {
        let grad = accent.mode == .gradient
        row2.isHidden = !grad
        angleRow.isHidden = !grad
        angleLabel.stringValue = "\(Int(accent.angle))°"
        hiLabel.stringValue = "\(Int(accent.hiPercent))%"
        let c = accent.inkContrasts
        let ok = accent.inkContrast >= 4.5, glassOK = accent.glassContrast >= 4.5
        metrics.stringValue = String(format: "Ink %@ on the colour: %.2f:1 %@\nDark / white on the colour: %.2f · %.2f\nColour on dark glass: %.2f:1 %@",
                                     accent.ink == Accent.dark ? "dark" : "white", accent.inkContrast, ok ? "✓" : "✗ (under 4.5)",
                                     c.dark, c.white, accent.glassContrast, glassOK ? "✓" : "✗")
        metrics.textColor = ok ? .labelColor : .systemRed
        css.stringValue = accent.css
        preview.accent = accent
        if project != nil { status.stringValue = saved == nil ? "No accent saved yet." : (saved == accent ? "Saved." : "Not saved yet.") }
    }

    // MARK: actions

    @objc private func changed() {
        accent.mode = mode.selectedSegment == 1 ? .gradient : .solid
        if accent.mode == .gradient, accent.stops.count < 2 { accent.stops.append(Self.hex(well2.color)) }
        accent.angle = angle.doubleValue.rounded()
        accent.hiPercent = hi.doubleValue.rounded()
        refresh()
    }

    @objc private func wellChanged(_ w: NSColorWell) {
        var stops = accent.stops
        while stops.count < 2 { stops.append(stops.first ?? "#FF2D55") }
        stops[w === well1 ? 0 : 1] = Self.hex(w.color)
        accent.stops = stops
        hex1.stringValue = stops[0]
        hex2.stringValue = stops[1]
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let rgb = Accent.rgb(f.stringValue) else { show(); return }
        let hex = Accent.hex(rgb.0, rgb.1, rgb.2)
        var stops = accent.stops
        while stops.count < 2 { stops.append(stops.first ?? hex) }
        stops[f === hex1 ? 0 : 1] = hex
        accent.stops = stops
        show()
    }

    @objc private func save() {
        guard let owner else { return }
        var args: [String: JSONValue] = ["mode": .string(accent.mode.rawValue), "stops": .array(accent.used.map { .string($0) }),
                                         "hiPercent": .number(accent.hiPercent)]
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

/// The kit's shapes in the accent, drawn over the video's frame: a filled
/// pill with ink text, a glass pill, a gradient card and an orb, and a
/// full-colour strip, as the skill's picker shows them.
@MainActor
final class AccentPreview: NSView {
    var accent = Accent(mode: .solid, stops: ["#FF2D55"]) { didSet { needsDisplay = true } }
    private var image: CGImage?

    func frame(_ i: CGImage?) { image = i; needsDisplay = true }

    override var isFlipped: Bool { true }

    private func gradient() -> NSGradient {
        NSGradient(starting: AccentPanel.color(accent.acc), ending: AccentPanel.color(accent.acc2))!
    }

    private func text(_ s: String, _ size: CGFloat, _ color: NSColor, in r: NSRect, bold: Bool = true) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium),
                                                          .foregroundColor: color, .paragraphStyle: p])
        let h = a.size().height
        a.draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h))
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()
        // The frame, filling the view's height, centred.
        if let image, let ctx = NSGraphicsContext.current?.cgContext {
            let k = bounds.height / CGFloat(image.height)
            let w = CGFloat(image.width) * k
            let r = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: r)
            ctx.restoreGState()
        }
        let ink = AccentPanel.color(accent.ink)
        let angle = CGFloat(accent.mode == .gradient ? accent.angle - 90 : 45)
        let pad: CGFloat = 12, w = bounds.width
        // Filled pill with ink text.
        let pill = NSRect(x: pad, y: pad, width: min(170, w * 0.5), height: 36)
        gradient().draw(in: NSBezierPath(roundedRect: pill, xRadius: 18, yRadius: 18), angle: angle)
        text("Accent pill", 14, ink, in: pill)
        // Glass pill: dark glass with the colour as text and rim.
        let glass = NSRect(x: pad, y: pill.maxY + 10, width: min(170, w * 0.5), height: 36)
        let gp = NSBezierPath(roundedRect: glass, xRadius: 18, yRadius: 18)
        NSColor(srgbRed: 12 / 255, green: 13 / 255, blue: 20 / 255, alpha: 0.72).setFill()
        gp.fill()
        AccentPanel.color(accent.acc).withAlphaComponent(0.8).setStroke()
        gp.lineWidth = 1.5
        gp.stroke()
        text("Glass pill", 14, AccentPanel.color(accent.acc), in: glass)
        // Card: gradient number, white text, the light variant below.
        let card = NSRect(x: pad, y: glass.maxY + 12, width: min(200, w * 0.58), height: 92)
        NSColor(srgbRed: 12 / 255, green: 13 / 255, blue: 20 / 255, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
        let num = NSRect(x: card.minX, y: card.minY + 8, width: card.width, height: 40)
        text("12,400", 32, AccentPanel.color(accent.acc), in: num)
        text("white text", 13, .white, in: NSRect(x: card.minX, y: num.maxY + 2, width: card.width, height: 18), bold: false)
        text("light variant", 12, AccentPanel.color(accent.accHi), in: NSRect(x: card.minX, y: num.maxY + 22, width: card.width, height: 16), bold: false)
        // Orb and a full-colour strip on the right.
        let orb = NSRect(x: w - pad - 56, y: pad, width: 56, height: 56)
        gradient().draw(in: NSBezierPath(ovalIn: orb), angle: angle)
        let strip = NSRect(x: w - pad - 56, y: orb.maxY + 10, width: 56, height: bounds.height - orb.maxY - 10 - pad)
        gradient().draw(in: NSBezierPath(roundedRect: strip, xRadius: 10, yRadius: 10), angle: angle)
    }
}
