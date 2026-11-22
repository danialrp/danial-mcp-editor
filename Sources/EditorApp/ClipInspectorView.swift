import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// The Clip panel: what a selected clip is made of besides colour and
/// effects. Speed, sound (gain, mute, fades), fit and crop, slip, replacing
/// the file, the person matte of its footage and, for a HyperFrames layer,
/// its render. Track-wide sound tools (silence cuts, loudness) sit at the
/// bottom. Every control is a tool call, the same an agent makes.
@MainActor
final class ClipInspectorView: NSView {
    weak var owner: MainWindowController?

    private let content = NSStackView()
    private var project: Project?
    private var selection: [EntityID] = []
    private let resultLabel = NSTextField(wrappingLabelWithString: "")

    /// Slider rows: identifier → (slider, value label, unit).
    private var valueLabels: [String: (NSTextField, String)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let doc = TopDownView()
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
        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.preferredMaxLayoutWidth = 300
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(project p: Project?, selection: [EntityID]) {
        project = p
        self.selection = selection
        rebuild()
    }

    private var clip: Clip? {
        guard let p = project, let id = selection.first, let (t, c) = try? p.locate(clip: id) else { return nil }
        return p.tracks[t].clips[c]
    }

    private var track: Track? {
        guard let p = project, let id = selection.first, let (t, _) = try? p.locate(clip: id) else { return nil }
        return p.tracks[t]
    }

    private var asset: MediaAsset? {
        guard let clip else { return nil }
        return try? project?.asset(clip.asset)
    }

    // MARK: building

    /// Controls, by identifier, for the self-test.
    private(set) var controls: [String: NSControl] = [:]

    private func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        valueLabels = [:]
        controls = [:]
        guard project != nil else {
            content.addArrangedSubview(note("Open or create a project."))
            return
        }
        if let clip, let asset {
            if asset.isHyperFrames { buildHyperFrames(asset) } else { buildClip(clip, asset) }
        } else {
            content.addArrangedSubview(note("Put the playhead over a clip or select one to change its speed, sound, crop and matte."))
        }
        content.addArrangedSubview(separator())
        buildTrackSound()
        content.addArrangedSubview(resultLabel)
    }

