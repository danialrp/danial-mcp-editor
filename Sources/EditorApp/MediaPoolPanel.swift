import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// The Media panel: every file in the project's media pool. Drag a row onto
/// the timeline to place it there, double-click to add it at the playhead;
/// relink a moved file, remove unused ones, or have a file transcribed.
@MainActor
final class MediaPoolPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: MainWindowController?

    private let table = NSTableView()
    private var project: Project?
    private(set) var rows: [MediaAsset] = []
    private let info = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        for (id, title, w) in [("name", "Name", 170.0), ("kind", "Kind", 60.0), ("length", "Length", 60.0), ("used", "Used", 40.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(addAtPlayhead)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        func b(_ t: String, _ a: Selector, _ tip: String) -> NSButton {
            let x = NSButton(title: t, target: self, action: a)
            x.bezelStyle = .rounded
            x.controlSize = .small
            x.toolTip = tip
            return x
        }
        let bar1 = NSStackView(views: [b("Import…", #selector(importFiles), "Add files to the pool and the timeline"),
                                       b("Add at playhead", #selector(addAtPlayhead), "Place the selected files at the playhead"),
                                       b("Relink…", #selector(relink), "Point the selected file at a moved or replaced file")])
        let bar2 = NSStackView(views: [b("Transcribe", #selector(transcribe), "Word-by-word transcript through Edits, as a job"),
                                       b("Remove unused", #selector(removeUnused), "Take files no clip uses out of the pool (the files stay on disk)"),
                                       b("Show in Finder", #selector(reveal), "")])
        let bar3 = NSStackView(views: [b("From link…", #selector(fromLink), "Download a YouTube, Pinterest, Instagram or X post by its link")])
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [bar1, bar2, bar3, scroll, info])
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
            info.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(project p: Project?) {
        guard p?.media != project?.media || p?.tracks != project?.tracks else { project = p; return }
        let picked = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        project = p
        rows = p?.media.filter { !$0.isHyperFrames } ?? []
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { picked.contains(rows[$0].id) }), byExtendingSelection: false)
        let missing = rows.filter { !FileManager.default.fileExists(atPath: $0.path) }.count
        info.stringValue = "\(rows.count) files" + (missing > 0 ? " · \(missing) missing: select and Relink" : "")
    }

    private var used: Set<EntityID> { Set(project?.tracks.flatMap { $0.clips.map(\.asset) } ?? []) }
    var selected: [MediaAsset] { table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil } }

    func select(_ ids: [EntityID]) {
        table.selectRowIndexes(IndexSet(rows.indices.filter { ids.contains(rows[$0].id) }), byExtendingSelection: false)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let a = rows[row]
        let text: String = switch col?.identifier.rawValue {
        case "name": a.name
        case "kind": a.isImage ? "picture" : a.info.video != nil ? "video" : "sound"
        case "length": a.isImage ? "—" : MainWindowController.format(a.info.duration)
        default: used.contains(a.id) ? "✓" : ""
        }
        let f = NSTextField(labelWithString: text)
        f.lineBreakMode = .byTruncatingMiddle
        if !FileManager.default.fileExists(atPath: a.path) { f.textColor = .systemRed }
        f.toolTip = a.path
        return f
    }

    /// Rows drag out as file URLs, so the timeline places them where dropped.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        URL(fileURLWithPath: rows[row].path) as NSURL
    }

    // MARK: actions

    @objc private func importFiles() { (NSApp.delegate as? AppDelegate)?.importMedia(nil) }

    @objc private func fromLink() { (NSApp.delegate as? AppDelegate)?.showDownloads(nil) }

    @objc func addAtPlayhead() {
        let urls = selected.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty, let owner else { return }
        Task { await owner.importAndAppend(urls, at: owner.timeline.pendingSeek ?? owner.runtime.player.currentTime) }
    }

    @objc private func relink() {
        guard let a = selected.first else { owner?.show("select a file in the Media list"); return }
        let panel = NSOpenPanel()
        panel.message = "Choose the file that replaces \(a.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await owner?.runTool("media.relink", .object(["id": .string(a.id.raw), "path": .string(url.path)])) }
    }

    @objc private func removeUnused() {
        let ids = (selected.isEmpty ? rows : selected).filter { !used.contains($0.id) }.map { JSONValue.string($0.id.raw) }
        guard !ids.isEmpty else { owner?.show("every file here is used by a clip"); return }
        Task { await owner?.runTool("media.remove", .object(["ids": .array(ids)])) }
    }

    @objc private func transcribe() {
        guard let a = selected.first, a.info.audio != nil else { owner?.show("select a file with sound"); return }
        Task {
            guard let r = await owner?.callTool("transcript.create", .object(["asset": .string(a.id.raw)])) else { return }
            owner?.show("Transcribing \(a.name) (job \(r["job"]?.stringValue ?? "")); the Words tab shows it when done")
        }
    }

    @objc private func reveal() {
        let urls = selected.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}
