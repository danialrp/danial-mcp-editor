import AppKit
import EditorCore
import EditorKit

/// Help › Keyboard Shortcuts: every key, grouped, with what it does. The
/// timeline keys come from the current keymap (so a changed key shows
/// here); the menu keys are listed after them. Settings › Keys changes them.
@MainActor
final class ShortcutsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var app: AppDelegate?
    private let table = NSTableView()
    private let filter = NSSearchField()
    private(set) var rows: [(group: String, key: String, action: String)] = []
    private var shown: [(group: String, key: String, action: String)] = []

    init(app: AppDelegate) {
        self.app = app
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        super.init(window: w)
        for (id, title, width) in [("group", "", 110.0), ("key", "Key", 110.0), ("action", "Does", 300.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        filter.placeholderString = "Find a key or an action"
        filter.delegate = self
        let change = NSButton(title: "Change Keys…", target: self, action: #selector(changeKeys))
        change.bezelStyle = .rounded
        let note = NSTextField(labelWithString: "Timeline keys work when no text field is being edited.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [note, NSView(), change])
        let stack = NSStackView(views: [filter, scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for v in [filter, scroll, bar] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        w.contentView = stack
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What a binding does, in words: the menu title of the same tool and
    /// arguments, else the tool's name.
    static func describe(_ b: Keymap.Binding, entries: [NSMenuItem]) -> String {
        for i in entries {
            guard let e = i.representedObject as? AppDelegate.Entry, e.tool == b.tool,
                  (e.args ?? .object([:])) == (b.args ?? .object([:])) else { continue }
            return e.title
        }
        if b.tool == "player.jump", let to = b.args?["to"]?.stringValue {
            return ["previousEdge": "Previous edit (start of the clip)", "nextEdge": "Next edit (end of the clip)", "start": "Go to start", "end": "Go to end"][to] ?? to
        }
        if b.tool == "player.step", let f = b.args?["frames"]?.doubleValue {
            return f < 0 ? "Back \(Int(-f)) frame\(f == -1 ? "" : "s")" : "Forward \(Int(f)) frame\(f == 1 ? "" : "s")"
        }
        if b.tool == "ui.zoom", let to = b.args?["to"]?.stringValue { return ["in": "Zoom in", "out": "Zoom out", "fit": "Zoom to fit"][to] ?? to }
        return b.tool
    }

    static func group(_ tool: String) -> String {
        switch tool.split(separator: ".").first.map(String.init) ?? "" {
        case "player": "Playback"
        case "history": "Edit"
        case "ui": "Selection"
        case "marker", "timeline": "Timeline"
        default: "Clips"
        }
    }

    func reload() {
        guard let app else { return }
        let order = ["Playback", "Timeline", "Clips", "Selection", "Edit"]
        var out = app.runtime.keymap.current.bindings.map { b in
            (group: Self.group(b.tool), key: AppDelegate.glyphs(b.key), action: Self.describe(b, entries: app.entries))
        }
        out.sort { (order.firstIndex(of: $0.group) ?? 9, $0.action) < (order.firstIndex(of: $1.group) ?? 9, $1.action) }
        // Keys of the menus themselves.
        var menuKeys: [(String, String, String)] = []
        for top in NSApp.mainMenu?.items ?? [] {
            for i in top.submenu?.items ?? [] where !i.keyEquivalent.isEmpty {
                var mods = ""
                let m = i.keyEquivalentModifierMask
                if m.contains(.control) { mods += "⌃" }
                if m.contains(.option) { mods += "⌥" }
                if m.contains(.shift) || i.keyEquivalent != i.keyEquivalent.lowercased() { mods += "⇧" }
                if m.contains(.command) { mods += "⌘" }
                menuKeys.append(("Menus", mods + i.keyEquivalent.uppercased(), "\(top.title) › \(i.title)"))
            }
        }
        rows = out + menuKeys.map { (group: $0.0, key: $0.1, action: $0.2) }
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        let q = filter.stringValue.lowercased()
        let list = q.isEmpty ? rows : rows.filter { $0.action.lowercased().contains(q) || $0.key.lowercased().contains(q) }
        // The group name only on the first row of each group.
        shown = list.enumerated().map { i, r in (i > 0 && list[i - 1].group == r.group) ? (group: "", key: r.key, action: r.action) : r }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = shown[row]
        let f: NSTextField
        switch col?.identifier.rawValue {
        case "group":
            f = NSTextField(labelWithString: r.group)
            f.font = .systemFont(ofSize: 12, weight: .semibold)
        case "key":
            f = NSTextField(labelWithString: r.key)
            f.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        default:
            f = NSTextField(labelWithString: r.action)
        }
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    @objc private func changeKeys() { app?.showSettings(keys: true) }
}
