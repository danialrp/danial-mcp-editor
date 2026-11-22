import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// View › Agent Notes: the notes agents keep in the project (spec,
/// progress, decisions, notes on clips), listed with their summary and
/// shown as formatted Markdown. A note about clips or a time range can
/// select those clips or move the playhead there. Search runs notes.find.
@MainActor
final class NotesWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var mainWindow: MainWindowController?
    private let table = NSTableView()
    let text = NSTextView()
    private let search = NSSearchField()
    private let info = NSTextField(labelWithString: "")
    private let goButton = NSButton(title: "Go to its time", target: nil, action: nil)
    private let clipsButton = NSButton(title: "Select its clips", target: nil, action: nil)
    private(set) var notes: [JSONValue] = []
    private var shown: JSONValue?

    init(mainWindow: MainWindowController) {
        self.mainWindow = mainWindow
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Agent Notes"
        w.minSize = NSSize(width: 640, height: 400)
        super.init(window: w)

        for (id, title, width) in [("name", "Note", 140.0), ("summary", "Summary", 170.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        search.placeholderString = "Search every note"
        search.delegate = self
        search.target = self
        search.action = #selector(find)
        search.sendsSearchStringImmediately = false
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let left = NSStackView(views: [search, listScroll, refresh])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 8)
        listScroll.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -22).isActive = true
        search.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -22).isActive = true

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.baseWritingDirection = .natural
        let textScroll = NSScrollView()
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingTail
        goButton.target = self
        goButton.action = #selector(goToTime)
        clipsButton.target = self
        clipsButton.action = #selector(selectClips)
        for b in [goButton, clipsButton, refresh] { b.bezelStyle = .rounded }
        let bar = NSStackView(views: [info, NSView(), clipsButton, goButton])
        bar.spacing = 8
        let right = NSStackView(views: [bar, textScroll])
        right.orientation = .vertical
        right.spacing = 10
        right.edgeInsets = NSEdgeInsets(top: 14, left: 8, bottom: 14, right: 14)
        bar.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -22).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        w.contentView = split
        w.center()
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() { Task { await reloadNow() } }

    func reloadNow() async {
        guard let mainWindow else { return }
        guard mainWindow.project != nil else {
            notes = []
            table.reloadData()
            show(nil)
            text.string = "Open a project to see its notes."
            return
        }
        guard let r = await mainWindow.callTool("notes.list", .object([:])) else { return }
        notes = r["notes"]?.arrayValue ?? []
        table.reloadData()
        if notes.isEmpty { show(nil); text.string = "No notes yet. Agents write them with notes.write (spec, progress, decisions)." }
        else if let name = shown?["name"]?.stringValue, let i = notes.firstIndex(where: { $0["name"]?.stringValue == name }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let n = notes[row]
        let s = col?.identifier.rawValue == "name" ? (n["title"]?.stringValue ?? n["name"]?.stringValue ?? "") : (n["summary"]?.stringValue ?? "")
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = s
        if col?.identifier.rawValue == "name" { f.font = .systemFont(ofSize: 12, weight: .medium) }
        return f
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let i = table.selectedRow
        guard i >= 0, i < notes.count, let name = notes[i]["name"]?.stringValue else { return }
        Task { await open(name) }
    }

    /// Shows a note as formatted Markdown with its clips, range and revision.
    func open(_ name: String) async {
        guard let r = await mainWindow?.callTool("notes.read", .object(["name": .string(name)])) else { return }
        show(r)
        text.textStorage?.setAttributedString(Self.render(r["content"]?.stringValue ?? ""))
        text.scrollToBeginningOfDocument(nil)
    }

    private func show(_ n: JSONValue?) {
        shown = n
        var parts: [String] = []
        if let n {
            if let rev = n["revision"]?.doubleValue { parts.append("written at revision \(Int(rev))") }
            if let u = n["updated"]?.stringValue { parts.append(u.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")) }
            if let c = n["clips"]?.arrayValue, !c.isEmpty { parts.append("\(c.count) clip\(c.count == 1 ? "" : "s")") }
            if let gone = n["clipsNoLongerInProject"]?.arrayValue, !gone.isEmpty { parts.append("\(gone.count) no longer in the project") }
        }
        info.stringValue = parts.joined(separator: " · ")
        goButton.isEnabled = n?["from"]?.doubleValue != nil
        clipsButton.isEnabled = !(n?["clips"]?.arrayValue ?? []).isEmpty
    }

    /// Markdown to styled text: headings, lists, bold, italic, code and links.
    static func render(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        var inCode = false
        for raw in md.components(separatedBy: "\n") {
            var line = raw
            var attrs = body
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 4
            para.baseWritingDirection = .natural
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            } else if let m = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[m] == " " {
                let level = line.distance(from: line.startIndex, to: m)
                line = String(line[line.index(after: m)...])
                attrs[.font] = NSFont.systemFont(ofSize: [20, 17, 15, 14][min(level, 4) - 1], weight: .semibold)
                para.paragraphSpacingBefore = 10
            } else if let r = line.range(of: #"^\s*([-*]|\d+\.)\s+"#, options: .regularExpression) {
                let marker = line[r].trimmingCharacters(in: .whitespaces)
                line = (marker.first?.isNumber == true ? marker + " " : "•  ") + line[r.upperBound...]
                para.headIndent = 18
                para.firstLineHeadIndent = 4
            }
            attrs[.paragraphStyle] = para
            let piece: NSAttributedString
            if !inCode, let a = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                let m = NSMutableAttributedString(a)
                m.addAttributes(attrs.filter { $0.key != .font }, range: NSRange(location: 0, length: m.length))
                // Keep bold and italic from the Markdown, at this line's size.
                let base = attrs[.font] as? NSFont ?? .systemFont(ofSize: 13)
                m.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: m.length)) { v, range, _ in
                    let intent = InlinePresentationIntent(rawValue: (v as? UInt) ?? 0)
                    var f = base
                    if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                    if intent.contains(.code) { f = .monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular) }
                    m.addAttribute(.font, value: f, range: range)
                }
                piece = m
            } else {
                piece = NSAttributedString(string: line, attributes: attrs)
            }
            out.append(piece)
            out.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        return out
    }

    @objc private func find() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let mainWindow else { reload(); return }
        Task {
            guard let r = await mainWindow.callTool("notes.find", .object(["query": .string(q)])) else { return }
            let hits = r["matches"]?.arrayValue ?? []
            show(nil)
            var lines: [String] = []
            for h in hits {
                let note = h["note"]?.stringValue ?? ""
                let heading = h["heading"]?.stringValue ?? ""
                let line = h["line"]?.stringValue ?? ""
                lines.append("- **\(note)**" + (heading.isEmpty ? "" : " › \(heading)") + ": " + line)
            }
            let md = hits.isEmpty ? "Nothing found for **\(q)**." : "## \(hits.count) found for \(q)\n" + lines.joined(separator: "\n")
            text.textStorage?.setAttributedString(Self.render(md))
        }
    }

    @objc private func goToTime() {
        guard let f = shown?["from"]?.doubleValue else { return }
        Task { await mainWindow?.runTool("player.seek", .object(["time": .number(f)])) }
    }

    @objc private func selectClips() {
        guard let ids = shown?["clips"]?.arrayValue?.compactMap(\.stringValue) else { return }
        mainWindow?.timeline.select(ids.map { EntityID($0) })
    }
}
