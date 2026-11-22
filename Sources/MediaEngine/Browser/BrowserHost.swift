import AppKit
import EditorCore
import EditorKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// The built-in browser (B-1 to B-6, architecture section 13).
///
/// One web view at a time, in a profile whose website data store persists,
/// so sign-ins survive restarts. The app shows this same view in its
/// sidebar or a window, so the owner sees every step (B-4); without the app
/// it lives in an offscreen window. Agents act on the page through element
/// references from `read`. Sign-in is the owner's: the host never types into
/// a password field (B-6).
@MainActor
public final class BrowserHost: NSObject {
    public enum Layout: String, Sendable, CaseIterable { case hidden, sidebar, window }

    public struct Download: Sendable {
        public var name: String
        public var file: URL?
        public var done: Bool
        public var error: String?
    }

    let settings: UserSettingsStore
    public private(set) var webView: WKWebView?
    public private(set) var profile: String?
    public private(set) var layout: Layout = .hidden
    public private(set) var downloads: [Download] = []
    /// The last alert or confirmation the page raised (answered automatically).
    public private(set) var lastDialog: String?
    /// Called when the view, profile or layout changes, so the app can show it.
    public var onChange: (() -> Void)?
    private var offscreen: NSWindow?
    private var pendingFiles: [URL]?
    private var chooserOpened = false
    private let cacheDownloads: URL
    var downloadFolder: URL {
        let f = settings.current.browser.downloadFolder
        return f.isEmpty ? cacheDownloads : URL(fileURLWithPath: (f as NSString).expandingTildeInPath, isDirectory: true)
    }

    public init(settings: UserSettingsStore) {
        self.settings = settings
        cacheDownloads = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor/browser/downloads", isDirectory: true)
        super.init()
    }

    // MARK: profiles and sessions

    /// The persistent data store of a profile, made on first use.
    func store(_ name: String) throws -> WKWebsiteDataStore {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.count <= 40 else { throw EditorError.invalid("a profile name is 1 to 40 characters", parameter: "profile") }
        if let raw = settings.current.browser.profiles[clean], let id = UUID(uuidString: raw) {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        let id = UUID()
        try settings.update { $0.browser.profiles[clean] = id.uuidString }
        return WKWebsiteDataStore(forIdentifier: id)
    }

    public var profiles: [String] { settings.current.browser.profiles.keys.sorted() }

    /// Shows the browser (or keeps it hidden) in a profile; a new profile or
    /// no page yet starts a session.
    public func open(profile name: String?, layout: Layout?, url: URL?) async throws {
        let want = name ?? profile ?? settings.current.browser.defaultProfile
        if webView == nil || want != profile { try makeView(want) }
        if let layout { self.layout = layout }
        onChange?()
        if let url { try await navigate(url) } else if webView?.url == nil, let home = URL(string: settings.current.browser.homePage) { try await navigate(home) }
    }

    public func close() {
        layout = .hidden
        onChange?()
    }

    /// A fresh page in the same profile: same sign-ins, nothing else kept (B-3).
    public func newSession(url: URL?) async throws {
        try makeView(profile ?? settings.current.browser.defaultProfile)
        onChange?()
        if let target = url ?? URL(string: settings.current.browser.homePage) { try await navigate(target) }
    }

    private func makeView(_ name: String) throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = try store(name)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let b = settings.current.browser
        let old = webView
        let view = WKWebView(frame: old?.frame ?? NSRect(x: 0, y: 0, width: b.width, height: b.height), configuration: config)
        view.customUserAgent = b.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        if let parent = old?.superview {
            view.autoresizingMask = old?.autoresizingMask ?? [.width, .height]
            parent.replaceSubview(old!, with: view)
        } else {
            park(view)
        }
        webView = view
        profile = name
    }

    /// Puts the view in the offscreen window, where it still renders.
    public func park(_ view: WKWebView? = nil) {
        guard let v = view ?? webView else { return }
        if offscreen == nil {
            let b = settings.current.browser
            let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: b.width, height: b.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            offscreen = w
        }
        v.removeFromSuperview()
        v.frame = offscreen!.contentView!.bounds
        v.autoresizingMask = [.width, .height]
        offscreen!.contentView!.addSubview(v)
    }

