import AppKit
import EditorCore
import EditorKit

/// The colour panel: the Adjust, White Balance, HSL and Style tabs of the
/// owner's Edits panel, acting on the selected clips. Every change is a tool
/// call, the same an agent makes, so hand and agent edits are identical.
@MainActor
final class InspectorView: NSView {
    weak var owner: MainWindowController?

    private let title = NSTextField(labelWithString: "Colour")
    private let lookPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Saved presets (look profiles); the last one used is remembered.
    let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var presetsLoaded = false
    static let lastPresetKey = "colour.lastPreset"
    private let enabled = NSButton(checkboxWithTitle: "On", target: nil, action: nil)
    private let tabs = NSTabView()
    private var sliders: [String: (NSSlider, NSTextField)] = [:]
    private let bandPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var hslSliders: [String: (NSSlider, NSTextField)] = [:]
    private let rangeSlider = CommitSlider(value: 25, minValue: 5, maxValue: 90, target: nil, action: nil)
    private let rangeLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")

    private var project: Project?
    private var selection: [EntityID] = []
    private var look: Look?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: building

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        lookPopup.target = self
        lookPopup.action = #selector(lookChosen)
        enabled.target = self
        enabled.action = #selector(enabledChanged)
        presetPopup.controlSize = .regular
        presetPopup.toolTip = "Saved presets, for any project"
        let header = NSStackView(views: [title, NSView(), enabled])
        let lookLabel = NSTextField(labelWithString: "Look"), presetLabel = NSTextField(labelWithString: "Preset")
        for l in [lookLabel, presetLabel] { l.textColor = .secondaryLabelColor; l.widthAnchor.constraint(equalToConstant: 52).isActive = true }
        lookPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        presetPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let lookRow = NSStackView(views: [lookLabel, lookPopup, button("Reset all", #selector(resetLook))])
        let presetRow = NSStackView(views: [presetLabel, presetPopup, button("Apply", #selector(loadProfile))])
        let presetButtons = NSStackView(views: [button("Save as New…", #selector(saveProfile)), button("Update", #selector(updateProfile)),
                                                button("Rename…", #selector(renameProfile)), button("Delete", #selector(deleteProfile))])
        for v in [lookRow, presetRow, presetButtons] { v.spacing = 8 }
        let row = NSStackView(views: [lookRow, presetRow, presetButtons])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 10

        for tab in ["Adjust", "White Balance", "Style"] {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
            for s in Look.sliders where s.tab == tab {
                stack.addArrangedSubview(sliderRow(s.name, s.range, store: &sliders))
            }
            addTab(tab, stack)
        }
        // HSL: a band or picked colour, then hue, saturation, luminance.
        bandPopup.target = self
        bandPopup.action = #selector(bandChosen)
        let hsl = NSStackView()
        hsl.orientation = .vertical
        hsl.alignment = .leading
        hsl.spacing = 12
        hsl.edgeInsets = NSEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        hsl.addArrangedSubview(bandPopup)
        for n in ["hue", "saturation", "luminance"] { hsl.addArrangedSubview(sliderRow(n, -100...100, hsl: true, store: &hslSliders)) }
        rangeSlider.target = self
        rangeSlider.action = #selector(hslChanged(_:))
        rangeSlider.isContinuous = false
        let rangeName = NSTextField(labelWithString: "reach")
        rangeName.textColor = .secondaryLabelColor
        rangeName.widthAnchor.constraint(equalToConstant: 92).isActive = true
        rangeSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        hsl.addArrangedSubview(NSStackView(views: [rangeName, rangeSlider, rangeLabel]))
        hsl.addArrangedSubview(NSStackView(views: [button("Pick colour…", #selector(pickColour)), button("Remove", #selector(removePicked))]))
        tabs.insertTabViewItem(item("HSL", hsl), at: 2)

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let all = NSStackView(views: [header, row, tabs, hint])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 14
        all.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor),
            all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor),
            header.widthAnchor.constraint(equalTo: all.widthAnchor, constant: -20),
            tabs.widthAnchor.constraint(equalTo: all.widthAnchor, constant: -20),
            tabs.heightAnchor.constraint(equalToConstant: 330),
            hint.widthAnchor.constraint(equalTo: all.widthAnchor, constant: -20),
        ])
        refresh()
    }

    private func button(_ t: String, _ a: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: a)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func item(_ label: String, _ v: NSView) -> NSTabViewItem {
        let i = NSTabViewItem(identifier: label)
        i.label = label
        let holder = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(v)
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
                                     v.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8)])
        i.view = holder
        return i
    }

    private func addTab(_ label: String, _ v: NSView) { tabs.addTabViewItem(item(label, v)) }

    private func sliderRow(_ name: String, _ range: ClosedRange<Double>, hsl: Bool = false,
                           store: inout [String: (NSSlider, NSTextField)]) -> NSView {
        let label = NSTextField(labelWithString: Self.display(name))
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let s = CommitSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: self,
                         action: hsl ? #selector(hslChanged(_:)) : #selector(sliderChanged(_:)))
        s.identifier = NSUserInterfaceItemIdentifier(name)
        s.isContinuous = true
        s.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let v = NSTextField(labelWithString: "0")
        v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        v.widthAnchor.constraint(equalToConstant: 34).isActive = true
        store[name] = (s, v)
        return NSStackView(views: [label, s, v])
    }

    static func display(_ name: String) -> String {
        name == "noiseReduction" ? "Noise reduction" : name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: state

    func update(project p: Project?, selection: [EntityID]) {
        project = p
        self.selection = selection
        if !presetsLoaded { refreshPresets() }
        refresh()
    }

    /// The look of the first selected clip (its own, else its track's).
    private func currentLook() -> Look? {
        guard let p = project, let first = selection.first, let (t, c) = try? p.locate(clip: first) else { return nil }
        let clip = p.tracks[t].clips[c]
        guard let id = clip.look ?? p.tracks[t].look else { return nil }
        return p.looks.first { $0.id == id }
    }

    private func refresh() {
        look = currentLook()
        let hasClip = !selection.isEmpty && project != nil
        lookPopup.removeAllItems()
        lookPopup.addItem(withTitle: "No look")
        for l in project?.looks ?? [] {
            lookPopup.addItem(withTitle: l.name)
            lookPopup.lastItem?.representedObject = l.id.raw
        }
        lookPopup.addItem(withTitle: "New look")
        if let look, let i = (project?.looks.firstIndex { $0.id == look.id }) { lookPopup.selectItem(at: i + 1) }
        else { lookPopup.selectItem(at: 0) }
        enabled.state = (look?.enabled ?? true) ? .on : .off
        for (name, (s, v)) in sliders where CommitSlider.isFinal(s) {
            // A slider being dragged keeps its knob; the project catches up on release.
            let value = look?[slider: name] ?? 0
            s.doubleValue = value
            v.stringValue = "\(Int(value.rounded()))"
        }
        let chosen = bandPopup.titleOfSelectedItem
        bandPopup.removeAllItems()
        for b in HSLBand.allCases { bandPopup.addItem(withTitle: b.rawValue.capitalized) }
        for c in look?.picked ?? [] {
            bandPopup.addItem(withTitle: "Picked \(c.color)")
            bandPopup.lastItem?.representedObject = c.id.raw
        }
        if let chosen, bandPopup.item(withTitle: chosen) != nil { bandPopup.selectItem(withTitle: chosen) }
        refreshHSL()
        for v in [lookPopup, enabled, tabs, bandPopup] as [NSView] { (v as? NSControl)?.isEnabled = hasClip }
        sliders.values.forEach { $0.0.isEnabled = hasClip }
        hslSliders.values.forEach { $0.0.isEnabled = hasClip }
        hint.stringValue = hasClip
            ? "Changes apply to the look of the selected clip\(selection.count > 1 ? "s" : ""); every clip and track using that look changes with it."
            : "Put the playhead over a clip or select one to set its colour and light."
    }

    private func refreshHSL() {
        let picked = pickedSelection()
        let adj: HSLAdjust = picked?.adjust ?? look?.band(selectedBand() ?? .red) ?? HSLAdjust()
        for (name, value) in [("hue", adj.hue), ("saturation", adj.saturation), ("luminance", adj.luminance)]
            where CommitSlider.isFinal(hslSliders[name]?.0) {
            hslSliders[name]?.0.doubleValue = value
            hslSliders[name]?.1.stringValue = "\(Int(value.rounded()))"
        }
        rangeSlider.isEnabled = picked != nil
        rangeSlider.doubleValue = picked?.range ?? 25
        rangeLabel.stringValue = picked.map { "\(Int($0.range))°" } ?? ""
    }

    private func selectedBand() -> HSLBand? {
        HSLBand(rawValue: (bandPopup.titleOfSelectedItem ?? "").lowercased())
    }

    private func pickedSelection() -> PickedColor? {
        guard let id = bandPopup.selectedItem?.representedObject as? String else { return nil }
        return look?.picked.first { $0.id.raw == id }
    }

    // MARK: actions

    /// The look being made for a drag that started on a clip without one.
    private var creatingLook: Task<String?, Never>?

    /// At the start of a drag on a clip without a look, makes the look at
    /// once, so the rest of the drag only changes its values (drawn live).
    private func startLookOnce() {
        guard look == nil, creatingLook == nil, !selection.isEmpty else { return }
        creatingLook = Task { await self.makeLook() }
    }

    /// Makes sure the selected clips have a look and returns its id.
    private func ensureLook() async -> String? {
        if let look { return look.id.raw }
        if let c = creatingLook {
            let id = await c.value
            creatingLook = nil
            return id
        }
        return await makeLook()
    }

    private func makeLook() async -> String? {
        guard let owner, !selection.isEmpty else { return nil }
        let id = "look_" + IDGenerator.newSeed()
        await owner.runTool("batch.apply", .object(["commands": .array([
            .object(["name": .string("look.create"), "args": .object(["id": .string(id)])]),
            .object(["name": .string("look.assign"), "args": .object(["look": .string(id), "clips": .array(selection.map { .string($0.raw) })])]),
        ])]))
        return id
    }

    /// The project with the look of the selected clips changed by `change`,
    /// for the live preview of a slider being dragged.
    private func previewProject(_ change: (inout Look) -> Void) -> Project? {
        guard var p = project, !selection.isEmpty else { return nil }
        if let look, let i = p.looks.firstIndex(where: { $0.id == look.id }) {
            change(&p.looks[i])
        } else {
            var l = Look(id: "look_preview", name: "preview")
            change(&l)
            p.looks.append(l)
            for id in selection { if let (t, c) = try? p.locate(clip: id) { p.tracks[t].clips[c].look = l.id } }
        }
        return p
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let name = s.identifier?.rawValue else { return }
        sliders[name]?.1.stringValue = "\(Int(s.doubleValue.rounded()))"
        let value = s.doubleValue.rounded()
        // While dragging, a live picture; the change is applied when the
        // slider is let go, so a drag is one undo step.
        let current = look?[slider: name] ?? 0
        guard CommitSlider.isFinal(s) else {
            // A press that has not moved the value yet changes nothing.
            if look == nil, value == current { return }
            startLookOnce()
            // Until the new look exists the picture waits (a few ms); then
            // every value goes straight to the player.
            if look != nil, let p = previewProject({ $0[slider: name] = value }) { owner?.preview(p) }
            return
        }
        // Let go where it started: no new look, no undo step.
        if value == current, creatingLook == nil { owner?.endPreview(); return }
        Task {
            guard let id = await ensureLook() else { return }
            await owner?.runTool("look.update", .object(["id": .string(id), name: .number(value)]))
            owner?.endPreview()
        }
    }

    @objc private func hslChanged(_ s: NSSlider) {
        if let name = s.identifier?.rawValue { hslSliders[name]?.1.stringValue = "\(Int(s.doubleValue.rounded()))" }
        if s === rangeSlider { rangeLabel.stringValue = "\(Int(s.doubleValue))°" }
        let h = hslSliders["hue"]!.0.doubleValue.rounded(), sa = hslSliders["saturation"]!.0.doubleValue.rounded()
        let l = hslSliders["luminance"]!.0.doubleValue.rounded(), range = rangeSlider.doubleValue.rounded()
        let picked = pickedSelection(), band = selectedBand()
        guard CommitSlider.isFinal(s) else {
            startLookOnce()
            if look != nil, picked == nil, let band, let p = previewProject({ $0.hsl[band.rawValue] = HSLAdjust(hue: h, saturation: sa, luminance: l) }) {
                owner?.preview(p)
            }
            return
        }
        Task {
            defer { owner?.endPreview() }
            guard let id = await ensureLook() else { return }
            if let picked {
                await owner?.runTool("look.updatePickedColor", .object(["look": .string(id), "id": .string(picked.id.raw),
                    "hue": .number(h), "saturation": .number(sa), "luminance": .number(l), "range": .number(range)]))
            } else if let band {
                await owner?.runTool("look.update", .object(["id": .string(id), "hsl": .object([band.rawValue: .object([
                    "hue": .number(h), "saturation": .number(sa), "luminance": .number(l)])])]))
            }
        }
    }

    @objc private func bandChosen() { refreshHSL() }

    @objc private func lookChosen() {
        guard let owner, !selection.isEmpty else { return }
        let ids = JSONValue.array(selection.map { .string($0.raw) })
        if lookPopup.indexOfSelectedItem == 0 {
            Task { await owner.runTool("look.assign", .object(["clips": ids])) }
        } else if lookPopup.titleOfSelectedItem == "New look" {
            look = nil
            Task { _ = await ensureLook() }
        } else if let id = lookPopup.selectedItem?.representedObject as? String {
            Task { await owner.runTool("look.assign", .object(["look": .string(id), "clips": ids])) }
        }
    }

    @objc private func enabledChanged() {
        guard let look else { return }
        let on = enabled.state == .on
        Task { await owner?.runTool("look.update", .object(["id": .string(look.id.raw), "enabled": .bool(on)])) }
    }

    @objc private func resetLook() {
        guard let look else { return }
        var args: [String: JSONValue] = ["id": .string(look.id.raw)]
        for s in Look.sliders { args[s.name] = .number(0) }
        args["hsl"] = .object(Dictionary(uniqueKeysWithValues: HSLBand.allCases.map {
            ($0.rawValue, JSONValue.object(["hue": .number(0), "saturation": .number(0), "luminance": .number(0)]))
        }))
        Task { await owner?.runTool("look.update", .object(args)) }
    }

    @objc private func pickColour() {
        // The system colour sampler: click anywhere on screen, for example on
        // skin in the player.
        NSColorSampler().show { [weak self] color in
            guard let self, let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            Task { @MainActor in
                guard let id = await self.ensureLook() else { return }
                await self.owner?.runTool("look.addPickedColor", .object(["look": .string(id), "color": .string(hex)]))
            }
        }
    }

    @objc private func removePicked() {
        guard let look, let p = pickedSelection() else { return }
        Task { await owner?.runTool("look.removePickedColor", .object(["look": .string(look.id.raw), "id": .string(p.id.raw)])) }
    }

    // MARK: presets

    /// Reads the saved presets into the popup, keeping the last one used selected.
    func refreshPresets(select wanted: String? = nil) {
        guard let owner else { return }
        presetsLoaded = true
        Task {
            let names = await owner.callTool("look.listProfiles", .object([:]))?["profiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
            presetPopup.removeAllItems()
            if names.isEmpty {
                presetPopup.addItem(withTitle: "No saved presets")
                presetPopup.isEnabled = false
                return
            }
            presetPopup.isEnabled = true
            presetPopup.addItems(withTitles: names)
            let keep = wanted ?? UserDefaults.standard.string(forKey: Self.lastPresetKey)
            if let keep, names.contains(keep) { presetPopup.selectItem(withTitle: keep) }
        }
    }

    var selectedPreset: String? { presetPopup.isEnabled ? presetPopup.titleOfSelectedItem : nil }

    private func remember(_ name: String?) {
        UserDefaults.standard.set(name, forKey: Self.lastPresetKey)
    }

    private func ask(_ title: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// Saves the current look as a new preset.
    @objc func saveProfile() {
        guard let look else { owner?.show("select a clip with a look first"); return }
        guard let name = ask("Save the look as a new preset", look.name) else { return }
        Task { await savePreset(name, replace: false) }
    }

    func savePreset(_ name: String, replace: Bool) async {
        guard let look, let owner else { return }
        guard await owner.callTool("look.saveProfile", .object(["look": .string(look.id.raw), "name": .string(name), "replace": .bool(replace)])) != nil else { return }
        remember(name)
        refreshPresets(select: name)
        owner.show("Preset \(name) saved")
    }

    /// Overwrites the selected preset with the current look.
    @objc private func updateProfile() {
        guard let name = selectedPreset else { owner?.show("no preset to update; Save as New first"); return }
        guard look != nil else { owner?.show("select a clip with a look first"); return }
        let a = NSAlert()
        a.messageText = "Update the preset \"\(name)\" with the current look?"
        a.addButton(withTitle: "Update")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await savePreset(name, replace: true) }
    }

    @objc private func renameProfile() {
        guard let name = selectedPreset, let owner, let new = ask("Rename the preset", name), new != name else { return }
        Task {
            guard await owner.callTool("look.renameProfile", .object(["name": .string(name), "newName": .string(new)])) != nil else { return }
            remember(new)
            refreshPresets(select: new)
        }
    }

    @objc private func deleteProfile() {
        guard let name = selectedPreset, let owner else { return }
        let a = NSAlert()
        a.messageText = "Move the preset \"\(name)\" to the Trash?"
        a.informativeText = "Looks already used in projects stay as they are."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await deletePreset(name) }
    }

    func deletePreset(_ name: String) async {
        guard await owner?.callTool("look.deleteProfile", .object(["name": .string(name)])) != nil else { return }
        if UserDefaults.standard.string(forKey: Self.lastPresetKey) == name { remember(nil) }
        refreshPresets()
    }

    /// Applies the selected preset to the selected clips (or the clip under the playhead).
    @objc func loadProfile() {
        guard let owner, let name = selectedPreset else { owner?.show("no saved presets yet"); return }
        guard !selection.isEmpty else { owner.show("put the playhead over a clip or select one"); return }
        let ids = JSONValue.array(selection.map { .string($0.raw) })
        remember(name)
        Task { await owner.runTool("look.loadProfile", .object(["name": .string(name), "clips": ids])) }
    }
}
