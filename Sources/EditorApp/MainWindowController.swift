import AppKit
import AVFoundation
import EditorCore
import EditorKit
import MediaEngine

/// The editor window: player on top, transport bar, timeline below.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let runtime: EditorRuntime
    /// The built-in browser's place in the window (B-1).
    var browser: BrowserPresenter?
    let playerView = PlayerView()
    let timeline = TimelineView()
    let inspector = InspectorView()
    let effectsPanel = EffectsInspectorView()
    let accentPanel = AccentPanel()
    let clipPanel = ClipInspectorView()
    let mediaPanel = MediaPoolPanel()
    let wordsPanel = TranscriptPanel()
    private let timeLabel = NSTextField(labelWithString: "--:--.--")
    private let statusLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private var projectWatch: Task<Void, Never>?
    private var keyMonitor: Any?
    private(set) var message: (String, Date)?
    var statusProvider: (() -> String)?

    private(set) var project: Project?
    private(set) var revision = 0

    init(runtime: EditorRuntime) {
        self.runtime = runtime
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Danial MCP Editor"
        w.minSize = NSSize(width: 720, height: 480)
        w.appearance = NSAppearance(named: .darkAqua)
        // Opens centred on the screen, sized to it, every time.
        if let screen = NSScreen.main?.visibleFrame {
            let size = NSSize(width: min(1600, screen.width * 0.88), height: min(1000, screen.height * 0.9))
            w.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        super.init(window: w)
        w.delegate = self
        layout()
        playerView.player = runtime.player.player
        playerView.onDrop = { [weak self] urls in Task { await self?.importAndAppend(urls) } }
        timeline.owner = self
        runtime.player.onRebuild = { [weak self] in
            // A new picture (or new look values): an exact still is made again.
            if let self, !self.previewShown { self.stillFor = nil }
            self?.refreshStatus()
        }
        installKeys()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func layout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        playButton.bezelStyle = .texturedRounded
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self
        playButton.action = #selector(togglePlay)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .labelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        func transport(_ symbol: String, _ tip: String, _ tool: String, _ args: [String: JSONValue]) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: #selector(transportPressed(_:)))
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            transportActions[ObjectIdentifier(b)] = (tool, args)
            return b
        }
        let bar = NSStackView(views: [
            transport("backward.end.fill", "Go to start", "player.jump", ["to": .string("start")]),
            transport("chevron.backward", "Back one frame", "player.step", ["frames": .number(-1)]),
            playButton,
            transport("chevron.forward", "Forward one frame", "player.step", ["frames": .number(1)]),
            transport("forward.end.fill", "Go to end", "player.jump", ["to": .string("end")]),
            timeLabel, NSView(), statusLabel])
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        bar.spacing = 10

        let scroll = NSScrollView()
        scroll.documentView = timeline
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.12, alpha: 1)
        timeline.scrollView = scroll

        let playerArea = NSStackView(views: [playerView, bar])
        playerArea.orientation = .vertical
        playerArea.spacing = 0
        playerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        let top = NSSplitView()
        top.isVertical = true
        top.dividerStyle = .thin
        top.addArrangedSubview(playerArea)
        // Right column: colour and effects, one tab each.
        let side = NSTabView()
        for (label, view) in zip(Self.tabLabels, [mediaPanel as NSView, clipPanel, inspector, effectsPanel, accentPanel, wordsPanel]) {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            side.addTabViewItem(item)
        }
        top.addArrangedSubview(side)
        browser = BrowserPresenter(host: runtime.browser, side: side, run: { [weak self] name, args in
            Task { await self?.runTool(name, .object(args)) }
        }, call: { [weak self] name, args in await self?.callTool(name, .object(args)) })
        side.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        inspector.owner = self
        effectsPanel.owner = self
        accentPanel.owner = self
        clipPanel.owner = self
        mediaPanel.owner = self
        wordsPanel.owner = self
        side.selectTabViewItem(at: 2)
        sideTabs = side

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(top)
        split.addArrangedSubview(scroll)
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        split.setPosition(520, ofDividerAt: 0)
    }

    // MARK: following the project

    /// Follows project open and close, then every change to the open project,
    /// whoever made it (the owner here or an agent over MCP).
    func followSessions() async {
        for await ref in await runtime.editor.sessions() {
            projectWatch?.cancel()
            await runtime.player.follow()
            guard let session = ref?.session else {
                project = nil
                timeline.setProject(nil)
                selectionChanged()
                window?.title = "Danial MCP Editor"
                refreshStatus()
                continue
            }
            // Subscribe before loading, so an edit made in between (an agent
            // that creates a project and edits it at once) is not missed.
            let changes = await session.changes()
            await load(session)
            timeline.zoomToFit()
            projectWatch = Task { [weak self] in
                for await _ in changes {
                    await self?.load(session)
                }
            }
        }
    }

    private func load(_ session: EditorSession) async {
        let (p, rev) = await (session.project, session.revision)
        project = p
        revision = rev
        window?.title = "\(p.name) — Danial MCP Editor"
        window?.representedURL = session.url
        timeline.setProject(p)
        selectionChanged()
        refreshStatus()
    }

    /// Called by the timeline when the selected clips change.
    func selectionChanged() {
        let target = inspectorTarget()
        lastPanelTarget = target
        inspector.update(project: project, selection: target)
        effectsPanel.update(project: project, selection: target)
        clipPanel.update(project: project, selection: target)
        accentPanel.update(project: project)
        mediaPanel.update(project: project)
        wordsPanel.update(project: project)
    }

    private(set) var lastPanelTarget: [EntityID] = []
    /// The right-hand tabs, in order.
    static let tabLabels = ["Media", "Clip", "Colour", "Effects", "Accent", "Words"]
    private(set) weak var sideTabs: NSTabView?

    /// Brings a right-hand tab to the front by its label.
    func showTab(_ label: String) {
        guard let tabs = sideTabs, let i = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == label }) else { return }
        tabs.selectTabViewItem(at: i)
    }
    /// Clips copied with Cmd+C, pasted with Cmd+V.
    var copiedClips: [EntityID] = []
    /// The app's own tools (ui.*), for shortcuts and the MCP server.
    private(set) lazy var uiTools: [Tool] = appTools()

    /// What the colour and effects panels act on: the selected clips, or with
    /// nothing selected the footage clip under the playhead on the topmost
    /// visible picture track, so the sliders are never dead.
    private func inspectorTarget() -> [EntityID] {
        let selected = timeline.selection.sorted()
        guard selected.isEmpty, let p = project else { return selected }
        for t in p.tracks.reversed() where t.kind != .audio && !t.hidden {
            guard let i = t.clipIndex(containing: timeline.playhead) else { continue }
            let c = t.clips[i]
            if (try? p.asset(c.asset).isHyperFrames) == true { continue }
            return [c.id]
        }
        return []
    }

    // MARK: export

    private var exportJob: String?

    /// Starts an export through the export.start tool and follows the job in
    /// the status bar.
    func startExport(path: String, preset: String, overwrite: Bool, reveal: Bool = true) async {
        guard let tool = runtime.tool("export.start") else { return }
        do {
            let r = try await tool.call(runtime.editor, arguments: .object([
                "path": .string(path), "preset": .string(preset), "overwrite": .bool(overwrite)]))
            guard let id = r["jobId"]?.stringValue else { return }
            exportJob = id
            while true {
                let info = try await runtime.jobs.info(id)
                if info.state == .running {
                    show("Export \(Int(info.progress * 100))%  \(info.message)")
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                exportJob = nil
                switch info.state {
                case .done:
                    let rendered = info.result?["rendered"]?.doubleValue ?? 0, reused = info.result?["reused"]?.doubleValue ?? 0
                    let secs = info.result?["totalSeconds"]?.doubleValue ?? 0
                    show("Exported \((path as NSString).lastPathComponent) in \(Int(secs.rounded())) s (\(Int(rendered)) segments rendered, \(Int(reused)) reused)")
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                case .cancelled: show("Export cancelled; finished segments are kept for next time")
                default: show("Export failed: \(info.error ?? "")"); NSSound.beep()
                }
                return
            }
        } catch {
            show("export: \(error)")
            NSSound.beep()
        }
    }

    func cancelExport() {
        guard let id = exportJob else { show("no export is running"); return }
        Task { try? await runtime.jobs.cancel(id) }
    }

    // MARK: running tools

    /// Runs a tool exactly as an agent would; errors show in the status bar.
    func runTool(_ name: String, _ args: JSONValue) async {
        guard let tool = runtime.tool(name) ?? uiTools.first(where: { $0.name == name }) else { show("no tool \(name)"); return }
        do {
            _ = try await tool.call(runtime.editor, arguments: args)
        } catch {
            show("\(name): \(error)")
            NSSound.beep()
        }
    }

    /// Runs a tool and returns its result; errors show in the status bar and give nil.
    func callTool(_ name: String, _ args: JSONValue) async -> JSONValue? {
        guard let tool = runtime.tool(name) ?? uiTools.first(where: { $0.name == name }) else { show("no tool \(name)"); return nil }
        do {
            return try await tool.call(runtime.editor, arguments: args)
        } catch {
            show("\(name): \(error)")
            NSSound.beep()
            return nil
        }
    }

    /// Runs a key binding: fills in the playhead and the selection first.
    func runBinding(tool: String, args: JSONValue?) {
        let b = Keymap.Binding("", tool, args)
        // While a seek from scrubbing is on its way, the playhead as shown;
        // otherwise the player's own time (it can move without the timeline,
        // for example by an agent's player.seek).
        let playhead = timeline.pendingSeek ?? runtime.player.currentTime
        var filled = runtime.keymap.current.arguments(for: b, playhead: playhead, selection: timeline.selection.sorted(),
                                                       selectedTracks: timeline.selectedTracks)
        // What only the window knows: the copied clips and every clip.
        func fill(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string("$copied"): .array(copiedClips.map { .string($0.raw) })
            case .string("$all"): .array((project?.tracks.flatMap(\.clips).map(\.id) ?? []).map { .string($0.raw) })
            case .object(let o): .object(o.mapValues(fill))
            default: v
            }
        }
        filled = fill(filled)
        // Delete with a marked range and no clips selected removes the range.
        if tool == "clip.remove", filled["ids"]?.arrayValue?.isEmpty ?? true, timeline.markedRange != nil {
            Task { await runTool("ui.deleteRange", .object([:])) }
            return
        }
        // Nothing to act on: a key that needs clips does nothing without them.
        if ["clip.remove", "clip.duplicate", "clip.nudge", "clip.copyTo", "clip.detachAudio"].contains(tool), filled["ids"]?.arrayValue?.isEmpty ?? true {
            show("select clips first")
            return
        }
        Task { await runTool(tool, filled) }
    }

    /// Imports files and puts them on the timeline, the way a person expects:
    /// footage at the end of the main track (or where it was dropped),
    /// pictures on a free overlay track and sound on a free audio track at
    /// the playhead (or where dropped). Files already in the pool are placed
    /// again. One undo step for the placing.
    func importAndAppend(_ urls: [URL], at: Time? = nil, track dropTrack: EntityID? = nil) async {
        guard let session = await runtime.editor.session else {
            show("open or create a project first")
            return
        }
        guard let r = await callTool("media.import", .object(["paths": .array(urls.map { .string($0.path) })])) else { return }
        for f in r["failed"]?.arrayValue ?? [] { show("cannot import \(f["path"]?.stringValue ?? ""): \(f["error"]?.stringValue ?? "")") }
        let p = await session.project
        var ids = (r["added"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        ids += (r["alreadyInPool"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        let assets = ids.compactMap { try? p.asset(EntityID($0)) }
        let commands = Self.placement(assets, in: p, at: at, playhead: timeline.pendingSeek ?? runtime.player.currentTime, dropTrack: dropTrack)
        if !commands.isEmpty { await runTool("batch.apply", .object(["commands": .array(commands)])) }
        if at == nil { timeline.zoomToFit() }
    }

    /// clip.add (and track.add) commands that place `assets`; pure, so the
    /// self-test can check it.
    static func placement(_ assets: [MediaAsset], in p: Project, at: Time?, playhead: Time, dropTrack: EntityID?) -> [JSONValue] {
        var commands: [JSONValue] = []
        var tracks = p.tracks
        var made = 0
        // Ranges taken by clips placed in this same drop, per track.
        var taken: [EntityID: [TimeRange]] = [:]
        func free(_ t: Track, _ r: TimeRange) -> Bool {
            !t.locked && t.overlapping(r).isEmpty && !(taken[t.id] ?? []).contains { $0.start < r.end && r.start < $0.end }
        }
        func add(_ asset: MediaAsset, track: EntityID, start: Time?) {
            var a: [String: JSONValue] = ["track": .string(track.raw), "asset": .string(asset.id.raw)]
            if let start { a["start"] = .number(start.seconds) }
            commands.append(.object(["name": .string("clip.add"), "args": .object(a)]))
        }
        var cursor = at ?? playhead
        for asset in assets where !asset.isHyperFrames {
            let length = asset.isImage ? Time(seconds: MediaAsset.stillDefaultSeconds) : asset.info.duration
            let footage = asset.info.video != nil && !asset.isImage
            let wanted: TrackKind = footage ? .main : asset.isImage ? .overlay : .audio
            let range = TimeRange(start: cursor, duration: length)
            // Dropped on a track that can hold it.
            if let d = dropTrack, let t = tracks.first(where: { $0.id == d }),
               (t.kind == .audio) == (wanted == .audio), !t.locked {
                add(asset, track: t.id, start: t.kind == .main && at == nil ? nil : cursor)
                taken[t.id, default: []].append(range)
                cursor = cursor + length
                continue
            }
            // Footage: the end of the main track, or at a given time on the
            // main track when it is free there, else on a free overlay track.
            if wanted == .main, let main = tracks.first(where: { $0.kind == .main }), at == nil || free(main, range) {
                add(asset, track: main.id, start: at.map { _ in cursor })
                if at != nil { taken[main.id, default: []].append(range); cursor = cursor + length }
                continue
            }
            let kind: TrackKind = wanted == .main ? .overlay : wanted
            if let t = tracks.first(where: { $0.kind == kind && free($0, range) }) {
                add(asset, track: t.id, start: cursor)
                taken[t.id, default: []].append(range)
            } else {
                made += 1
                let id = EntityID("track_\(kind.rawValue)_\(Int(Date().timeIntervalSince1970))_\(made)")
                let name = kind == .audio ? "Audio \(tracks.filter { $0.kind == .audio }.count + 1)" : "Overlay \(tracks.filter { $0.kind == .overlay }.count + 1)"
                commands.append(.object(["name": .string("track.add"), "args": .object(["kind": .string(kind.rawValue), "id": .string(id.raw), "name": .string(name)])]))
                tracks.append(Track(id: id, kind: kind, name: name))
                add(asset, track: id, start: cursor)
                taken[id, default: []].append(range)
            }
        }
        return commands
    }

    // MARK: keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread; only plain values cross into the actor.
            let key = Keymap.normalize(MainWindowController.keyString(event))
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, windowNumber == self.window?.windowNumber,
                      !(self.window?.firstResponder is NSText) else { return false }
                return self.handleKey(key)
            }
            return handled ? nil : event
        }
    }

    /// Runs the binding of a normalised key string; false when none.
    @discardableResult
    func handleKey(_ key: String) -> Bool {
        guard let b = runtime.keymap.current.bindings.first(where: { Keymap.normalize($0.key) == Keymap.normalize(key) }) else { return false }
        runBinding(tool: b.tool, args: b.args)
        return true
    }

    nonisolated static func keyString(_ e: NSEvent) -> String {
        var parts: [String] = []
        let f = e.modifierFlags
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("alt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        let special: [UInt16: String] = [49: "space", 123: "left", 124: "right", 125: "down", 126: "up",
                                         115: "home", 119: "end", 51: "delete", 117: "forwarddelete",
                                         36: "return", 76: "return", 53: "escape", 48: "tab", 116: "pageup", 121: "pagedown"]
        parts.append(special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").lowercased())
        return parts.joined(separator: "+")
    }

    // MARK: status

    // MARK: standard edit actions (the Edit menu, when no text field takes them)

    @objc func copy(_ sender: Any?) { runBinding(tool: "ui.copy", args: nil) }
    @objc func cut(_ sender: Any?) {
        runBinding(tool: "ui.copy", args: nil)
        runBinding(tool: "clip.remove", args: .object(["ids": .string("$selection")]))
    }
    @objc func paste(_ sender: Any?) { runBinding(tool: "clip.copyTo", args: .object(["ids": .string("$copied"), "start": .string("$playhead")])) }
    override func selectAll(_ sender: Any?) { runBinding(tool: "ui.select", args: .object(["ids": .string("$all")])) }

    private var transportActions: [ObjectIdentifier: (String, [String: JSONValue])] = [:]
    @objc private func transportPressed(_ b: NSButton) {
        guard let (tool, args) = transportActions[ObjectIdentifier(b)] else { return }
        Task { await runTool(tool, .object(args)) }
    }

    @objc private func togglePlay() { Task { await runTool("player.toggle", .object([:])) } }

    func show(_ text: String) {
        message = (text, Date())
        refreshStatus()
    }

    func refreshStatus() {
        var parts: [String] = []
        if let m = message, Date().timeIntervalSince(m.1) < 6 { parts.append(m.0) }
        if let e = runtime.player.lastError { parts.append("playback: \(e)") }
        if project != nil { parts.append("rev \(revision)") }
        if let s = statusProvider?() { parts.append(s) }
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    private func tick() {
        let p = runtime.player
        // Potential, not current, headroom: macOS raises the current one only once HDR is on screen.
        p.refreshPreviewRange(displayHDR: window?.screen.map { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 })
        let t = p.currentTime
        timeLabel.stringValue = project == nil ? "No project — File › New or Open" : "\(Self.format(t)) / \(Self.format(p.duration))"
        playButton.image = NSImage(systemSymbolName: p.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        // While a seek from scrubbing is on its way the player is behind.
        if timeline.pendingSeek == nil || p.isPlaying { timeline.playhead = t }
        if !p.isPlaying { effectsPanel.playheadMoved(t); accentPanel.playheadMoved(t) }
        wordsPanel.playheadMoved(t)
        // With nothing selected the panels follow the clip under the playhead.
        if !p.isPlaying, timeline.selection.isEmpty, inspectorTarget() != lastPanelTarget { selectionChanged() }
        updateStill(t, playing: p.isPlaying)
        if p.isPlaying { timeline.keepPlayheadVisible() }
        if let m = message, Date().timeIntervalSince(m.1) >= 6 { message = nil; refreshStatus() }
    }

    private var stillFor: Time?
    /// The time of the exact still on screen, if one is.
    private var stillShownAt: Time?
    private var stillTask: Task<Void, Never>?

    // MARK: live preview of a slider being dragged

    private var previewTask: Task<Void, Never>?
    private var previewPending: (project: Project, fast: Bool)?
    private(set) var previewShown = false

    /// Shows the frame under the playhead as `p` would draw it, without
    /// changing the project: a slider being dragged. The newest change wins
    /// and only one frame is made at a time.
    ///
    /// When only slider values of existing looks differ, they go straight
    /// into the player's look table: playback picks them up at the next
    /// frame and a paused frame is drawn again. No composition is built.
    func preview(_ p: Project) {
        var fast = false
        if var same = project, runtime.player.built != nil {
            same.looks = p.looks
            fast = same == p
        }
        if fast {
            runtime.player.previewLooks(p.looks)
            // The player draws the paused frame again with the new values;
            // a still left from a slower preview would hide it. On a frame
            // the player cannot show itself (an exact still lies over it),
            // the still is made again from the same composition instead.
            if stillFor == nil {
                previewPending = nil
                if previewShown { previewShown = false; playerView.showStill(nil) }
                return
            }
        }
        guard !runtime.player.isPlaying else { return }
        previewPending = (p, fast)
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            while let self, let next = self.previewPending {
                self.previewPending = nil
                let t = self.runtime.player.currentTime
                let width = Int(self.playerView.bounds.width * (self.window?.backingScaleFactor ?? 2))
                let built = next.fast ? self.runtime.player.built : try? await self.runtime.media.composition(for: next.project, preview: self.runtime.player.previewMode)
                if let built,
                   let image = try? await FrameCapture.timelineFrame(built, at: t, maxWidth: max(320, width)),
                   self.previewPending != nil || self.previewTask != nil {
                    self.playerView.showStill(image)
                    self.previewShown = true
                }
            }
            self?.previewTask = nil
        }
    }

    /// The drag ended and its change was applied: back to the player once
    /// it has the new picture.
    func endPreview() {
        previewPending = nil
        guard previewShown else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.previewTask == nil else { return }
            self.previewShown = false
            self.stillFor = nil
            // On a frame the player cannot show, the preview still stays
            // until the exact still is made again; elsewhere the player shows it.
            let t = self.runtime.player.currentTime
            if let b = self.runtime.player.built, b.inOrderStart(at: t) != nil || b.prerolled(at: t) != nil {
                self.stillShownAt = t
            } else {
                self.stillShownAt = nil
                self.playerView.showStill(nil)
            }
        }
    }

    /// While paused on a frame the player cannot show exactly, shows that
    /// frame decoded in order instead (FrameCapture), until play or a move.
    private func updateStill(_ t: Time, playing: Bool) {
        if playing {
            if stillFor != nil { stillFor = nil; stillShownAt = nil; stillTask?.cancel(); playerView.showStill(nil) }
            return
        }
        guard t != stillFor, !previewShown else { return }
        stillFor = t
        stillTask?.cancel()
        let exact = runtime.player.built.map { $0.inOrderStart(at: t) != nil || $0.prerolled(at: t) != nil } ?? false
        // The same frame made again (new looks) keeps its old still until the
        // new one is ready, so the player's wrong frame never flashes.
        if !exact || t != stillShownAt { playerView.showStill(nil); stillShownAt = nil }
        guard exact, let built = runtime.player.built else { return }
        let width = Int(playerView.bounds.width * (window?.backingScaleFactor ?? 2))
        stillTask = Task { [weak self] in
            let image = try? await FrameCapture.timelineFrame(built, at: t, maxWidth: width)
            guard let self, !Task.isCancelled, self.stillFor == t, !self.runtime.player.isPlaying else { return }
            self.playerView.showStill(image)
            self.stillShownAt = image == nil ? nil : t
        }
    }

    /// mm:ss.cc, with hours in front from an hour on (h:mm:ss.cc).
    static func format(_ t: Time) -> String {
        let s = max(0, t.seconds)
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = s - Double(h * 3600 + m * 60)
        return h > 0 ? String(format: "%d:%02d:%05.2f", h, m, sec) : String(format: "%02d:%05.2f", m, sec)
    }
}

/// Shows the player's picture, letterboxed: HDR on displays that have it, an
/// SDR preview on those that do not (see PlayerController.showsSDR).
final class PlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    /// A still frame shown over the player while paused where the player
    /// itself cannot show the exact frame (leading frames of open-GOP video;
    /// see DecodeStart in MediaEngine).
    private let still = CALayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        still.contentsGravity = .resizeAspect
        still.isHidden = true
        layer?.addSublayer(still)
        registerForDraggedTypes([.fileURL])
    }

    /// Files dropped on the picture: imported and placed like File › Import.
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, let onDrop else { return false }
        onDrop(urls)
        return true
    }

    func showStill(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image
        still.isHidden = image == nil
        CATransaction.commit()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        still.frame = bounds
        CATransaction.commit()
    }
}
