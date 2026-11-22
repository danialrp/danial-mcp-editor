import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// The Effects panel: the selected clip's effects, with controls generated
/// from each plug-in's manifest, and its transform with keyframes at the
/// playhead. Every change is a tool call, the same an agent makes.
@MainActor
final class EffectsInspectorView: NSView {
    weak var owner: MainWindowController?

    private let content = NSStackView()
    private var project: Project?
    private var selection: [EntityID] = []
    private var transformRows: [KeyframeProperty: (NSSlider, NSTextField, NSButton)] = [:]
    private var clearButtons: [KeyframeProperty: NSButton] = [:]
    /// Easing for new keyframes, and set on keyframes at the playhead.
    private(set) var easing: Keyframe.Easing = .ease
    private let easingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var playhead = Time.zero

    private static let transformRanges: [(KeyframeProperty, ClosedRange<Double>, String)] = [
        (.scale, 0.1...4, "Scale"), (.x, -0.5...1.5, "Position X"), (.y, -0.5...1.5, "Position Y"),
        (.rotation, -180...180, "Rotation"), (.opacity, 0...1, "Opacity"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor), content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor), content.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(project p: Project?, selection: [EntityID]) {
        project = p
        self.selection = selection
        rebuild()
    }

    /// Called while paused, so the transform shows its value at the playhead.
    func playheadMoved(_ t: Time) {
        guard t != playhead else { return }
        playhead = t
        refreshTransform()
    }

    private var clip: Clip? {
        guard let p = project, let id = selection.first, let (t, c) = try? p.locate(clip: id) else { return nil }
        return p.tracks[t].clips[c]
    }

    // MARK: building

