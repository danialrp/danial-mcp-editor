import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// Edit › History: every change since the project was opened, newest first.
/// "Go back to here" undoes changes until the project is as it was then
/// (history.revertTo); redo still brings them back.
@MainActor
final class HistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var mainWindow: MainWindowController?
    private let table = NSTableView()
    private(set) var rows: [(revision: Int, op: String, at: String, commands: String)] = []

    init(mainWindow: MainWindowController) {
        self.mainWindow = mainWindow
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = "History"
        w.isFloatingPanel = false
        w.hidesOnDeactivate = false
        super.init(window: w)
        for (id, title, width) in [("rev", "Revision", 70.0), ("op", "Kind", 60.0), ("at", "Time", 90.0), ("what", "Change", 280.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(revert)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let revertButton = NSButton(title: "Go back to here", target: self, action: #selector(revert))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let note = NSTextField(labelWithString: "Redo (⇧⌘Z) brings undone changes back.")
        note.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [revertButton, refresh, note])
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        w.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        guard let mainWindow else { return }
        rows = []
        table.reloadData()
        Task {
            guard let r = await mainWindow.callTool("history.list", .object(["limit": .number(500)])) else { return }
            let out = DateFormatter()
            out.timeStyle = .medium
            let iso = ISO8601DateFormatter()
            rows = (r["changes"]?.arrayValue ?? []).reversed().map { c in
                let at = c["at"]?.stringValue.flatMap { iso.date(from: $0) }.map { out.string(from: $0) } ?? ""
                return (Int(c["revision"]?.doubleValue ?? 0), c["op"]?.stringValue ?? "",
                        at, (c["commands"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))
            }
            table.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let s: String = switch col?.identifier.rawValue {
        case "rev": String(r.revision)
        case "op": r.op
        case "at": r.at
        default: r.commands
        }
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    /// Goes back to a revision (the self-test, and the button).
    func revert(to revision: Int) async {
        await mainWindow?.runTool("history.revertTo", .object(["revision": .number(Double(revision))]))
        reload()
    }

    @objc private func revert() {
        let i = table.selectedRow
        guard i >= 0, i < rows.count, let mainWindow else { return }
        Task {
            await mainWindow.runTool("history.revertTo", .object(["revision": .number(Double(rows[i].revision))]))
            reload()
        }
    }
}