    func requireView() throws -> WKWebView {
        guard let v = webView else { throw EditorError.invalid("the browser is not open; call browser.open first") }
        return v
    }

    // MARK: navigation

    public func navigate(_ url: URL) async throws {
        let v = try requireView()
        guard ["http", "https", "about", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw EditorError.invalid("only http, https, file and about addresses open", parameter: "url")
        }
        if url.isFileURL { v.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { v.load(URLRequest(url: url)) }
        try await settle(v)
    }

    public func go(_ where_: String) async throws {
        let v = try requireView()
        switch where_ {
        case "back": guard v.canGoBack else { throw EditorError.invalid("there is no page to go back to") }; v.goBack()
        case "forward": guard v.canGoForward else { throw EditorError.invalid("there is no page to go forward to") }; v.goForward()
        default: v.reload()
        }
        try await settle(v)
    }

    /// Waits until the page stops loading, at most `timeout` seconds.
    func settle(_ v: WKWebView, timeout: Double = 30) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        let end = Date().addingTimeInterval(timeout)
        while v.isLoading, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    // MARK: page scripts

    /// Runs a function body in the page's isolated script world.
    func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        let v = try requireView()
        do {
            return try await v.callAsyncJavaScript(Self.helpers + body, arguments: args, in: nil, contentWorld: .defaultClient)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw EditorError(.invalid, message)
        }
    }

    /// Shared helpers: every element, through shadow roots, and lookup by reference.
    static let helpers = """
    const __all = (root, sel, out = []) => {
      for (const el of root.querySelectorAll(sel)) out.push(el);
      for (const el of root.querySelectorAll('*')) if (el.shadowRoot) __all(el.shadowRoot, sel, out);
      return out;
    };
    const __find = (ref) => {
      const el = __all(document, '[data-dme-ref="' + ref + '"]')[0];
      if (!el) throw new Error('no element ' + ref + ' on the page; read the page again');
      return el;
    };

    """

    /// The page as a list of elements with references (B-2).
    public func read(limit: Int = 300, textLimit: Int = 4000) async throws -> JSONValue {
        let r = try await js("""
        const sel = 'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=textbox],[role^=menuitem],[role=treeitem],[role=gridcell],[role=searchbox],[role=spinbutton],[role=listbox],[role=option],[role=tab],[role=checkbox],[role=radio],[role=combobox],[role=switch],[role=slider],[contenteditable=""],[contenteditable=true],[tabindex]:not([tabindex="-1"]),img';
        let next = Number(document.documentElement.dataset.dmeNext || 1);
        const out = [];
        for (const el of __all(document, sel)) {
          const r = el.getBoundingClientRect(), s = getComputedStyle(el);
          const fileInput = el.tagName === 'INPUT' && el.type === 'file';
          if (!fileInput && (r.width < 2 || r.height < 2 || s.visibility === 'hidden' || s.display === 'none' || Number(s.opacity) < 0.02)) continue;
          if (el.tagName === 'IMG' && Math.min(el.naturalWidth, el.naturalHeight) < 64) continue;
          if (!el.dataset.dmeRef) el.dataset.dmeRef = 'e' + (next++);
          const role = el.getAttribute('role') || (el.tagName === 'INPUT' ? 'input:' + (el.type || 'text') : el.isContentEditable ? 'textbox' : el.tagName.toLowerCase());
          const name = (el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.placeholder || (el.tagName === 'IMG' ? '' : el.innerText) || '').trim().replace(/\\s+/g, ' ').slice(0, 120);
          const o = { ref: el.dataset.dmeRef, role, name, box: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)] };
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') o.disabled = true;
          if (el.getAttribute('aria-checked') || el.getAttribute('aria-selected') || el.checked) o.checked = el.checked || el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-selected') === 'true';
          if ((el.tagName === 'INPUT' && !['password', 'file'].includes(el.type)) || el.tagName === 'TEXTAREA') o.value = String(el.value).slice(0, 200);
          if (el.isContentEditable) o.value = el.innerText.slice(0, 200);
          if (el.tagName === 'IMG') { o.src = (el.currentSrc || el.src).slice(0, 160); o.size = [el.naturalWidth, el.naturalHeight]; }
          if (el.tagName === 'SELECT') o.options = [...el.options].map(x => x.text).slice(0, 40);
          out.push(o);
        }
        document.documentElement.dataset.dmeNext = next;
        return { url: location.href, title: document.title, viewport: [innerWidth, innerHeight],
                 scroll: [Math.round(scrollX), Math.round(scrollY), document.documentElement.scrollHeight],
                 elements: out.slice(0, limit), more: Math.max(0, out.length - limit),
                 text: document.body ? document.body.innerText.slice(0, textLimit) : '' };
        """, ["limit": limit, "textLimit": textLimit])
        var v = try JSONValue(any: r)
        if case .object(var o) = v {
            if let d = lastDialog { o["lastDialog"] = .string(d) }
            o["profile"] = profile.map { .string($0) } ?? .null
            v = .object(o)
        }
        return v
    }

