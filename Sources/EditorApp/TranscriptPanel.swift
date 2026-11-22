import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// The Words panel: a transcript as text at its timeline places. Click a
/// word to put the playhead on it; search finds a word or phrase; the word
/// under the playhead is highlighted. Transcripts come from Media ›
/// Transcribe (Edits) or from a JSON file (Import…).
@MainActor
final class TranscriptPanel: NSView, NSTextViewDelegate, NSSearchFieldDelegate {
    weak var owner: MainWindowController?

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    let search = NSSearchField()
    let text = NSTextView()
    let status = NSTextField(labelWithString: "")
    private var project: Project?
    /// The shown words: timeline start and end, and their range in the text.
    private(set) var words: [(start: Double, end: Double, range: NSRange)] = []
    private var shownID: String?
    private var highlighted: Int?
    /// True while the text is being replaced: its selection moves then, and
    /// that is not a click on a word.
    private var replacing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        picker.controlSize = .small
        picker.target = self
        picker.action = #selector(pick)
        search.placeholderString = "Find a word or phrase"
        search.delegate = self
        search.target = self
        search.action = #selector(find)
        search.sendsSearchStringImmediately = false
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.delegate = self
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        // Right-to-left transcripts read naturally.
        text.baseWritingDirection = .natural
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        func b(_ t: String, _ a: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: a)
            x.bezelStyle = .rounded
            x.controlSize = .small
            return x
        }
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        let top = NSStackView(views: [picker, b("Import…", #selector(importJSON)), b("Remove", #selector(remove))])
        let stack = NSStackView(views: [top, search, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(project p: Project?) {
        let changed = p?.transcripts != project?.transcripts || p?.tracks != project?.tracks
        project = p
        guard changed else { return }
        picker.removeAllItems()
        let ts = p?.transcripts ?? []
        for t in ts {
            let name = (try? p?.asset(t.asset).name) ?? t.asset.raw
            picker.addItem(withTitle: "\(name) · \(t.words.count) words · \(t.language)")
            picker.lastItem?.representedObject = t.id.raw
        }
        if ts.isEmpty {
            picker.addItem(withTitle: "No transcripts")
            words = []
            replacing = true
            text.string = ""
            replacing = false
            status.stringValue = "Transcribe a file from the Media tab, or import a JSON transcript."
            shownID = nil
            return
        }
        if let id = shownID, let i = ts.firstIndex(where: { $0.id.raw == id }) { picker.selectItem(at: i) } else { picker.selectItem(at: ts.count - 1) }
        load()
    }

    private var selectedID: String? { picker.selectedItem?.representedObject as? String }

    @objc private func pick() { load() }

    /// Loads the picked transcript's words at their timeline places.
    func load() {
        guard let id = selectedID, let owner else { return }
        shownID = id
        Task {
            guard let r = await owner.callTool("transcript.get", .object(["id": .string(id), "limit": .number(100_000)])) else { return }
            let list = r["words"]?.arrayValue ?? []
            let out = NSMutableAttributedString()
            var ws: [(Double, Double, NSRange)] = []
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
            for w in list {
                guard let s = w["text"]?.stringValue, let a = w["start"]?.doubleValue, let e = w["end"]?.doubleValue else { continue }
                if out.length > 0 { out.append(NSAttributedString(string: " ", attributes: attrs)) }
                let range = NSRange(location: out.length, length: (s as NSString).length)
                out.append(NSAttributedString(string: s, attributes: attrs))
                ws.append((a, e, range))
            }
            replacing = true
            text.textStorage?.setAttributedString(out)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            replacing = false
            words = ws.map { (start: $0.0, end: $0.1, range: $0.2) }
            highlighted = nil
            status.stringValue = "\(words.count) words on the timeline. Click a word to go there."
        }
    }

    /// A click on a word moves the playhead to its start.
    func textViewDidChangeSelection(_ n: Notification) {
        guard !replacing else { return }
        let loc = text.selectedRange().location
        guard text.selectedRange().length == 0, let w = words.first(where: { NSLocationInRange(loc, $0.range) || loc == NSMaxRange($0.range) }) else { return }
        seek(w.start)
    }

    func seek(_ seconds: Double) {
        Task { await owner?.runTool("player.seek", .object(["time": .number(seconds)])) }
    }

    /// Marks the word under the playhead.
    func playheadMoved(_ t: Time) {
        guard !words.isEmpty, let storage = text.textStorage else { return }
        let s = t.seconds
        let i = words.lastIndex { $0.start <= s + 0.001 }
        guard i != highlighted else { return }
        if let h = highlighted, h < words.count { storage.removeAttribute(.backgroundColor, range: words[h].range) }
        highlighted = i
        if let i { storage.addAttribute(.backgroundColor, value: NSColor.systemPurple.withAlphaComponent(0.45), range: words[i].range) }
    }

    @objc func find() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let id = selectedID, let owner else { return }
        Task {
            guard let r = await owner.callTool("transcript.find", .object(["id": .string(id), "text": .string(q)])) else { return }
            let starts = (r["matches"]?.arrayValue ?? []).compactMap { $0["start"]?.doubleValue }
            if let first = starts.first {
                status.stringValue = "\(starts.count) found; at " + starts.prefix(8).map { MainWindowController.format(Time(seconds: $0)) }.joined(separator: ", ")
                seek(first)
                if let w = words.first(where: { abs($0.start - first) < 0.001 }) { text.scrollRangeToVisible(w.range) }
            } else {
                status.stringValue = "Not on the timeline (cut out or not said)."
            }
        }
    }

    @objc private func importJSON() {
        guard let p = project else { return }
        let files = p.media.filter { $0.info.audio != nil && !$0.isHyperFrames }
        guard !files.isEmpty else { owner?.show("import a file with sound first"); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "A transcript JSON: {\"words\": [...]} or Edits' {\"segments\": [...]}; times in the media file"
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        for f in files { pop.addItem(withTitle: f.name); pop.lastItem?.representedObject = f.id.raw }
        let row = NSStackView(views: [NSTextField(labelWithString: "Words of:"), pop])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url, let asset = pop.selectedItem?.representedObject as? String else { return }
        Task { await owner?.runTool("transcript.import", .object(["asset": .string(asset), "path": .string(url.path)])) }
    }

    @objc private func remove() {
        guard let id = selectedID else { return }
        shownID = nil
        Task { await owner?.runTool("transcript.remove", .object(["ids": .array([.string(id)])])) }
    }
}