    private func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        transformRows = [:]
        clearButtons = [:]
        guard let clip else {
            content.addArrangedSubview(note("Put the playhead over a clip or select one to add effects and animate its transform."))
            return
        }
        let title = label("Effects", bold: true)
        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.addItem(withTitle: "Add effect")
        for e in EffectCatalog.shared.all {
            add.addItem(withTitle: "\(e.manifest.name)  (\(e.manifest.kind.rawValue))")
            add.lastItem?.representedObject = e.manifest.id
            add.lastItem?.toolTip = e.manifest.summary
        }
        add.target = self
        add.action = #selector(addEffect(_:))
        add.controlSize = .small
        content.addArrangedSubview(NSStackView(views: [title, add]))
        if clip.effects.isEmpty { content.addArrangedSubview(note("No effects on this clip.")) }
        for (i, fx) in clip.effects.enumerated() { content.addArrangedSubview(effectBox(fx, index: i, count: clip.effects.count)) }
        let bad = EffectCatalog.shared.currentProblems
        if !bad.isEmpty {
            let why = bad.prefix(3).map { "\(($0.folder as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n")
            content.addArrangedSubview(note("\(bad.count) plug-in folder(s) failed to load:\n\(why)"))
        }
        content.addArrangedSubview(button("Reload plug-ins", #selector(reloadEffects)))

        content.addArrangedSubview(separator())
        if easingPopup.numberOfItems == 0 {
            easingPopup.addItems(withTitles: Keyframe.Easing.allCases.map(\.rawValue))
            easingPopup.controlSize = .small
            easingPopup.target = self
            easingPopup.action = #selector(easingChanged(_:))
            easingPopup.toolTip = "Easing of new keyframes; also changes keyframes at the playhead"
        }
        easingPopup.selectItem(withTitle: easing.rawValue)
        content.addArrangedSubview(NSStackView(views: [label("Transform", bold: true), easingPopup, button("Clear all", #selector(clearKeyframes))]))
        for (prop, range, name) in Self.transformRanges { content.addArrangedSubview(transformRow(prop, range, name)) }
        content.addArrangedSubview(note("◆ sets a keyframe at the playhead. With keyframes, a slider change sets one at the playhead; without, it changes the whole clip."))
        refreshTransform()
    }

    private func effectBox(_ fx: EffectInstance, index: Int, count: Int) -> NSView {
        let m = EffectCatalog.shared.entry(fx.effect)?.manifest
        let on = NSButton(checkboxWithTitle: "On", target: self, action: #selector(toggleEffect(_:)))
        on.state = fx.enabled ? .on : .off
        on.identifier = .init(fx.id.raw)
        var head: [NSView] = [label("\(m?.name ?? fx.effect) · \(fx.kind.rawValue)", bold: true), NSView(), on]
        for (t, a, enabled) in [("↑", #selector(effectUp(_:)), index > 0), ("↓", #selector(effectDown(_:)), index < count - 1), ("✕", #selector(removeEffect(_:)), true)] {
            let b = button(t, a)
            b.identifier = .init(fx.id.raw)
            b.isEnabled = enabled
            head.append(b)
        }
        let box = NSStackView(views: [NSStackView(views: head)])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        guard let m else {
            box.addArrangedSubview(note("Plug-in \(fx.effect) is not installed; the clip renders without it."))
            return box
        }
        if fx.kind != .filter, let d = m.duration {
            box.addArrangedSubview(paramSlider(fx, name: "duration", label: "Duration", value: fx.duration?.seconds ?? d.default,
                                               range: (d.min ?? 0.04)...(d.max ?? 10), unit: "s"))
        }
        for p in m.parameters {
            let value = fx.params[p.name] ?? p.defaultValue
            switch p.type {
            case .number:
                box.addArrangedSubview(paramSlider(fx, name: p.name, label: p.label ?? p.name, value: value,
                                                   range: (p.min ?? 0)...(p.max ?? 100), unit: p.unit))
            case .boolean:
                let c = NSButton(checkboxWithTitle: p.label ?? p.name, target: self, action: #selector(paramChanged(_:)))
                c.state = value == 1 ? .on : .off
                c.identifier = .init("\(fx.id.raw)|\(p.name)")
                c.toolTip = p.summary
                box.addArrangedSubview(c)
            case .choice:
                let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                pop.addItems(withTitles: p.choices ?? [])
                pop.selectItem(at: Int(value))
                pop.controlSize = .small
                pop.identifier = .init("\(fx.id.raw)|\(p.name)")
                pop.target = self
                pop.action = #selector(paramChanged(_:))
                box.addArrangedSubview(NSStackView(views: [fixed(label(p.label ?? p.name), 92), pop]))
            }
        }
        return box
    }

    private func paramSlider(_ fx: EffectInstance, name: String, label text: String, value: Double,
                             range: ClosedRange<Double>, unit: String?) -> NSView {
        let s = CommitSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(paramChanged(_:)))
        s.identifier = .init("\(fx.id.raw)|\(name)")
        s.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let v = label(Self.format(value) + (unit.map { " \($0)" } ?? ""))
        v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return NSStackView(views: [fixed(label(text), 92), s, v])
    }

    private func transformRow(_ prop: KeyframeProperty, _ range: ClosedRange<Double>, _ name: String) -> NSView {
        let s = CommitSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(transformChanged(_:)))
        s.identifier = .init(prop.rawValue)
        switch prop { case .scale: s.origin = 1; case .x, .y: s.origin = 0.5; default: break }
        s.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let v = label("")
        v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        v.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let k = button("◆", #selector(toggleKeyframe(_:)))
        k.identifier = .init(prop.rawValue)
        k.setButtonType(.pushOnPushOff)
        transformRows[prop] = (s, v, k)
        let x = button("✕", #selector(clearProperty(_:)))
        x.identifier = .init(prop.rawValue)
        x.toolTip = "Remove this property's keyframes"
        clearButtons[prop] = x
        return NSStackView(views: [fixed(label(name), 92), s, v, k, x])
    }

    private func refreshTransform() {
        guard let clip else { return }
        let t = Time.max(clip.start, Time.min(playhead, clip.end))
        let (tr, op) = clip.animated(at: t)
        let src = clip.sourceTime(at: t)
        for (prop, (s, v, k)) in transformRows {
            let value: Double = switch prop {
            case .x: tr.x
            case .y: tr.y
            case .scale: tr.scale
            case .rotation: tr.rotation
            case .opacity: op
            }
            s.doubleValue = value
            v.stringValue = Self.format(value)
            let ks = clip.keyframes[prop.rawValue] ?? []
            k.state = ks.contains { abs(($0.time - src).seconds) < 0.5 / 60 } ? .on : .off
            k.contentTintColor = ks.isEmpty ? nil : .systemYellow
            clearButtons[prop]?.isHidden = ks.isEmpty
        }
    }

    // MARK: actions

    private var ids: JSONValue { .array(selection.map { .string($0.raw) }) }

    @objc private func addEffect(_ p: NSPopUpButton) {
        guard let id = p.selectedItem?.representedObject as? String else { return }
        Task { await owner?.runTool("effect.add", .object(["clips": ids, "effect": .string(id)])) }
    }

    private func set(_ fx: String, _ args: [String: JSONValue]) {
        guard let clip else { return }
        var a = args
        a["clip"] = .string(clip.id.raw)
        a["effect"] = .string(fx)
        Task { await owner?.runTool("effect.set", .object(a)) }
    }

    @objc private func toggleEffect(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        set(id, ["enabled": .bool(b.state == .on)])
    }

    @objc private func paramChanged(_ c: NSControl) {
        guard let parts = c.identifier?.rawValue.split(separator: "|").map(String.init), parts.count == 2 else { return }
        let (fx, name) = (parts[0], parts[1])
        let value: Double
        switch c {
        case let s as NSSlider:
            if let row = s.superview as? NSStackView, let v = row.arrangedSubviews.last as? NSTextField {
                v.stringValue = Self.format(s.doubleValue) + (name == "duration" ? " s" : "")
            }
            // Apply when the slider is let go, so a drag is one undo step.
            guard CommitSlider.isFinal(s) else { return }
            value = (s.doubleValue * 100).rounded() / 100
        case let b as NSButton: value = b.state == .on ? 1 : 0
        case let p as NSPopUpButton: value = Double(p.indexOfSelectedItem)
        default: return
        }
        set(fx, name == "duration" ? ["duration": .number(value)] : ["params": .object([name: .number(value)])])
    }

    private func move(_ b: NSButton, by d: Int) {
        guard let clip, let id = b.identifier?.rawValue, let i = clip.effects.firstIndex(where: { $0.id.raw == id }) else { return }
        Task { await owner?.runTool("effect.reorder", .object(["clip": .string(clip.id.raw), "effect": .string(id), "index": .number(Double(i + d))])) }
    }

    @objc private func effectUp(_ b: NSButton) { move(b, by: -1) }
    @objc private func effectDown(_ b: NSButton) { move(b, by: 1) }

    @objc private func removeEffect(_ b: NSButton) {
        guard let clip, let id = b.identifier?.rawValue else { return }
        Task { await owner?.runTool("effect.remove", .object(["clip": .string(clip.id.raw), "effect": .string(id)])) }
    }

    /// The clip's keyframes for `prop` with one at the playhead set to `value`.
    private func keyframes(_ clip: Clip, _ prop: KeyframeProperty, setting value: Double?) -> JSONValue {
        let t = Time.max(clip.start, Time.min(playhead, clip.end))
        let src = clip.sourceTime(at: t)
        var ks = (clip.keyframes[prop.rawValue] ?? []).filter { abs(($0.time - src).seconds) >= 0.5 / 60 }
        if let value { ks.append(Keyframe(time: src, value: value, easing: easing)) }
        return .array(ks.sorted { $0.time < $1.time }.map {
            .object(["time": .number($0.time.seconds), "value": .number($0.value), "easing": .string($0.easing.rawValue)])
        })
    }

    @objc private func transformChanged(_ s: NSSlider) {
        guard let clip, let prop = KeyframeProperty(rawValue: s.identifier?.rawValue ?? "") else { return }
        transformRows[prop]?.1.stringValue = Self.format(s.doubleValue)
        let value = (s.doubleValue * 1000).rounded() / 1000
        guard CommitSlider.isFinal(s) else {
            // A live picture while dragging (a clip without keyframes on it).
            if clip.keyframes[prop.rawValue] == nil, var p = project {
                for id in ids.arrayValue?.compactMap(\.stringValue) ?? [clip.id.raw] {
                    guard let (t, c) = try? p.locate(clip: EntityID(id)) else { continue }
                    switch prop {
                    case .x: p.tracks[t].clips[c].transform.x = value
                    case .y: p.tracks[t].clips[c].transform.y = value
                    case .scale: p.tracks[t].clips[c].transform.scale = value
                    case .rotation: p.tracks[t].clips[c].transform.rotation = value
                    case .opacity: p.tracks[t].clips[c].opacity = value
                    }
                }
                owner?.preview(p)
            }
            return
        }
        if clip.keyframes[prop.rawValue] != nil {
            Task { await owner?.runTool("clip.setKeyframes", .object(["clip": .string(clip.id.raw), "property": .string(prop.rawValue),
                                                                      "keyframes": keyframes(clip, prop, setting: value), "timeBase": .string("source")])) }
        } else {
            Task { await owner?.runTool("clip.setTransform", .object(["ids": ids, prop.rawValue: .number(value)])); owner?.endPreview() }
        }
    }

    @objc private func toggleKeyframe(_ b: NSButton) {
        guard let clip, let prop = KeyframeProperty(rawValue: b.identifier?.rawValue ?? ""), let s = transformRows[prop]?.0 else { return }
        let adding = b.state == .on
        Task { await owner?.runTool("clip.setKeyframes", .object(["clip": .string(clip.id.raw), "property": .string(prop.rawValue),
                                                                  "keyframes": keyframes(clip, prop, setting: adding ? s.doubleValue : nil),
                                                                  "timeBase": .string("source")])) }
    }

    @objc private func clearProperty(_ b: NSButton) {
        guard let clip, let prop = b.identifier?.rawValue else { return }
        Task { await owner?.runTool("clip.removeKeyframes", .object(["clip": .string(clip.id.raw), "property": .string(prop)])) }
    }

    @objc private func reloadEffects() {
        Task { await owner?.runTool("effect.reload", .object([:])); rebuild() }
    }

    /// Sets the easing for new keyframes and on every keyframe at the playhead.
    @objc private func easingChanged(_ p: NSPopUpButton) {
        guard let e = Keyframe.Easing(rawValue: p.titleOfSelectedItem ?? "") else { return }
        easing = e
        guard let clip else { return }
        let t = Time.max(clip.start, Time.min(playhead, clip.end))
        let src = clip.sourceTime(at: t)
        for prop in KeyframeProperty.allCases {
            var ks = clip.keyframes[prop.rawValue] ?? []
            guard let i = ks.firstIndex(where: { abs(($0.time - src).seconds) < 0.5 / 60 }), ks[i].easing != e else { continue }
            ks[i].easing = e
            let list: JSONValue = .array(ks.map { .object(["time": .number($0.time.seconds), "value": .number($0.value), "easing": .string($0.easing.rawValue)]) })
            Task { await owner?.runTool("clip.setKeyframes", .object(["clip": .string(clip.id.raw), "property": .string(prop.rawValue),
                                                                      "keyframes": list, "timeBase": .string("source")])) }
        }
    }

    @objc private func clearKeyframes() {
        guard let clip else { return }
        Task { await owner?.runTool("clip.removeKeyframes", .object(["clip": .string(clip.id.raw)])) }
    }

    // MARK: small views

    static func format(_ v: Double) -> String {
        abs(v) >= 10 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }

    private func label(_ s: String, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        if bold { l.font = .systemFont(ofSize: 12, weight: .semibold) } else { l.textColor = .secondaryLabelColor }
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 11)
        l.preferredMaxLayoutWidth = 300
        return l
    }

    private func fixed(_ v: NSView, _ w: CGFloat) -> NSView {
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    private func button(_ t: String, _ a: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: a)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return b
    }
}

/// Lays out top-down inside a scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