    /// The markup of an element (or the body), shortened, with form values left out.
    public func html(_ ref: String?, limit: Int) async throws -> String {
        try await js("""
        const el = ref ? __find(ref) : document.body;
        const copy = el.cloneNode(true);
        for (const i of copy.querySelectorAll ? copy.querySelectorAll('input') : []) i.removeAttribute('value');
        return copy.outerHTML.replace(/<(svg|path|style|script)[\\s\\S]*?<\\/\\1>/g, '<$1/>').slice(0, limit);
        """, ["ref": ref ?? NSNull(), "limit": limit]) as? String ?? ""
    }

    /// Kind of an element, and its centre in page pixels after scrolling it into view.
    func locate(_ ref: String) async throws -> (kind: String, x: Double, y: Double) {
        let r = try await js("""
        const el = __find(ref);
        el.scrollIntoView({ block: 'center', inline: 'center' });
        const b = el.getBoundingClientRect();
        const kind = el.tagName === 'INPUT' ? 'input:' + (el.type || 'text') : el.isContentEditable ? 'editable' : el.tagName.toLowerCase();
        return [kind, b.x + b.width / 2, b.y + b.height / 2];
        """, ["ref": ref]) as? [Any]
        guard let r, r.count == 3, let kind = r[0] as? String, let x = r[1] as? Double, let y = r[2] as? Double else {
            throw EditorError(.notFound, "element \(ref) cannot be found")
        }
        return (kind, x, y)
    }

