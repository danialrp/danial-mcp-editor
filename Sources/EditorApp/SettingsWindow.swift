import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// Danial MCP Editor › Settings (⌘,): every user setting as a searchable
/// list (double-click a value to change it, through settings.set), and the
/// key bindings (keymap.set, keymap.reset). Same tools an agent uses.
@MainActor
final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var mainWindow: MainWindowController?

    private let settingsTable = NSTableView()
    private let keysTable = NSTableView()
    private let filter = NSSearchField()
    private(set) var leaves: [(key: String, value: JSONValue)] = []
    private var shown: [(key: String, value: JSONValue)] = []
    private(set) var bindings: [Keymap.Binding] = []

    init(mainWindow: MainWindowController) {
        self.mainWindow = mainWindow
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        super.init(window: w)

        let tabs = NSTabView()
        // Settings
        for (id, title, width) in [("key", "Setting", 300.0), ("value", "Value", 340.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            settingsTable.addTableColumn(c)
        }
        settingsTable.dataSource = self
        settingsTable.delegate = self
        settingsTable.usesAlternatingRowBackgroundColors = true
        settingsTable.target = self
        settingsTable.doubleAction = #selector(editSetting)
        filter.placeholderString = "Filter, for example cutRules or export"
        filter.delegate = self
        let sScroll = NSScrollView()
        sScroll.documentView = settingsTable
        sScroll.hasVerticalScroller = true
        let sNote = NSTextField(labelWithString: "Double-click a value to change it. The MCP token is not shown.")
        sNote.textColor = .secondaryLabelColor
        let sStack = NSStackView(views: [filter, sScroll, sNote])
        sStack.orientation = .vertical
        sStack.alignment = .leading
        sStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        sScroll.widthAnchor.constraint(equalTo: sStack.widthAnchor, constant: -16).isActive = true
        filter.widthAnchor.constraint(equalTo: sStack.widthAnchor, constant: -16).isActive = true
        let sItem = NSTabViewItem(identifier: "settings")
        sItem.label = "Settings"
        sItem.view = sStack
        tabs.addTabViewItem(sItem)

        // Keys
        for (id, title, width) in [("key", "Key", 110.0), ("tool", "Tool", 180.0), ("args", "Arguments", 340.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            keysTable.addTableColumn(c)
        }
        keysTable.dataSource = self
        keysTable.delegate = self
        keysTable.usesAlternatingRowBackgroundColors = true
        keysTable.target = self
        keysTable.doubleAction = #selector(changeKey)
        let kScroll = NSScrollView()
        kScroll.documentView = keysTable
        kScroll.hasVerticalScroller = true
        func b(_ t: String, _ a: Selector) -> NSButton { NSButton(title: t, target: self, action: a) }
        let kBar = NSStackView(views: [b("Change key…", #selector(changeKey)), b("Add…", #selector(addBinding)),
                                       b("Remove", #selector(removeBinding)), b("Back to CapCut's keys", #selector(resetKeys))])
        let kStack = NSStackView(views: [kScroll, kBar])
        kStack.orientation = .vertical
        kStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let kItem = NSTabViewItem(identifier: "keys")
        kItem.label = "Keys"
        kItem.view = kStack
        tabs.addTabViewItem(kItem)
        w.contentView = tabs
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Brings the Keys tab to the front.
    func showKeys() {
        (window?.contentView as? NSTabView)?.selectTabViewItem(withIdentifier: "keys")
    }

    func reload() {
        guard let mainWindow else { return }
        Task {
            if let s = await mainWindow.callTool("settings.get", .object([:])) {
                var out: [(String, JSONValue)] = []
                func walk(_ v: JSONValue, _ path: String) {
                    if case .object(let o) = v, !o.isEmpty {
                        for k in o.keys.sorted() { walk(o[k]!, path.isEmpty ? k : "\(path).\(k)") }
                    } else {
                        out.append((path, v))
                    }
                }
                walk(s, "")
                leaves = out.map { (key: $0.0, value: $0.1) }
                applyFilter()
            }
            if let k = await mainWindow.callTool("keymap.get", .object([:])), let list = k["bindings"]?.arrayValue {
                bindings = list.compactMap { b in
                    guard let key = b["key"]?.stringValue, let tool = b["tool"]?.stringValue else { return nil }
                    return Keymap.Binding(key, tool, b["args"] == .null ? nil : b["args"])
                }
                keysTable.reloadData()
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        let q = filter.stringValue.lowercased()
        shown = q.isEmpty ? leaves : leaves.filter { $0.key.lowercased().contains(q) }
        settingsTable.reloadData()
    }

    static func text(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: (try? String(decoding: v.data(), as: UTF8.self)) ?? ""
        }
    }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === settingsTable ? shown.count : bindings.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let s: String
        if tableView === settingsTable {
            s = col?.identifier.rawValue == "key" ? shown[row].key : Self.text(shown[row].value)
        } else {
            let b = bindings[row]
            s = switch col?.identifier.rawValue { case "key": b.key; case "tool": b.tool; default: b.args.map(Self.text) ?? "" }
        }
        let f = NSTextField(labelWithString: s)
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = s
        return f
    }

    // MARK: settings

    /// Asks for a text and returns it, or nil when cancelled.
    private func ask(_ title: String, _ info: String, _ value: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func editSetting() {
        let i = settingsTable.clickedRow >= 0 ? settingsTable.clickedRow : settingsTable.selectedRow
        guard i >= 0, i < shown.count, let mainWindow else { return }
        let (key, old) = shown[i]
        guard let input = ask("Change \(key)", "Same type as now: number, true/false, text, or JSON for a list.", Self.text(old)) else { return }
        let value: JSONValue
        switch old {
        case .number:
            guard let n = Double(input.trimmingCharacters(in: .whitespaces)) else { mainWindow.show("\(key) needs a number"); return }
            value = .number(n)
        case .bool: value = .bool(["true", "yes", "1", "on"].contains(input.lowercased().trimmingCharacters(in: .whitespaces)))
        case .string: value = .string(input)
        default:
            guard let v = try? JSONValue.parse(Data(input.utf8)) else { mainWindow.show("\(key) needs JSON"); return }
            value = v
        }
        Task {
            await mainWindow.runTool("settings.set", .object(["key": .string(key), "value": value]))
            reload()
        }
    }

    // MARK: keys

    private var pickedBinding: Keymap.Binding? {
        let i = keysTable.clickedRow >= 0 ? keysTable.clickedRow : keysTable.selectedRow
        return i >= 0 && i < bindings.count ? bindings[i] : nil
    }

    private func setBinding(_ key: String, _ tool: String?, _ args: JSONValue?) async {
        var a: [String: JSONValue] = ["key": .string(key)]
        if let tool { a["tool"] = .string(tool) }
        if let args { a["args"] = args }
        await mainWindow?.runTool("keymap.set", .object(a))
    }

    @objc private func changeKey() {
        guard let b = pickedBinding,
              let key = ask("New key for \(b.tool)", "For example cmd+b, q, shift+left, cmd+shift+z.", b.key)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty, Keymap.normalize(key) != Keymap.normalize(b.key) else { return }
        Task {
            await setBinding(key, b.tool, b.args)
            await setBinding(b.key, nil, nil)
            reload()
            (NSApp.delegate as? AppDelegate)?.refreshMenuKeys()
        }
    }

    @objc private func addBinding() {
        guard let key = ask("Key", "For example ctrl+m or shift+s.", "")?.trimmingCharacters(in: .whitespaces), !key.isEmpty,
              let tool = ask("Tool for \(key)", "A tool name, for example timeline.split or clip.setSpeed.", "")?.trimmingCharacters(in: .whitespaces), !tool.isEmpty,
              let argsText = ask("Arguments", "JSON object, may use $playhead, $selection, $selectedTracks, $copied, $all. Leave empty for none.", "")
        else { return }
        var args: JSONValue?
        if !argsText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let v = try? JSONValue.parse(Data(argsText.utf8)) else { mainWindow?.show("the arguments are not JSON"); return }
            args = v
        }
        Task {
            await setBinding(key, tool, args)
            reload()
            (NSApp.delegate as? AppDelegate)?.refreshMenuKeys()
        }
    }

    @objc private func removeBinding() {
        guard let b = pickedBinding else { return }
        Task {
            await setBinding(b.key, nil, nil)
            reload()
            (NSApp.delegate as? AppDelegate)?.refreshMenuKeys()
        }
    }

    @objc private func resetKeys() {
        Task {
            await mainWindow?.runTool("keymap.reset", .object([:]))
            reload()
            (NSApp.delegate as? AppDelegate)?.refreshMenuKeys()
        }
    }
}