    private func buildClip(_ clip: Clip, _ asset: MediaAsset) {
        let count = selection.count
        content.addArrangedSubview(title(count > 1 ? "\(count) clips" : asset.name))

        // Speed
        content.addArrangedSubview(title("Speed"))
        content.addArrangedSubview(sliderRow("speed", "Speed", clip.speed, 0.1...4, "×"))
        let presets = NSStackView(views: [0.5, 1, 1.22, 1.5, 2].map { v in
            let b = button(v == 1 ? "1×" : "\(EffectsInspectorView.format(v))×", #selector(speedPreset(_:)))
            b.tag = Int(v * 100)
            return b
        })
        content.addArrangedSubview(presets)

        // Sound
        if asset.info.audio != nil {
            content.addArrangedSubview(title("Sound"))
            content.addArrangedSubview(volumeRow(clip.gainDB))
            content.addArrangedSubview(sliderRow("fadeIn", "Fade in", clip.fadeIn.seconds, 0...5, "s"))
            content.addArrangedSubview(sliderRow("fadeOut", "Fade out", clip.fadeOut.seconds, 0...5, "s"))
            let mute = NSButton(checkboxWithTitle: "Mute this clip", target: self, action: #selector(muteChanged(_:)))
            mute.state = clip.muted ? .on : .off
            controls["muted"] = mute
            content.addArrangedSubview(mute)
        }

        // Picture: fit and crop
        if asset.info.video != nil {
            content.addArrangedSubview(title("Fit and crop"))
            let fit = NSPopUpButton(frame: .zero, pullsDown: false)
            fit.addItems(withTitles: ["Fit (whole picture)", "Fill (cover the canvas)"])
            fit.selectItem(at: clip.transform.fit == .fit ? 0 : 1)
            fit.controlSize = .small
            fit.target = self
            fit.action = #selector(fitChanged(_:))
            controls["fit"] = fit
            content.addArrangedSubview(NSStackView(views: [fixed(label("Fit"), 80), fit]))
            content.addArrangedSubview(sliderRow("cropLeft", "Crop left", clip.transform.cropLeft, 0...0.9, ""))
            content.addArrangedSubview(sliderRow("cropRight", "Crop right", clip.transform.cropRight, 0...0.9, ""))
            content.addArrangedSubview(sliderRow("cropTop", "Crop top", clip.transform.cropTop, 0...0.9, ""))
            content.addArrangedSubview(sliderRow("cropBottom", "Crop bottom", clip.transform.cropBottom, 0...0.9, ""))
        }

        // Slip and replace (one clip)
        if count == 1, !asset.isImage {
            content.addArrangedSubview(title("Slip (which part of the file shows)"))
            content.addArrangedSubview(NSStackView(views: [(-1.0, "−1 s"), (-1.0 / 30, "−1 f"), (1.0 / 30, "+1 f"), (1.0, "+1 s")].map { by, t in
                let b = button(t, #selector(slip(_:)))
                b.identifier = .init(String(by))
                return b
            }))
        }
        if count == 1, let p = project {
            let others = p.media.filter { $0.id != asset.id && !$0.isHyperFrames && ($0.info.video != nil) == (asset.info.video != nil) }
            if !others.isEmpty {
                let pop = NSPopUpButton(frame: .zero, pullsDown: true)
                pop.addItem(withTitle: "Replace with…")
                for m in others {
                    pop.addItem(withTitle: m.name)
                    pop.lastItem?.representedObject = m.id.raw
                }
                pop.controlSize = .small
                pop.target = self
                pop.action = #selector(replaceMedia(_:))
                controls["replace"] = pop
                content.addArrangedSubview(pop)
            }
        }

        // Person matte of the footage
        if asset.info.video != nil, !asset.isImage {
            content.addArrangedSubview(title("Person matte (depth)"))
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            pop.addItems(withTitles: ["Off", "Vision (made here)", "Imported masks"])
            pop.selectItem(at: asset.matte == .vision ? 1 : asset.matte == .imported ? 2 : 0)
            pop.controlSize = .small
            pop.target = self
            pop.action = #selector(matteChanged(_:))
            controls["matte"] = pop
            var row: [NSView] = [fixed(label("Matte"), 80), pop]
            if asset.matte != nil {
                row.append(button("Make", #selector(matteGenerate)))
                row.append(button("Status", #selector(matteStatus)))
            }
            content.addArrangedSubview(NSStackView(views: row))
        }
    }

    private func buildHyperFrames(_ asset: MediaAsset) {
        content.addArrangedSubview(title("HyperFrames · \(asset.name)"))
        content.addArrangedSubview(note("A motion-graphics layer: change it through its files (an agent's hf.* tools). From here: render the parts that are out of date, see their state, or lint it."))
        content.addArrangedSubview(NSStackView(views: [button("Render", #selector(hfRender)), button("Status", #selector(hfStatus)),
                                                       button("Check", #selector(hfCheck))]))
    }

    private func buildTrackSound() {
        let name = track?.name ?? "main track"
        content.addArrangedSubview(title("Sound of the \(track?.kind == .audio ? "track \(name)" : "main track")"))
        content.addArrangedSubview(NSStackView(views: [button("Find pauses", #selector(findSilence)), button("Remove pauses", #selector(applySilence))]))
        content.addArrangedSubview(NSStackView(views: [button("Normalise", #selector(normalize)), button("Measure loudness", #selector(loudness))]))
        content.addArrangedSubview(NSStackView(views: [button("Close gaps", #selector(closeGaps)), button("Join fades 0.05 s", #selector(joinFades))]))
    }

    // MARK: actions

    private var ids: JSONValue { .array(selection.map { .string($0.raw) }) }
    /// The track the track-wide sound tools act on: the clip's audio track, else the main track (the tools' default).
    private var trackArg: [String: JSONValue] {
        guard let t = track, t.kind == .audio else { return [:] }
        return ["track": .string(t.id.raw)]
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let key = s.identifier?.rawValue else { return }
        if key == "gainDB" {
            let g = fader.gain(at: s.doubleValue)
            valueLabels[key]?.0.stringValue = Self.formatDB(g)
            guard CommitSlider.isFinal(s), g != clip?.gainDB else { return }
            run("clip.setAudio", ["ids": ids, "gainDB": .number(g)])
            return
        }
        if let (l, unit) = valueLabels[key] { l.stringValue = EffectsInspectorView.format(s.doubleValue) + unit }
        guard CommitSlider.isFinal(s) else { return }
        let v = (s.doubleValue * 100).rounded() / 100
        switch key {
        case "speed": run("clip.setSpeed", ["ids": ids, "speed": .number(max(0.1, v))])
        case "gainDB", "fadeIn", "fadeOut": run("clip.setAudio", ["ids": ids, key: .number(v)])
        default: run("clip.setTransform", ["ids": ids, key: .number(v)])
        }
    }

    @objc private func speedPreset(_ b: NSButton) { run("clip.setSpeed", ["ids": ids, "speed": .number(Double(b.tag) / 100)]) }
    @objc private func muteChanged(_ b: NSButton) { run("clip.setAudio", ["ids": ids, "muted": .bool(b.state == .on)]) }
    @objc private func fitChanged(_ p: NSPopUpButton) { run("clip.setTransform", ["ids": ids, "fit": .string(p.indexOfSelectedItem == 0 ? "fit" : "fill")]) }

    @objc private func slip(_ b: NSButton) {
        guard let clip, let by = Double(b.identifier?.rawValue ?? "") else { return }
        run("clip.slip", ["id": .string(clip.id.raw), "by": .number(by)])
    }

    @objc private func replaceMedia(_ p: NSPopUpButton) {
        guard let clip, let id = p.selectedItem?.representedObject as? String else { return }
        run("clip.replaceMedia", ["id": .string(clip.id.raw), "asset": .string(id)])
    }

    @objc private func matteChanged(_ p: NSPopUpButton) {
        guard let asset else { return }
        run("media.setMatte", ["id": .string(asset.id.raw), "source": .string(["none", "vision", "imported"][p.indexOfSelectedItem])])
    }

    @objc private func matteGenerate() {
        guard let asset else { return }
        report("matte.generate", ["id": .string(asset.id.raw)]) { r in "Making the matte (job \(r["jobId"]?.stringValue ?? "")); the timeline picks it up chunk by chunk." }
    }

    @objc private func matteStatus() {
        guard let asset else { return }
        report("matte.status", ["id": .string(asset.id.raw)]) { r in
            let files = r["mattes"]?.arrayValue ?? []
            return files.map { f in
                if let problem = f["problem"]?.stringValue { return "Matte: \(problem)" }
                let chunks = f["chunks"]?.arrayValue ?? []
                let made = chunks.filter { $0["state"]?.stringValue == "current" }.count
                return "Matte: \(made) of \(chunks.count) chunks made" + (f["stability"]?["iouMedian"]?.doubleValue.map { String(format: ", frame-to-frame overlap %.3f", $0) } ?? "")
            }.joined(separator: "\n")
        }
    }

    @objc private func hfRender() {
        guard let asset else { return }
        report("hf.render", ["id": .string(asset.id.raw)]) { r in "Rendering (job \(r["jobId"]?.stringValue ?? "")); each slice shows when done." }
    }

    @objc private func hfStatus() {
        guard let asset else { return }
        report("hf.status", ["id": .string(asset.id.raw)]) { r in
            let slices = r["slices"]?.arrayValue ?? []
            var by: [String: Int] = [:]
            for s in slices { by[s["state"]?.stringValue ?? "?", default: 0] += 1 }
            return "Slices: " + by.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        }
    }

    @objc private func hfCheck() {
        guard let asset else { return }
        report("hf.check", ["id": .string(asset.id.raw)]) { r in
            let out = (r["output"]?.stringValue ?? "").split(separator: "\n").suffix(6).joined(separator: "\n")
            return (r["ok"]?.boolValue == true ? "Check passed" : "Check found problems") + (out.isEmpty ? "" : "\n" + out)
        }
    }

    @objc private func findSilence() {
        report("audio.findSilence", trackArg) { r in
            "\(Int(r["count"]?.doubleValue ?? 0)) pauses, \(String(format: "%.1f", r["removedSeconds"]?.doubleValue ?? 0)) s would go. Remove pauses cuts them in one undo step."
        }
    }

    @objc private func applySilence() {
        report("audio.applySilenceCuts", trackArg) { r in
            "Removed \(Int(r["count"]?.doubleValue ?? 0)) pauses (\(String(format: "%.1f", r["removedSeconds"]?.doubleValue ?? 0)) s). Undo with ⌘Z."
        }
    }

    @objc private func normalize() {
        report("audio.normalize", trackArg) { r in
            String(format: "Gain %+.1f dB set: %.1f LUFS, peak %.1f dBFS", r["gainDB"]?.doubleValue ?? 0,
                   r["expectedLUFS"]?.doubleValue ?? .nan, r["expectedPeakDBFS"]?.doubleValue ?? .nan)
        }
    }

    @objc private func loudness() {
        report("audio.loudness", [:]) { r in
            String(format: "Timeline: %.1f LUFS integrated, peak %.1f dBFS", r["integratedLUFS"]?.doubleValue ?? .nan,
                   r["samplePeakDBFS"]?.doubleValue ?? .nan)
        }
    }

    @objc private func closeGaps() {
        var a = trackArg
        if a.isEmpty, let t = track { a["track"] = .string(t.id.raw) }
        run("timeline.closeGaps", a)
    }

    @objc private func joinFades() {
        var a = trackArg
        if a.isEmpty, let t = track, t.kind != .overlay { a["track"] = .string(t.id.raw) }
        a["duration"] = .number(0.05)
        run("timeline.setJoinFades", a)
    }

    private func run(_ tool: String, _ args: [String: JSONValue]) {
        Task { await owner?.runTool(tool, .object(args)) }
    }

    /// Runs a tool and shows a short reading of its result under the panel.
    private func report(_ tool: String, _ args: [String: JSONValue], _ text: @escaping @MainActor (JSONValue) -> String) {
        resultLabel.stringValue = "\(tool)…"
        Task {
            guard let r = await owner?.callTool(tool, .object(args)) else { resultLabel.stringValue = ""; return }
            resultLabel.stringValue = text(r)
        }
    }

    // MARK: small views

    /// The fader the volume slider uses now (its right end reaches a gain set above the usual top).
    private(set) var fader = VolumeFader.standard

    static func formatDB(_ g: Double) -> String {
        g <= VolumeFader.standard.floor ? "-60 dB" : String(format: "%+.1f dB", g).replacingOccurrences(of: "+0.0", with: "0.0")
    }

    /// Volume on an audio taper: fine near 0 dB, silence only at the left end.
    /// The slider's value is the position (0...1); the label shows dB.
    private func volumeRow(_ gain: Double) -> NSView {
        fader = VolumeFader.standard.covering(gain)
        let row = sliderRow("gainDB", "Volume", fader.position(of: gain), 0...1, "")
        if let s = controls["gainDB"] as? CommitSlider { s.origin = fader.position(of: 0) }
        valueLabels["gainDB"]?.0.stringValue = Self.formatDB(gain)
        return row
    }

    private func sliderRow(_ key: String, _ text: String, _ value: Double, _ range: ClosedRange<Double>, _ unit: String) -> NSView {
        let s = CommitSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        s.identifier = .init(key)
        if key == "speed" { s.origin = 1 }
        s.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let u = unit.isEmpty ? "" : " \(unit)"
        let v = label(EffectsInspectorView.format(value) + u)
        v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabels[key] = (v, u)
        controls[key] = s
        let row = NSStackView(views: [fixed(label(text), 88), s, v])
        row.spacing = 10
        return row
    }

    private func title(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.lineBreakMode = .byTruncatingMiddle
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return l
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
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
final class TopDownView: NSView {
    override var isFlipped: Bool { true }
}
