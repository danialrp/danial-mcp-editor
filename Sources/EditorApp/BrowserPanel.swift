import AppKit
import EditorKit
import MediaEngine
import WebKit

/// The built-in browser as the owner sees it (B-1, B-4): an address bar and
/// the very web view agents drive, shown in the sidebar or in its own
/// window. The owner signs in here; every button goes through a tool.
@MainActor
final class BrowserPanel: NSView, NSTextFieldDelegate {
    let host: BrowserHost
    let run: (String, [String: JSONValue]) -> Void
    /// Runs a tool and hands back its result (nil on error, shown in the status bar).
    var call: ((String, [String: JSONValue]) async -> JSONValue?)?
    private let address = NSTextField()
    private let profileMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let page = NSView()
    private var targets: [PopupTarget] = []
    private var watch: NSKeyValueObservation?
    private weak var watched: WKWebView?

    init(host: BrowserHost, run: @escaping (String, [String: JSONValue]) -> Void) {
        self.host = host
        self.run = run
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
            let t = PopupTarget(action)
            targets.append(t)
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: t, action: #selector(PopupTarget.changed))
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        address.placeholderString = "Address"
        address.delegate = self
        address.lineBreakMode = .byTruncatingTail
        let profileTarget = PopupTarget { [weak self] in
            guard let self, let name = self.profileMenu.titleOfSelectedItem else { return }
            if name == "New Profile…" { self.newProfile() } else { self.run("browser.open", ["profile": .string(name)]) }
        }
        targets.append(profileTarget)
        profileMenu.target = profileTarget
        profileMenu.action = #selector(PopupTarget.changed)
        let bar = NSStackView(views: [
            button("chevron.left", "Back") { [weak self] in self?.run("browser.navigate", ["url": .string("back")]) },
            button("chevron.right", "Forward") { [weak self] in self?.run("browser.navigate", ["url": .string("forward")]) },
            button("arrow.clockwise", "Reload") { [weak self] in self?.run("browser.navigate", ["url": .string("reload")]) },
            address, profileMenu,
            button("plus.square.on.square", "New session") { [weak self] in self?.run("browser.newSession", [:]) },
            button("square.and.arrow.down", "Save an image or download from this page into the project") { [weak self] in self?.chooseResult() },
            button("macwindow", "Own window / sidebar") { [weak self] in
                guard let self else { return }
                self.run("browser.open", ["layout": .string(self.host.layout == .window ? "sidebar" : "window")])
            },
        ])
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [bar, page])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            page.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the host's current web view into this panel.
    func adopt() {
        guard let v = host.webView else { return }
        if v.superview !== page {
            v.removeFromSuperview()
            v.frame = page.bounds
            v.autoresizingMask = [.width, .height]
            page.addSubview(v)
        }
        // A new session replaces the view in place: follow the current one.
        if watched !== v {
            watched = v
            watch = v.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.address.stringValue = wv.url?.absoluteString ?? "" }
            }
        }
        profileMenu.removeAllItems()
        profileMenu.addItems(withTitles: host.profiles + ["New Profile…"])
        if let p = host.profile { profileMenu.selectItem(withTitle: p) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement else { return }
        let text = address.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { run("browser.navigate", ["url": .string(text)]) }
    }

    /// Lists the page's large images and finished downloads; the one picked
    /// is saved into the project and added to the media pool.
    func chooseResult() {
        Task {
            guard let r = await call?("browser.listResults", [:]) else { return }
            let menu = NSMenu()
            func add(_ title: String, _ args: [String: JSONValue]) {
                let i = NSMenuItem(title: title, action: #selector(pickResult(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = ResultArgs(args)
                menu.addItem(i)
            }
            for d in r["downloads"]?.arrayValue ?? [] where d["done"]?.boolValue == true {
                guard let name = d["name"]?.stringValue else { continue }
                add("Download: \(name)", ["download": .string(name)])
            }
            for img in r["pageImages"]?.arrayValue ?? [] {
                guard let ref = img["ref"]?.stringValue else { continue }
                let size = img["size"]?.arrayValue?.compactMap(\.doubleValue).map { String(Int($0)) }.joined(separator: "×") ?? ""
                let alt = img["alt"]?.stringValue ?? ""
                add("Image \(size)\(alt.isEmpty ? "" : "  \(alt.prefix(40))")", ["ref": .string(ref)])
            }
            if menu.items.isEmpty {
                let i = NSMenuItem(title: "No large images or finished downloads on this page", action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - 40, y: bounds.maxY - 30), in: self)
        }
    }

    @objc private func pickResult(_ i: NSMenuItem) {
        guard let a = (i.representedObject as? ResultArgs)?.args else { return }
        run("browser.saveResult", a.merging(["addToPool": .bool(true)]) { x, _ in x })
    }

    private func newProfile() {
        let alert = NSAlert()
        alert.messageText = "New browser profile"
        alert.informativeText = "A profile keeps its own sign-ins."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            run("browser.open", ["profile": .string(field.stringValue)])
        } else if let p = host.profile {
            profileMenu.selectItem(withTitle: p)
        }
    }
}

/// Places the browser panel where the host's layout says.
@MainActor
final class BrowserPresenter {
    let host: BrowserHost
    let panel: BrowserPanel
    let side: NSTabView
    private var window: NSWindow?
    private let tabID = "Browser"

    init(host: BrowserHost, side: NSTabView, run: @escaping (String, [String: JSONValue]) -> Void,
         call: @escaping (String, [String: JSONValue]) async -> JSONValue?) {
        self.host = host
        self.side = side
        panel = BrowserPanel(host: host, run: run)
        panel.call = call
        host.onChange = { [weak self] in self?.update() }
    }

    func update() {
        let tab = side.tabViewItems.first { ($0.identifier as? String) == tabID }
        switch host.layout {
        case .hidden:
            window?.orderOut(nil)
            if let tab { side.removeTabViewItem(tab) }
            host.park()
        case .sidebar:
            window?.orderOut(nil)
            let item = tab ?? {
                let i = NSTabViewItem(identifier: tabID)
                i.label = tabID
                side.addTabViewItem(i)
                return i
            }()
            item.view = panel
            panel.adopt()
            side.selectTabViewItem(item)
        case .window:
            if let tab { side.removeTabViewItem(tab) }
            let w = window ?? {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
                w.title = "Browser"
                w.isReleasedWhenClosed = false
                w.setFrameAutosaveName("DanialMCPEditor.Browser")
                w.center()
                return w
            }()
            if window == nil {
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.host.layout == .window { self?.panel.run("browser.close", [:]) } }
                }
            }
            window = w
            w.contentView = panel
            panel.adopt()
            w.makeKeyAndOrderFront(nil)
        }
    }
}

/// Arguments carried by a menu item.
private final class ResultArgs: NSObject {
    let args: [String: JSONValue]
    init(_ a: [String: JSONValue]) { args = a }
}