    /// Clicks an element. `trusted` sends a real mouse click to the view
    /// (for pages that ignore script clicks); otherwise the page gets the
    /// pointer and click events from script.
    public func click(_ ref: String, trusted: Bool = false) async throws {
        let target = try await locate(ref)
        if trusted {
            let v = try requireView()
            guard let window = v.window else { throw EditorError.invalid("a real click needs the view in a window") }
            let p = NSPoint(x: target.x * v.pageZoom, y: v.isFlipped ? target.y * v.pageZoom : v.bounds.height - target.y * v.pageZoom)
            let at = v.convert(p, to: nil)
            window.makeFirstResponder(v)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
            }
        } else {
            _ = try await js("""
            const el = __find(ref);
            const b = el.getBoundingClientRect(), x = b.x + b.width / 2, y = b.y + b.height / 2;
            const o = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0 };
            el.dispatchEvent(new PointerEvent('pointerdown', o)); el.dispatchEvent(new MouseEvent('mousedown', o));
            if (el.focus) el.focus();
            el.dispatchEvent(new PointerEvent('pointerup', o)); el.dispatchEvent(new MouseEvent('mouseup', o));
            el.click();
            """, ["ref": ref])
        }
        try await settle(try requireView(), timeout: 10)
    }

    /// Types into a field or editable area (replacing what is there unless
    /// `append`), then presses Return when `submit`. Never into a password
    /// field. With `keys` the text is typed as real key presses, for pages
    /// that only accept what a person types.
    public func type(_ ref: String, text: String, append: Bool = false, submit: Bool = false, keys: Bool = false) async throws {
        let target = try await locate(ref)
        guard target.kind != "input:password" else {
            throw EditorError.invalid("passwords are typed by the owner, never by an agent (B-6); ask the owner to sign in", parameter: "ref")
        }
        if keys {
            try await click(ref, trusted: true)
            if !append {
                _ = try await js("""
                const el = __find(ref);
                if (el.isContentEditable) { const r = document.createRange(); r.selectNodeContents(el); getSelection().removeAllRanges(); getSelection().addRange(r); }
                else if (el.select) el.select();
                """, ["ref": ref])
            }
            try await typeKeys(text)
            if submit { try await press("return") }
            return
        }
        _ = try await js("""
        const el = __find(ref);
        el.focus();
        if (el.isContentEditable) {
          const sel = getSelection(), range = document.createRange();
          range.selectNodeContents(el);
          if (append) range.collapse(false);
          sel.removeAllRanges(); sel.addRange(range);
          if (!document.execCommand('insertText', false, text)) {
            el.innerText = append ? el.innerText + text : text;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data: text, inputType: 'insertText' }));
          }
        } else if ('value' in el) {
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const set = Object.getOwnPropertyDescriptor(proto, 'value').set;
          set.call(el, append ? el.value + text : text);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data: text, inputType: 'insertText' }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else {
          throw new Error('element ' + ref + ' takes no text');
        }
        """, ["ref": ref, "text": text, "append": append])
        if submit { try await press("return") }
    }

    /// Real key presses for each character, in the focused element.
    func typeKeys(_ text: String) async throws {
        let v = try requireView()
        guard let window = v.window else { throw EditorError.invalid("keys need the view in a window") }
        window.makeFirstResponder(v)
        for ch in text {
            let s = String(ch)
            let (chars, code): (String, UInt16) = s == "\n" ? ("\r", 36) : (s, 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { v.keyDown(with: e) } else { v.keyUp(with: e) }
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Presses a key in the view: return, escape or tab.
    public func press(_ key: String) async throws {
        let v = try requireView()
        guard let window = v.window else { throw EditorError.invalid("keys need the view in a window") }
        let (chars, code): (String, UInt16) = switch key {
        case "escape": ("\u{1B}", 53)
        case "tab": ("\t", 48)
        default: ("\r", 36)
        }
        window.makeFirstResponder(v)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { v.keyDown(with: e) } else { v.keyUp(with: e) }
        }
        try await settle(v, timeout: 10)
    }

    public func select(_ ref: String, option: String) async throws {
        _ = try await js("""
        const el = __find(ref);
        if (el.tagName !== 'SELECT') throw new Error('element ' + ref + ' is not a list; click it and pick the option instead');
        const o = [...el.options].find(x => x.text.trim() === option || x.value === option);
        if (!o) throw new Error('no option "' + option + '"; options: ' + [...el.options].map(x => x.text.trim()).join(', '));
        el.value = o.value;
        el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
        """, ["ref": ref, "option": option])
    }

    /// Gives files to an upload field directly. For any other element:
    /// with `drop`, drops them on it; otherwise clicks it for real and the
    /// file chooser it opens gets these files.
    public func attach(_ ref: String, files: [URL], drop: Bool = false) async throws {
        guard !files.isEmpty else { throw EditorError.invalid("give at least one file", parameter: "files") }
        for f in files where !FileManager.default.isReadableFile(atPath: f.path) { throw EditorError(.notFound, "cannot read \(f.path)") }
        let target = try await locate(ref)
        if target.kind != "input:file", !drop {
            pendingFiles = files
            chooserOpened = false
            try await click(ref, trusted: true)
            let end = Date().addingTimeInterval(5)
            while !chooserOpened, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
            guard chooserOpened else {
                pendingFiles = nil
                throw EditorError(.conflict, "element \(ref) opened no file chooser; give the upload field itself, or drop: true for a drop area")
            }
            try await settle(try requireView(), timeout: 10)
            return
        }
        var list: [[String: String]] = []
        for f in files {
            guard let d = FileManager.default.contents(atPath: f.path) else { throw EditorError(.notFound, "cannot read \(f.path)") }
            guard d.count <= 60_000_000 else { throw EditorError.invalid("\(f.lastPathComponent) is larger than 60 MB", parameter: "files") }
            let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            list.append(["name": f.lastPathComponent, "type": mime, "data": d.base64EncodedString()])
        }
        _ = try await js("""
        const el = __find(ref);
        const dt = new DataTransfer();
        for (const f of files) {
          const bin = atob(f.data), bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          dt.items.add(new File([bytes], f.name, { type: f.type }));
        }
        if (el.tagName === 'INPUT' && el.type === 'file') {
          el.files = dt.files;
          el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
          return;
        }
        const b = el.getBoundingClientRect(), o = { bubbles: true, cancelable: true, composed: true, dataTransfer: dt, clientX: b.x + b.width / 2, clientY: b.y + b.height / 2 };
        el.dispatchEvent(new DragEvent('dragenter', o)); el.dispatchEvent(new DragEvent('dragover', o)); el.dispatchEvent(new DragEvent('drop', o));
        """, ["ref": ref, "files": list])
        try await settle(try requireView(), timeout: 10)
    }

    /// Waits for text to appear, an element to appear or go, or a download
    /// to finish. Returns how long it took.
    public func waitFor(text: String?, ref: String?, gone: Bool, download: Bool, timeout: Double) async throws -> Double {
        let t0 = Date()
        let before = downloads.filter(\.done).count
        while Date().timeIntervalSince(t0) < timeout {
            if download, downloads.filter(\.done).count > before { return Date().timeIntervalSince(t0) }
            if text != nil || ref != nil {
                let found = try await js("""
                if (ref) return __all(document, '[data-dme-ref="' + ref + '"]').length > 0;
                return (document.body ? document.body.innerText : '').includes(text);
                """, ["ref": ref ?? NSNull(), "text": text ?? ""]) as? Bool ?? false
                if found != gone { return Date().timeIntervalSince(t0) }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw EditorError(.conflict, "waited \(Int(timeout)) s and the condition did not come true; read the page to see where it stands")
    }

    /// An image of the visible page, or of one element.
    public func capture(_ ref: String?) async throws -> CGImage {
        let v = try requireView()
        let config = WKSnapshotConfiguration()
        if let ref {
            let r = try await js("""
            const el = __find(ref); el.scrollIntoView({ block: 'center', inline: 'center' });
            const b = el.getBoundingClientRect(); return [b.x, b.y, b.width, b.height];
            """, ["ref": ref]) as? [Double]
            guard let r, r.count == 4 else { throw EditorError(.notFound, "element \(ref) cannot be found") }
            let z = v.pageZoom
            config.rect = CGRect(x: r[0] * z, y: r[1] * z, width: r[2] * z, height: r[3] * z)
        }
        let image = try await v.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw EditorError(.io, "the page could not be captured") }
        return cg
    }

    /// Generated images on the page (large ones) and finished downloads.
    public func results() async throws -> JSONValue {
        let minSize = settings.current.browser.resultMinSize
        let r = try await js("""
        let next = Number(document.documentElement.dataset.dmeNext || 1);
        const out = [];
        for (const el of __all(document, 'img')) {
          if (!el.complete || Math.min(el.naturalWidth, el.naturalHeight) < minSize) continue;
          if (!el.dataset.dmeRef) el.dataset.dmeRef = 'e' + (next++);
          out.push({ ref: el.dataset.dmeRef, src: (el.currentSrc || el.src).slice(0, 160), size: [el.naturalWidth, el.naturalHeight], alt: el.alt || '' });
        }
        document.documentElement.dataset.dmeNext = next;
        return out;
        """, ["minSize": minSize])
        let dl: [JSONValue] = downloads.map { d in
            .object(["name": .string(d.name), "done": .bool(d.done), "file": d.file.map { .string($0.path) } ?? .null,
                     "error": d.error.map { .string($0) } ?? .null])
        }
        // An empty list can come back from the page as nothing at all. Not
        // "images": the MCP layer turns that key into pictures for the model.
        let images = try JSONValue(any: r)
        return .object(["pageImages": images == .null ? .array([]) : images, "downloads": .array(dl)])
    }

    /// The bytes of a result: an image on the page (by reference) or a download (by name).
    public func resultData(ref: String?, download: String?) async throws -> (data: Data, suggested: String) {
        if let download {
            guard let d = downloads.last(where: { $0.name == download && $0.done }), let f = d.file, let data = FileManager.default.contents(atPath: f.path) else {
                throw EditorError(.notFound, "no finished download \(download); see browser.listResults")
            }
            return (data, d.name)
        }
        guard let ref else { throw EditorError.invalid("give ref (an image) or download (a name)") }
        let r = try await js("""
        const el = __find(ref);
        const src = el.currentSrc || el.src;
        if (!src) throw new Error('element ' + ref + ' has no image');
        try {
          const res = await fetch(src, { credentials: 'include' });
          const buf = new Uint8Array(await res.arrayBuffer());
          let s = ''; for (let i = 0; i < buf.length; i += 32768) s += String.fromCharCode.apply(null, buf.subarray(i, i + 32768));
          return { data: btoa(s), src };
        } catch (e) {
          return { data: null, src };
        }
        """, ["ref": ref]) as? [String: Any]
        let src = r?["src"] as? String ?? ""
        if let b64 = r?["data"] as? String, let data = Data(base64Encoded: b64), !data.isEmpty {
            return (data, URL(string: src)?.lastPathComponent ?? "result")
        }
        // Another site's image the page may show but not read: download it
        // with the profile's cookies.
        guard let url = URL(string: src), ["http", "https"].contains(url.scheme ?? "") else {
            throw EditorError(.io, "the image \(ref) cannot be read")
        }
        let file = try await fetchWithProfile(url)
        guard let data = FileManager.default.contents(atPath: file.path) else { throw EditorError(.io, "the download of \(ref) is empty") }
        return (data, url.lastPathComponent)
    }

    private var waiting: [ObjectIdentifier: CheckedContinuation<URL, Error>] = [:]

    func fetchWithProfile(_ url: URL) async throws -> URL {
        let v = try requireView()
        let download = await v.startDownload(using: URLRequest(url: url))
        download.delegate = self
        return try await withCheckedThrowingContinuation { c in waiting[ObjectIdentifier(download)] = c }
    }
}

// MARK: delegates

extension BrowserHost: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// A link that opens a new window opens here instead.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        lastDialog = "alert: \(message)"
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        lastDialog = "confirm (answered no): \(message)"
        return false
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        defer { pendingFiles = nil }
        if let files = pendingFiles {
            chooserOpened = true
            return files
        }
        // The owner clicked an upload button: an ordinary open panel.
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return await panel.begin() == .OK ? panel.urls : nil
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        try? FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var url = downloadFolder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloadFolder.appendingPathComponent("\((name as NSString).deletingPathExtension)-\(n).\((name as NSString).pathExtension)")
            n += 1
        }
        if waiting[ObjectIdentifier(download)] == nil { downloads.append(Download(name: url.lastPathComponent, file: url, done: false)) }
        objc_setAssociatedObject(download, &Self.destinationKey, url, .OBJC_ASSOCIATION_RETAIN)
        return url
    }

    nonisolated(unsafe) static var destinationKey: UInt8 = 0

    public func downloadDidFinish(_ download: WKDownload) {
        let url = objc_getAssociatedObject(download, &Self.destinationKey) as? URL
        if let c = waiting.removeValue(forKey: ObjectIdentifier(download)) {
            if let url { c.resume(returning: url) } else { c.resume(throwing: EditorError(.io, "download without a file")) }
            return
        }
        if let i = downloads.lastIndex(where: { $0.file == url }) { downloads[i].done = true }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let c = waiting.removeValue(forKey: ObjectIdentifier(download)) { c.resume(throwing: error); return }
        let url = objc_getAssociatedObject(download, &Self.destinationKey) as? URL
        if let i = downloads.lastIndex(where: { $0.file == url }) { downloads[i].error = error.localizedDescription; downloads[i].done = false }
    }
}

extension JSONValue {
    /// From what a page script returns (Foundation objects).
    init(any value: Any?) throws {
        guard let value, !(value is NSNull) else { self = .null; return }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
