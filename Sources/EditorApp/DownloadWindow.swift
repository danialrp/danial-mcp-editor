import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// File › Download from Link: a post from YouTube, Pinterest, Instagram or X
/// by its link (social.download), the downloads present (social.list), a
/// look at one (social.inspect: contact sheet, length, loudness, captions),
/// adding it to the timeline, and moving downloads to the Trash
/// (social.cleanup). The same tools an agent uses for references.
@MainActor
final class DownloadWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var mainWindow: MainWindowController?

    let url = NSTextField()
    let what = NSPopUpButton(frame: .zero, pullsDown: false)
    let quality = NSPopUpButton(frame: .zero, pullsDown: false)
    let subtitles = NSButton(checkboxWithTitle: "Captions", target: nil, action: nil)
    let addToProject = NSButton(checkboxWithTitle: "Add to project", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let sheet = NSImageView()
    private let details = NSTextView()
    private(set) var rows: [JSONValue] = []
    /// The download job running from this window, if any.
    private(set) var job: String?

    init(mainWindow: MainWindowController) {
        self.mainWindow = mainWindow
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Download from Link"
        super.init(window: w)

        url.placeholderString = "Link to a YouTube video, Pinterest pin, Instagram post or X post"
        url.target = self
        url.action = #selector(download)
        what.addItems(withTitles: ["Everything", "Video", "Sound only", "Pictures"])
        let qs = mainWindow.runtime.editor.settings.current.downloader
        quality.addItems(withTitles: qs.qualities.keys.sorted { (Int($0) ?? 99999) > (Int($1) ?? 99999) })
        quality.selectItem(withTitle: qs.defaultQuality)
        addToProject.state = .on
        func b(_ t: String, _ a: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: a)
            x.bezelStyle = .rounded
            return x
        }
        let go = b("Download", #selector(download))
        go.keyEquivalent = "\r"
        let row1 = NSStackView(views: [url, b("Info", #selector(info)), go])
        url.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A long link must not widen the window.
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        url.lineBreakMode = .byTruncatingTail
        url.cell?.isScrollable = true
        let row2 = NSStackView(views: [NSTextField(labelWithString: "Get"), what, NSTextField(labelWithString: "Quality"), quality, subtitles, addToProject])
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)

        for (id, title, width) in [("title", "Title", 300.0), ("platform", "Site", 80.0), ("size", "Size", 70.0), ("use", "In project", 90.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(inspect)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let row3 = NSStackView(views: [b("Look at it", #selector(inspect)), b("Add at playhead", #selector(addAtPlayhead)),
                                       b("Show in Finder", #selector(reveal)), b("Move to Trash", #selector(trash)),
                                       b("Move all to Trash…", #selector(trashAll)), b("Refresh", #selector(reload))])
        sheet.imageScaling = .scaleProportionallyUpOrDown
        sheet.setContentHuggingPriority(.defaultLow, for: .vertical)
        // A tall picture must not grow the window.
        sheet.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sheet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        details.isEditable = false
        details.drawsBackground = false
        details.font = .systemFont(ofSize: 11)
        details.baseWritingDirection = .natural
        let dScroll = NSScrollView()
        dScroll.documentView = details
        dScroll.hasVerticalScroller = true
        dScroll.drawsBackground = false
        details.autoresizingMask = [.width]
        let lower = NSSplitView()
        lower.isVertical = true
        lower.addArrangedSubview(sheet)
        lower.addArrangedSubview(dScroll)

        let stack = NSStackView(views: [row1, row2, status, scroll, row3, lower])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [row1, status, scroll, lower] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        lower.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.preferredMaxLayoutWidth = 700
        w.contentView = stack
        w.setContentSize(NSSize(width: 760, height: 640))
        w.minSize = NSSize(width: 600, height: 520)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: downloading

    var whatValue: String { ["all", "video", "audio", "images"][max(0, what.indexOfSelectedItem)] }

    @objc func download() {
        let link = url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let mainWindow else { status.stringValue = "Paste a link first."; return }
        var args: [String: JSONValue] = ["url": .string(link), "what": .string(whatValue), "subtitles": .bool(subtitles.state == .on)]
        if let q = quality.titleOfSelectedItem { args["quality"] = .string(q) }
        let wantsImport = addToProject.state == .on && mainWindow.project != nil
        status.stringValue = "Starting…"
        Task {
            guard let r = await mainWindow.callTool("social.download", .object(args)), let id = r["jobId"]?.stringValue else {
                status.stringValue = mainWindow.message?.0 ?? "The download did not start."
                return
            }
            job = id
            let downloadID = r["id"]?.stringValue
            while true {
                guard let i = try? await mainWindow.runtime.jobs.info(id) else { break }
                if i.state == .running {
                    status.stringValue = "\(Int(i.progress * 100))%  \(i.message)"
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                job = nil
                switch i.state {
                case .done:
                    let files = i.result?["files"]?.arrayValue ?? []
                    let title = i.result?["metadata"]?["title"]?.stringValue ?? link
                    status.stringValue = "Downloaded \(files.count) file\(files.count == 1 ? "" : "s"): \(title)"
                    if wantsImport {
                        let paths = (i.result?["paths"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(fileURLWithPath: $0) }
                            .filter { !["json", "vtt", "srt"].contains($0.pathExtension.lowercased()) }
                        if !paths.isEmpty { await mainWindow.importAndAppend(paths, at: mainWindow.timeline.pendingSeek ?? mainWindow.runtime.player.currentTime) }
                    }
                case .cancelled: status.stringValue = "Cancelled."
                default: status.stringValue = "Failed: \(i.error ?? "")"
                }
                break
            }
            await reloadNow()
            if let downloadID, let row = rows.firstIndex(where: { $0["id"]?.stringValue == downloadID }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                await inspectNow()
            }
        }
    }

    @objc private func info() {
        let link = url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let mainWindow else { return }
        status.stringValue = "Reading…"
        Task {
            guard let r = await mainWindow.callTool("social.info", .object(["url": .string(link)])) else {
                status.stringValue = mainWindow.message?.0 ?? ""
                return
            }
            sheet.image = nil
            details.string = Self.describe(r["metadata"] ?? .null) + (r["needsLogin"]?.stringValue.map { "\n\nNeeds a sign-in: \($0)" } ?? "")
            status.stringValue = r["metadata"]?["title"]?.stringValue ?? "Read."
        }
    }

    // MARK: the list

    @objc func reload() { Task { await reloadNow() } }

    func reloadNow() async {
        guard let r = await mainWindow?.callTool("social.list", .object([:])) else { return }
        rows = r["downloads"]?.arrayValue ?? []
        table.reloadData()
        let mb = (r["bytes"]?.doubleValue ?? 0) / 1_048_576
        if job == nil, status.stringValue.isEmpty || status.stringValue.hasPrefix("Downloads") {
            status.stringValue = "Downloads: \(rows.count), \(String(format: "%.1f", mb)) MB"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let s: String = switch col?.identifier.rawValue {
        case "title": r["title"]?.stringValue ?? r["id"]?.stringValue ?? ""
        case "platform": r["platform"]?.stringValue ?? ""
        case "size": String(format: "%.1f MB", (r["bytes"]?.doubleValue ?? 0) / 1_048_576)
        default: (r["usedByClips"]?.doubleValue ?? 0) > 0 ? "on timeline" : r["imported"]?.boolValue == true ? "in pool" : ""
        }
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = r["url"]?.stringValue
        return f
    }

    var selectedIDs: [String] { table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0]["id"]?.stringValue : nil } }

    func select(_ id: String) {
        if let i = rows.firstIndex(where: { $0["id"]?.stringValue == id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    // MARK: actions on downloads

    @objc func inspect() { Task { await inspectNow() } }

    /// Contact sheet on the left, metadata, loudness and captions on the right.
    func inspectNow() async {
        guard let id = selectedIDs.first, let mainWindow else { return }
        guard let r = await mainWindow.callTool("social.inspect", .object(["id": .string(id), "inline": .bool(false)])) else { return }
        if let p = r["sheet"]?["path"]?.stringValue { sheet.image = NSImage(contentsOfFile: p) } else { sheet.image = nil }
        var text = Self.describe(r["metadata"] ?? .null)
        if let a = r["audio"], a != .null { text += "\n\nSound:\n" + Self.describe(a) }
        for sub in r["subtitles"]?.arrayValue ?? [] {
            text += "\n\nCaptions (\(sub["language"]?.stringValue ?? "?")):\n" + (sub["text"]?.stringValue ?? "")
        }
        details.string = text
    }

    @objc private func addAtPlayhead() {
        guard let mainWindow else { return }
        let paths = table.selectedRowIndexes.flatMap { i -> [URL] in
            guard i < rows.count, let folder = rows[i]["folder"]?.stringValue else { return [] }
            return (rows[i]["files"]?.arrayValue ?? []).filter { ["video", "audio", "image"].contains($0["kind"]?.stringValue ?? "") }
                .compactMap { $0["name"]?.stringValue }.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        guard !paths.isEmpty else { status.stringValue = "Select a download with a video, sound or picture."; return }
        Task {
            await mainWindow.importAndAppend(paths, at: mainWindow.timeline.pendingSeek ?? mainWindow.runtime.player.currentTime)
            await reloadNow()
        }
    }

    @objc private func reveal() {
        let urls = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0]["folder"]?.stringValue : nil }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func trash() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        Task { await cleanup(["ids": .array(ids.map { .string($0) })]) }
    }

    @objc private func trashAll() {
        let a = NSAlert()
        a.messageText = "Move every download to the Trash?"
        a.informativeText = "Downloads that clips use stay; the Trash keeps the rest until it is emptied."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await cleanup(["all": .bool(true)]) }
    }

    func cleanup(_ args: [String: JSONValue]) async {
        guard let r = await mainWindow?.callTool("social.cleanup", .object(args)) else { return }
        let n = r["trashed"]?.arrayValue?.count ?? 0, refused = r["refused"]?.arrayValue?.count ?? 0
        status.stringValue = "Moved \(n) to the Trash (\(String(format: "%.1f", (r["bytesFreed"]?.doubleValue ?? 0) / 1_048_576)) MB)"
            + (refused > 0 ? "; \(refused) kept because clips use them" : "")
        sheet.image = nil
        details.string = ""
        await reloadNow()
    }

    static func describe(_ v: JSONValue) -> String {
        guard case .object(let o) = v else { return SettingsWindow.text(v) }
        return o.keys.sorted().compactMap { k -> String? in
            let x = o[k]!
            if x == .null { return nil }
            if case .array(let a) = x, a.isEmpty { return nil }
            return "\(k): " + (k == "description" ? (x.stringValue ?? "") : SettingsWindow.text(x)).prefix(600)
        }.joined(separator: "\n")
    }
}
