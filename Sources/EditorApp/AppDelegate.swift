import AppKit
import EditorCore
import EditorKit
import MCPServer
import MediaEngine
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: EditorRuntime!
    var server: HTTPTransport?
    var window: MainWindowController!
    var serverStatus = "MCP: starting"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings: UserSettingsStore
        do {
            settings = try UserSettingsStore()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        runtime = EditorRuntime(settings: settings)
        window = MainWindowController(runtime: runtime)
        window.statusProvider = { [weak self] in self?.serverStatus ?? "" }
        NSApp.mainMenu = buildMenu()
        window.showWindow(nil)
        NSApp.activate()
        startServer(settings)
        Task { await window.followSessions() }
        // Reopen the last project.
        if let last = settings.current.recentProjects.first, FileManager.default.fileExists(atPath: last) {
            run("project.open", ["path": .string(last)])
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // An agent may have changed the keymap meanwhile.
        if runtime != nil { refreshMenuKeys() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            try? await runtime.editor.closeProject()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func startServer(_ settings: UserSettingsStore) {
        let port = settings.current.mcp.port
        let handler = MCPHandler(editor: runtime.editor, tools: runtime.tools + window.uiTools)
        let s = HTTPTransport(handler: handler, port: port, token: settings.current.mcp.token)
        server = s
        Task {
            do {
                try await s.start()
                serverStatus = "MCP: 127.0.0.1:\(port)"
            } catch {
                serverStatus = "MCP: port \(port) busy (is dme serve running?)"
            }
            window.refreshStatus()
        }
    }

    /// Runs a tool and shows its error, if any. Every menu item and key goes
    /// through here, the same way agents do.
    func run(_ name: String, _ args: [String: JSONValue] = [:]) {
        Task { await window.runTool(name, .object(args)) }
    }

    // MARK: menu actions

    @objc func newProject(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldStringValue = "Untitled.dmeproj"
        let presets = runtime.editor.settings.current.projectPresets.keys.sorted()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: presets)
        popup.selectItem(withTitle: "reel")
        popup.sizeToFit()
        let label = NSTextField(labelWithString: "Preset:")
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = stack
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("project.create", ["path": .string(url.path), "preset": .string(popup.titleOfSelectedItem ?? "reel")])
    }

    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .dmeproj project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("project.open", ["path": .string(url.path)])
    }

    @objc func closeProject(_ sender: Any?) { run("project.close") }

    @objc func importMedia(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .video, .image]
        panel.message = "Files are used where they are, never copied. Footage goes to the end of the main track; pictures and sound go on a free track at the playhead. You can also drop files on the timeline or the picture."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await window.importAndAppend(urls) }
    }

    /// File › Export: a preset and a file, then the same export.start an agent uses.
    @objc func exportFile(_ sender: Any?) {
        let presets = runtime.editor.settings.current.exportPresets
        let names = presets.keys.sorted()
        guard !names.isEmpty else { window.show("no export presets in settings"); return }
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.nameFieldStringValue = (window.window?.title.components(separatedBy: " — ").first ?? "Export")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: names)
        popup.selectItem(withTitle: names.contains("reel") ? "reel" : names[0])
        let summary = NSTextField(labelWithString: "")
        summary.textColor = .secondaryLabelColor
        let update = { [weak panel] in
            let p = presets[popup.titleOfSelectedItem ?? ""]
            summary.stringValue = p?.summary ?? ""
            panel?.allowedContentTypes = p?.container == .mov ? [.quickTimeMovie] : [.mpeg4Movie]
        }
        update()
        let target = PopupTarget(update)
        popup.target = target
        popup.action = #selector(PopupTarget.changed)
        let stack = NSStackView(views: [NSTextField(labelWithString: "Preset:"), popup, summary])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = stack
        let ok = panel.runModal() == .OK
        _ = target
        guard ok, let url = panel.url, let preset = popup.titleOfSelectedItem else { return }
        // The save panel already asked about replacing an existing file.
        Task { await window.startExport(path: url.path, preset: preset, overwrite: FileManager.default.fileExists(atPath: url.path)) }
    }

    @objc func cancelExport(_ sender: Any?) { window.cancelExport() }

    /// File › Verify Exported File: export.verify on a file, result in an alert.
    @objc func verifyExport(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = "Choose an exported file to check against the project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let r = await window.callTool("export.verify", .object(["path": .string(url.path)])) else { return }
            let a = NSAlert()
            a.messageText = "Exported file: \(url.lastPathComponent)"
            a.informativeText = String(Self.describe(r).prefix(1500))
            a.runModal()
        }
    }

    /// Readable key: value lines of a tool result.
    static func describe(_ v: JSONValue, _ indent: String = "") -> String {
        guard case .object(let o) = v else { return indent + SettingsWindow.text(v) }
        return o.keys.sorted().map { k in
            if case .object = o[k]! { return "\(indent)\(k):\n" + describe(o[k]!, indent + "  ") }
            return "\(indent)\(k): \(SettingsWindow.text(o[k]!))"
        }.joined(separator: "\n")
    }

    /// File › Save Export Preset: a new preset from an existing one with a
    /// changed size, frame rate or bit rate.
    @objc func saveExportPreset(_ sender: Any?) {
        let presets = runtime.editor.settings.current.exportPresets.keys.sorted()
        guard !presets.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Save Export Preset"
        a.informativeText = "Starts from the chosen preset; empty fields keep its values."
        let from = NSPopUpButton(frame: .zero, pullsDown: false)
        from.addItems(withTitles: presets)
        let name = NSTextField(string: ""), w = NSTextField(string: ""), h = NSTextField(string: ""), fps = NSTextField(string: ""), mbps = NSTextField(string: "")
        name.placeholderString = "name"; w.placeholderString = "width"; h.placeholderString = "height"; fps.placeholderString = "fps"; mbps.placeholderString = "Mbps"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "From"), from], [NSTextField(labelWithString: "Name"), name],
                                      [NSTextField(labelWithString: "Size"), NSStackView(views: [w, h])],
                                      [NSTextField(labelWithString: "Frame rate"), fps], [NSTextField(labelWithString: "Video bit rate"), mbps]])
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 150)
        for f in [name, w, h, fps, mbps] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true }
        a.accessoryView = grid
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, !name.stringValue.isEmpty else { return }
        var args: [String: JSONValue] = ["name": .string(name.stringValue), "from": .string(from.titleOfSelectedItem ?? presets[0])]
        if let v = Int(w.stringValue) { args["width"] = .number(Double(v)) }
        if let v = Int(h.stringValue) { args["height"] = .number(Double(v)) }
        if let v = Int(fps.stringValue) { args["frameRate"] = .number(Double(v)) }
        if let v = Double(mbps.stringValue) { args["videoBitrateMbps"] = .number(v) }
        run("export.savePreset", args)
    }

    @objc func clearExportCache(_ sender: Any?) {
        Task {
            let info = await window.callTool("export.cacheInfo", .object([:]))
            let a = NSAlert()
            a.messageText = "Move cached export segments to the Trash?"
            a.informativeText = "The next export renders everything again." + (info.map { "\n\n" + Self.describe($0).prefix(600) } ?? "")
            a.addButton(withTitle: "Move to Trash")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            run("export.clearCache")
        }
    }

    /// File › Project Settings: name, canvas size, frame rate, dynamic range.
    @objc func projectSettings(_ sender: Any?) {
        guard let p = window.project else { window.show("open or create a project first"); return }
        let a = NSAlert()
        a.messageText = "Project Settings"
        a.informativeText = "Frame rate can change only while the timeline is empty."
        let name = NSTextField(string: p.name), w = NSTextField(string: String(p.settings.width)), h = NSTextField(string: String(p.settings.height))
        let fps = NSTextField(string: String(p.settings.frameRate.fps))
        let hdr = NSPopUpButton(frame: .zero, pullsDown: false)
        hdr.addItems(withTitles: ["sdr", "hlg"])
        hdr.selectItem(withTitle: p.settings.dynamicRange.rawValue)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name"), name], [NSTextField(labelWithString: "Canvas"), NSStackView(views: [w, h])],
                                      [NSTextField(labelWithString: "Frame rate"), fps], [NSTextField(labelWithString: "Dynamic range"), hdr]])
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        a.accessoryView = grid
        a.addButton(withTitle: "Apply")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var args: [String: JSONValue] = [:]
        if name.stringValue != p.name { args["name"] = .string(name.stringValue) }
        if let v = Int(w.stringValue), v != p.settings.width { args["width"] = .number(Double(v)) }
        if let v = Int(h.stringValue), v != p.settings.height { args["height"] = .number(Double(v)) }
        if let v = Int(fps.stringValue), v != p.settings.frameRate.fps { args["frameRate"] = .number(Double(v)) }
        if let d = hdr.titleOfSelectedItem, d != p.settings.dynamicRange.rawValue { args["dynamicRange"] = .string(d) }
        if !args.isEmpty { run("project.setSettings", args) }
    }

    private(set) var historyWindow: HistoryWindow?
    @objc func showHistory(_ sender: Any?) {
        if historyWindow == nil { historyWindow = HistoryWindow(mainWindow: window) }
        historyWindow?.reload()
        historyWindow?.showWindow(nil)
    }

    private(set) var downloadWindow: DownloadWindow?
    @objc func showDownloads(_ sender: Any?) {
        if downloadWindow == nil { downloadWindow = DownloadWindow(mainWindow: window) }
        downloadWindow?.reload()
        downloadWindow?.showWindow(nil)
    }

    private(set) var settingsWindow: SettingsWindow?
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindow(mainWindow: window) }
        settingsWindow?.reload()
        settingsWindow?.showWindow(nil)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        run("project.open", ["path": .string(path)])
    }

    @objc func showTab(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        window.showTab(label)
    }

    @objc func zoomIn(_ sender: Any?) { window.timeline.zoom(by: 1.5) }
    @objc func zoomOut(_ sender: Any?) { window.timeline.zoom(by: 1 / 1.5) }
    @objc func zoomToFit(_ sender: Any?) { window.timeline.zoomToFit() }
    @objc func browserSidebar(_ sender: Any?) { run("browser.open", ["layout": .string("sidebar")]) }
    @objc func browserWindow(_ sender: Any?) { run("browser.open", ["layout": .string("window")]) }
    @objc func browserHide(_ sender: Any?) { run("browser.close") }

    // MARK: menu items that run tools

    /// A menu item that runs a tool with key-binding style arguments
    /// ($playhead, $selection …). Its title shows the key bound to the same
    /// tool and arguments, whatever the keymap says now.
    final class Entry: NSObject {
        let title: String, tool: String, args: JSONValue?
        init(_ title: String, _ tool: String, _ args: JSONValue?) { self.title = title; self.tool = tool; self.args = args }
    }
    private(set) var entries: [NSMenuItem] = []

    @objc func runEntry(_ sender: NSMenuItem) {
        guard let e = sender.representedObject as? Entry else { return }
        window.runBinding(tool: e.tool, args: e.args)
    }

    /// Puts the current key of each entry's binding into its title.
    func refreshMenuKeys() {
        let bindings = runtime.keymap.current.bindings
        for item in entries {
            guard let e = item.representedObject as? Entry else { continue }
            let b = bindings.first { $0.tool == e.tool && ($0.args ?? .object([:])) == (e.args ?? .object([:])) }
            item.title = b.map { "\(e.title)    \(Self.glyphs($0.key))" } ?? e.title
        }
    }

    /// "cmd+shift+z" → "⇧⌘Z".
    static func glyphs(_ key: String) -> String {
        let parts = Keymap.normalize(key).split(separator: "+").map(String.init)
        let mods: [String: String] = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
        let names: [String: String] = ["space": "Space", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "Home", "end": "End",
                                       "delete": "⌫", "forwarddelete": "⌦", "return": "↩", "escape": "Esc", "tab": "⇥",
                                       "pageup": "⇞", "pagedown": "⇟"]
        guard let last = parts.last else { return key }
        return parts.dropLast().compactMap { mods[$0] }.joined() + (names[last] ?? last.uppercased())
    }

    // MARK: menu

    private weak var recentMenu: NSMenu?

    private(set) var shortcutsWindow: ShortcutsWindow?
    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil { shortcutsWindow = ShortcutsWindow(app: self) }
        shortcutsWindow?.reload()
        shortcutsWindow?.showWindow(nil)
    }

    private(set) var notesWindow: NotesWindow?
    @objc func showNotes(_ sender: Any?) {
        if notesWindow == nil { notesWindow = NotesWindow(mainWindow: window) }
        notesWindow?.reload()
        notesWindow?.showWindow(nil)
    }

    func showSettings(keys: Bool) {
        showSettings(nil)
        if keys { settingsWindow?.showKeys() }
    }

    @objc func openAgentGuide(_ sender: Any?) {
        if let url = Bundle.main.url(forResource: "agent-guide", withExtension: "md") { NSWorkspace.shared.open(url) }
    }

    @objc func copyConnection(_ sender: Any?) {
        let port = runtime.editor.settings.current.mcp.port
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(port)/mcp", forType: .string)
        window.show("MCP address copied: http://127.0.0.1:\(port)/mcp")
    }

    /// The menu bar, laid out as macOS apps are: the app, File, Edit, Clip,
    /// Timeline, Playback, View, Window, Help. Items that edit run their tool
    /// through the keymap's arguments; their titles show the current key.
    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        entries = []
        @discardableResult
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = m
            main.addItem(item)
            return m
        }
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            i.submenu = m
            return i
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            i.target = target ?? self
            return i
        }
        /// A standard item for the first responder (text fields get it first).
        func std(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func tool(_ title: String, _ name: String, _ args: [String: JSONValue]? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(runEntry(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = Entry(title, name, args.map { .object($0) })
            entries.append(i)
            return i
        }
        let playhead = JSONValue.string("$playhead"), sel = JSONValue.string("$selection")

        menu("Danial MCP Editor", [
            NSMenuItem(title: "About Danial MCP Editor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            std("Hide Danial MCP Editor", #selector(NSApplication.hide(_:)), "h"),
            std("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            std("Quit Danial MCP Editor", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentSub = NSMenu(title: "Open Recent")
        recentSub.delegate = self
        recent.submenu = recentSub
        recentMenu = recentSub
        menu("File", [
            item("New Project…", #selector(newProject(_:)), "n"),
            item("Open Project…", #selector(openProject(_:)), "o"),
            recent,
            .separator(),
            item("Close Project", #selector(closeProject(_:)), "w", [.command, .shift]),
            item("Project Settings…", #selector(projectSettings(_:)), ";", [.command, .option]),
            .separator(),
            item("Import Media…", #selector(importMedia(_:)), "i"),
            item("Download from Link…", #selector(showDownloads(_:)), "d", [.command, .shift]),
            .separator(),
            item("Export…", #selector(exportFile(_:)), "e"),
            item("Cancel Export", #selector(cancelExport(_:))),
            item("Verify Exported File…", #selector(verifyExport(_:))),
            sub("Export Presets", [
                item("Save Export Preset…", #selector(saveExportPreset(_:))),
                item("Clear Export Cache…", #selector(clearExportCache(_:))),
            ]),
        ])

        menu("Edit", [
            tool("Undo", "history.undo"),
            tool("Redo", "history.redo"),
            item("History…", #selector(showHistory(_:)), "y"),
            .separator(),
            std("Cut", #selector(NSText.cut(_:)), "x"),
            std("Copy", #selector(NSText.copy(_:)), "c"),
            std("Paste", #selector(NSText.paste(_:)), "v"),
            tool("Duplicate", "clip.duplicate", ["ids": sel]),
            tool("Delete", "clip.remove", ["ids": sel]),
            .separator(),
            std("Select All", #selector(NSText.selectAll(_:)), "a"),
            tool("Deselect All", "ui.select", ["ids": .array([])]),
        ])

        menu("Clip", [
            tool("Split at Playhead", "timeline.split", ["time": playhead, "tracks": .string("$selectedTracks")]),
            tool("Delete to Clip Start", "timeline.deleteToEdge", ["time": playhead, "side": .string("left")]),
            tool("Delete to Clip End", "timeline.deleteToEdge", ["time": playhead, "side": .string("right")]),
            .separator(),
            tool("Nudge Left One Frame", "clip.nudge", ["ids": sel, "frames": .number(-1)]),
            tool("Nudge Right One Frame", "clip.nudge", ["ids": sel, "frames": .number(1)]),
            .separator(),
            sub("Speed", [0.5, 1, 1.22, 1.5, 2].map { v in
                tool(v == 1 ? "Normal (1×)" : "\(EffectsInspectorView.format(v))×", "clip.setSpeed", ["ids": sel, "speed": .number(v)])
            }),
            tool("Extract Audio", "clip.detachAudio", ["ids": sel]),
            tool("Freeze Frame at Playhead", "clip.freezeFrame", ["time": playhead]),
        ])

        menu("Timeline", [
            tool("Add Marker", "marker.add", ["time": playhead]),
            tool("Delete Marked Range", "ui.deleteRange"),
            .separator(),
            tool("Add Overlay Track", "track.add", ["kind": .string("overlay")]),
            tool("Add Audio Track", "track.add", ["kind": .string("audio")]),
            .separator(),
            tool("Close Gaps on Main Track", "timeline.closeGaps"),
            tool("Remove Pauses on Main Track", "audio.applySilenceCuts"),
            tool("Normalise Main Track", "audio.normalize"),
            .separator(),
            tool("Record Voice-over", "audio.record", ["action": .string("toggle")]),
        ])

        menu("Playback", [
            tool("Play / Pause", "player.toggle"),
            .separator(),
            tool("Back One Frame", "player.step", ["frames": .number(-1)]),
            tool("Forward One Frame", "player.step", ["frames": .number(1)]),
            tool("Back Ten Frames", "player.step", ["frames": .number(-10)]),
            tool("Forward Ten Frames", "player.step", ["frames": .number(10)]),
            .separator(),
            tool("Start of Clip (Previous Edit)", "player.jump", ["to": .string("previousEdge")]),
            tool("End of Clip (Next Edit)", "player.jump", ["to": .string("nextEdge")]),
            tool("Go to Start", "player.jump", ["to": .string("start")]),
            tool("Go to End", "player.jump", ["to": .string("end")]),
        ])

        var view: [NSMenuItem] = [
            tool("Zoom In", "ui.zoom", ["to": .string("in")]),
            tool("Zoom Out", "ui.zoom", ["to": .string("out")]),
            tool("Zoom to Fit", "ui.zoom", ["to": .string("fit")]),
            .separator(),
        ]
        for (i, t) in MainWindowController.tabLabels.enumerated() {
            let m = item("\(t)", #selector(showTab(_:)), String(i + 1), [.command, .option])
            m.representedObject = t
            view.append(m)
        }
        view += [
            .separator(),
            item("Browser in Sidebar", #selector(browserSidebar(_:))),
            item("Browser in a Window", #selector(browserWindow(_:))),
            item("Hide Browser", #selector(browserHide(_:))),
            .separator(),
            std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
        menu("View", view)

        let windowMenu = menu("Window", [
            std("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            .separator(),
            item("Agent Notes", #selector(showNotes(_:)), "n", [.command, .option]),
            item("History", #selector(showHistory(_:))),
            item("Download from Link", #selector(showDownloads(_:))),
            .separator(),
            NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""),
        ])
        NSApp.windowsMenu = windowMenu

        let help = menu("Help", [
            item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/"),
            .separator(),
            item("Agent Guide", #selector(openAgentGuide(_:))),
            item("Copy MCP Address", #selector(copyConnection(_:))),
        ])
        NSApp.helpMenu = help
        refreshMenuKeys()
        return main
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Open Recent lists the recent projects each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for p in runtime.editor.settings.current.recentProjects where FileManager.default.fileExists(atPath: p) {
            let i = NSMenuItem(title: (p as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p
            i.toolTip = p
            menu.addItem(i)
        }
        if menu.items.isEmpty {
            let i = NSMenuItem(title: "No recent projects", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
    }
}

/// Target for a control's action inside a panel built in code.
final class PopupTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed() { action() }
}
