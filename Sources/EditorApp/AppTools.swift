import AppKit
import EditorCore
import EditorKit
import MediaEngine

/// Tools only the app has, for what the owner sees: the timeline's
/// selection and zoom, and a self-test that works the real window with
/// mouse and key events the way a person does (useful when nobody can
/// watch the screen).
extension MainWindowController {
    func appTools() -> [Tool] {
        let w = AppBox(value: self)
        return [
            Tool("ui.state", .read, "What the app window shows: the open project, the timeline's selection, playhead and zoom, which side panel is open, and what the colour and effects panels act on.") { _, _ in
                await MainActor.run { w.value.uiState() }
            },
            Tool("ui.select", .manage, "Select clips on the timeline, as the owner would by clicking (an empty list clears). The colour and effects panels then act on them.", [
                Parameter("ids", .array(.id), "Clip ids", required: true),
            ]) { _, args in
                let ids = (try args.strings("ids") ?? []).map { EntityID($0) }
                return await MainActor.run { w.value.timeline.select(ids); return w.value.uiState() }
            },
            Tool("ui.zoom", .manage, "Zoom the timeline: fit the whole timeline, in or out, or to a number of pixels per second.", [
                Parameter("to", .oneOf(["fit", "in", "out"]), "fit, in or out"),
                Parameter("pixelsPerSecond", .number, "Exact zoom"),
            ]) { _, args in
                let to = try args.string("to"), pps = try args.double("pixelsPerSecond")
                return await MainActor.run {
                    let t = w.value.timeline
                    if let pps { t.pixelsPerSecond = CGFloat(pps) }
                    switch to {
                    case "fit": t.zoomToFit()
                    case "in": t.zoom(by: 1.5)
                    case "out": t.zoom(by: 1 / 1.5)
                    default: break
                    }
                    return w.value.uiState()
                }
            },
            Tool("ui.copy", .manage, "Copy the selected clips (Cmd+C), or the given ones, for a paste at the playhead (Cmd+V runs clip.copyTo).", [
                Parameter("ids", .array(.id), "Clip ids; default the selection"),
            ]) { _, args in
                let ids = (try args.strings("ids")).map { $0.map { EntityID($0) } }
                return await MainActor.run {
                    w.value.copiedClips = ids ?? w.value.timeline.selection.sorted()
                    return .object(["copied": .array(w.value.copiedClips.map { .string($0.raw) })])
                }
            },
            Tool("ui.deleteRange", .write, "Delete the range marked on the timeline (⌥-drag on the ruler) from every unlocked track, closing the gap; or the given range.", [
                Parameter("start", .seconds, "Range start; default the marked range"),
                Parameter("end", .seconds, "Range end; default the marked range"),
            ]) { _, args in
                let given = (try args.time("start"), try args.time("end"))
                return try await MainActor.run {
                    let tl = w.value.timeline
                    guard let s = given.0 ?? tl.markedRange?.start, let e = given.1 ?? tl.markedRange?.end, e > s else {
                        throw EditorError.invalid("no range is marked; ⌥-drag on the ruler, or give start and end")
                    }
                    tl.markedRange = nil
                    Task { await w.value.runTool("timeline.deleteRange", .object(["start": .number(s.seconds), "end": .number(e.seconds), "allTracks": .bool(true)])) }
                    return .object(["start": .number(s.seconds), "end": .number(e.seconds)])
                }
            },
            Tool("ui.key", .manage, "Press a shortcut in the app as the owner would (for example cmd+b, q, w, space, home, end, up, down); it acts on the timeline's selection and playhead.", [
                Parameter("key", .string, "Key with modifiers, for example cmd+shift+z", required: true),
            ]) { _, args in
                let k = try args.requiredString("key")
                let handled = await MainActor.run { w.value.handleKey(k) }
                guard handled else { throw EditorError.invalid("no shortcut \(k); see keymap.get", parameter: "key") }
                try await Task.sleep(nanoseconds: 300_000_000)
                return await MainActor.run { w.value.uiState() }
            },
            Tool("ui.selfTest", .manage, "Work the app window like a person, on a scratch project made from the given video: clicks, drags and trims on the timeline, snapping, scrubbing, every shortcut (play, steps, jumps, split, delete to edge, delete, undo, redo), the colour, effect and transform sliders and the Accent panel. Reports each check. The open project is closed first and opened again at the end.", [
                Parameter("media", .string, "A video file to build the scratch project from", required: true),
                Parameter("downloadURL", .string, "Also test File › Download from Link with this post (needs the network): download, look at it, add it, move it to the Trash"),
            ]) { _, args in
                let path = (try args.requiredString("media") as NSString).expandingTildeInPath
                let link = try args.string("downloadURL")
                return await w.value.selfTest(media: path, downloadURL: link)
            },
        ]
    }

    func uiState() -> JSONValue {
        let t = timeline
        let side = (window?.contentView?.firstSubview(of: NSTabView.self))?.selectedTabViewItem?.label
        return .object([
            "project": project.map { .string($0.name) } ?? .null,
            "selection": .array(t.selection.sorted().map { .string($0.raw) }),
            "playhead": .number(t.playhead.seconds),
            "pixelsPerSecond": .number(Double(t.pixelsPerSecond)),
            "panel": side.map { .string($0) } ?? .null,
            "panelsActOn": .array(lastPanelTarget.map { .string($0.raw) }),
        ])
    }

    // MARK: self-test

    private func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        guard let tool = runtime.tool(name) else { throw EditorError(.notFound, "no tool \(name)") }
        return try await tool.call(runtime.editor, arguments: .object(args))
    }

    private func currentProject() async -> Project? { await runtime.editor.session?.project }

    /// Waits until `ok` holds (the window follows the session a moment later).
    private func until(_ seconds: Double = 3, _ ok: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if await ok() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        return await ok()
    }

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: timeline.convert(p, to: nil), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ a: NSPoint, _ b: NSPoint, _ flags: NSEvent.ModifierFlags = []) {
        timeline.mouseDown(with: mouse(.leftMouseDown, a, flags))
        for k in 1...6 {
            let f = CGFloat(k) / 6
            timeline.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), flags))
        }
        timeline.mouseUp(with: mouse(.leftMouseUp, b, flags))
    }

    private func clip(_ p: Project?, _ id: EntityID) -> Clip? {
        p?.tracks.lazy.flatMap(\.clips).first { $0.id == id }
    }

    func selfTest(media path: String, downloadURL: String? = nil) async -> JSONValue {
        var results: [JSONValue] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(detail)]))
        }
        let previous = await runtime.editor.session?.url
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-uitest-\(UUID().uuidString).dmeproj")
        do {
            if previous != nil { _ = try await call("project.close", [:]) }
            _ = try await call("project.create", ["path": .string(dir.path), "name": .string("ui self-test"),
                                                  "width": .number(1080), "height": .number(1920), "frameRate": .number(30)])
            let imported = try await call("media.import", ["paths": .array([.string(path)])])
            guard let asset = imported["added"]?.arrayValue?.first?["id"]?.stringValue else { throw EditorError.invalid("the video did not import") }
            guard let p0 = await currentProject(), let main = p0.tracks.first?.id else { throw EditorError.invalid("no project") }
            func add(_ track: EntityID, _ start: Double, _ src: Double, _ len: Double) async throws -> EntityID {
                let r = try await call("clip.add", ["asset": .string(asset), "track": .string(track.raw), "start": .number(start),
                                                    "sourceStart": .number(src), "sourceDuration": .number(len)])
                return EntityID(r["applied"]?.arrayValue?.first?["args"]?["id"]?.stringValue ?? "")
            }
            let c1 = try await add(main, 0, 10, 4), c2 = try await add(main, 4, 20, 4)
            let ovR = try await call("track.add", ["kind": .string("overlay"), "name": .string("Over")])
            let ov = EntityID(ovR["applied"]?.arrayValue?.first?["args"]?["id"]?.stringValue ?? "")
            let o1 = try await add(ov, 10, 30, 3)
            _ = await until { self.project?.tracks.count == 2 && self.project?.tracks.last?.clips.count == 1 }
            timeline.pixelsPerSecond = 60
            timeline.scrollView?.contentView.scroll(to: .zero)
            let pps = Double(timeline.pixelsPerSecond)
            let frame = 1.0 / 30
            func rev() async -> Int { await runtime.editor.session?.revision ?? -1 }

            // Clicks select and never move.
            var r0 = await rev()
            if let p = timeline.point(at: Time(seconds: 2), track: main) {
                timeline.mouseDown(with: mouse(.leftMouseDown, p)); timeline.mouseUp(with: mouse(.leftMouseUp, p))
            }
            check("click selects a clip", timeline.selection == [c1], "\(timeline.selection)")
            if let p = timeline.point(at: Time(seconds: 2), track: main) { drag(p, NSPoint(x: p.x + 2, y: p.y + 1)) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            check("a click with 2 px of jitter moves nothing", await rev() == r0, "revision \(r0) -> \(await rev())")

            // Move, snap, trim.
            if let p = timeline.point(at: Time(seconds: 11.5), track: ov) { drag(p, NSPoint(x: p.x + pps, y: p.y)) }
            var ok = await until { abs((self.clip(await self.currentProject(), o1)?.start.seconds ?? 0) - 11) < frame * 1.5 }
            check("drag moves a clip by one second", ok, "start \(clip(await currentProject(), o1)?.start.seconds ?? -1)")
            if let p = timeline.point(at: Time(seconds: 12.5), track: ov) {   // its start (11) to 3 px after 8 s
                drag(p, NSPoint(x: p.x - (11 - 8) * pps + 3, y: p.y))
            }
            ok = await until { self.clip(await self.currentProject(), o1)?.start == Time(seconds: 8) }
            check("a moved clip snaps to the edge of another", ok, "start \(clip(await currentProject(), o1)?.start.seconds ?? -1)")
            if let c = clip(await currentProject(), o1), let p = timeline.point(at: c.end, track: ov) {
                drag(NSPoint(x: p.x - 2, y: p.y), NSPoint(x: p.x - 2 - pps, y: p.y))
            }
            ok = await until { abs((self.clip(await self.currentProject(), o1)?.end.seconds ?? 0) - 10) < frame * 1.5 }
            check("dragging an end edge trims", ok, "end \(clip(await currentProject(), o1)?.end.seconds ?? -1)")
            r0 = await rev()
            if let p = timeline.point(at: Time(seconds: 4), track: main) { drag(NSPoint(x: p.x + 2, y: p.y), NSPoint(x: p.x + 2 - pps, y: p.y)) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            check("a trim into the neighbouring clip stops at it", clip(await currentProject(), c2)?.start == Time(seconds: 4) && message?.0.contains("overlap") != true,
                  "start \(clip(await currentProject(), c2)?.start.seconds ?? -1)")

            // Scrubbing and every shortcut.
            if let p = timeline.point(at: Time(seconds: 2.5), track: main) { drag(NSPoint(x: p.x, y: timeline.rulerY), NSPoint(x: p.x, y: timeline.rulerY)) }
            ok = await until { abs(self.runtime.player.currentTime.seconds - 2.5) < frame * 1.5 }
            check("a click on the ruler moves the playhead", ok, "player at \(runtime.player.currentTime.seconds)")
            func key(_ k: String, expect: @escaping () async -> Bool, _ name: String) async {
                let handled = handleKey(k)
                let good = await until(3, expect)
                check("\(k): \(name)", handled && good, "player \(runtime.player.currentTime.seconds), playing \(runtime.player.isPlaying)")
            }
            let duration = await currentProject()?.duration.seconds ?? 0
            await key("home", expect: { self.runtime.player.currentTime.seconds == 0 }, "jump to the start")
            await key("end", expect: { abs(self.runtime.player.currentTime.seconds - duration) < 2 * frame }, "jump to the end")
            await key("home", expect: { self.runtime.player.currentTime.seconds == 0 }, "jump to the start again")
            await key("down", expect: { abs(self.runtime.player.currentTime.seconds - 4) < frame / 2 }, "next edit")
            await key("up", expect: { self.runtime.player.currentTime.seconds < frame / 2 }, "previous edit")
            await key("right", expect: { abs(self.runtime.player.currentTime.seconds - frame) < frame / 2 }, "one frame on")
            await key("shift+right", expect: { abs(self.runtime.player.currentTime.seconds - 11 * frame) < frame / 2 }, "ten frames on")
            await key("left", expect: { abs(self.runtime.player.currentTime.seconds - 10 * frame) < frame / 2 }, "one frame back")
            await key("space", expect: { self.runtime.player.isPlaying }, "play")
            await key("space", expect: { !self.runtime.player.isPlaying }, "pause")
            _ = try await call("player.seek", ["time": .number(9)])
            _ = await until { abs(self.runtime.player.currentTime.seconds - 9) < frame }
            timeline.select([o1])
            await key("cmd+b", expect: { await self.currentProject()?.tracks.last?.clips.count == 2 }, "split the selected clip's track")
            check("cmd+b leaves the main track alone", await currentProject()?.tracks.first?.clips.count == 2)
            await key("cmd+z", expect: { await self.currentProject()?.tracks.last?.clips.count == 1 }, "undo")
            await key("cmd+shift+z", expect: { await self.currentProject()?.tracks.last?.clips.count == 2 }, "redo")
            if let second = await currentProject()?.tracks.last?.clips.last?.id {
                timeline.select([second])
                await key("delete", expect: { await self.currentProject()?.tracks.last?.clips.count == 1 }, "delete the selection")
            }
            _ = try await call("player.seek", ["time": .number(2)])
            _ = await until { abs(self.runtime.player.currentTime.seconds - 2) < frame }
            timeline.select([])
            let before = await currentProject()?.tracks.first?.end.seconds ?? 0
            await key("w", expect: { abs((await self.currentProject()?.tracks.first?.end.seconds ?? 0) - (before - 2)) < frame }, "delete to the clip's end")
            await key("q", expect: { abs((await self.currentProject()?.tracks.first?.end.seconds ?? 0) - (before - 4)) < frame }, "delete to the clip's start")

            // Sliders in the panels act on the selected clip.
            let first = await currentProject()?.tracks.first?.clips.first?.id ?? c1
            timeline.select([first])
            _ = await until { self.lastPanelTarget == [first] }
            func slider(_ id: String, in view: NSView) -> CommitSlider? {
                // Sliders in tabs that are not shown are out of the view tree.
                let tabs = view.allSubviews.compactMap { $0 as? NSTabView }.flatMap { $0.tabViewItems.compactMap(\.view) }
                return ([view] + tabs).flatMap { [$0] + $0.allSubviews }.compactMap { $0 as? CommitSlider }
                    .first { $0.identifier?.rawValue == id }
            }
            for (name, value) in [("exposure", 40.0), ("temperature", -30.0), ("vignette", 50.0)] {
                if let s = slider(name, in: inspector) {
                    s.doubleValue = value
                    s.sendAction(s.action, to: s.target)
                }
                let good = await until {
                    guard let p = await self.currentProject(), let c = self.clip(p, first), let t = p.tracks.first,
                          let l = p.effectiveLook(c, on: t) else { return false }
                    return l[slider: name] == value
                }
                check("colour slider \(name) sets the clip's look", good)
            }
            // A drag shows a live picture without changing the project, then applies once.
            if let s = slider("contrast", in: inspector) {
                let r1 = await rev()
                let lookID = await currentProject().flatMap { p in self.clip(p, first).flatMap { c in p.tracks.first.flatMap { p.effectiveLook(c, on: $0) } } }
                let task = Task { await s.simulateDrag([10, 20, 30, 40]) }
                // The dragged value reaches the player's look table (drawn at
                // once) or, for a change that needs a new composition, a still.
                let shown = await until(2) {
                    if self.previewShown { return true }
                    guard var l = lookID, let now = self.runtime.player.built?.looks.current(l.id) else { return false }
                    l.contrast = 20
                    return now == LookUniforms(l) || { l.contrast = 10; return now == LookUniforms(l) }()
                }
                let unchanged = await rev() == r1
                await task.value
                let applied = await until {
                    guard let p = await self.currentProject(), let c = self.clip(p, first), let t = p.tracks.first else { return false }
                    return p.effectiveLook(c, on: t)?[slider: "contrast"] == 40
                }
                let cleared = await until(3) { !self.previewShown }
                let r2 = await rev()
                check("dragging a slider shows a live picture and changes nothing", shown && unchanged, "shown \(shown), unchanged \(unchanged)")
                check("letting go applies the value once and ends the preview", applied && cleared && r2 == r1 + 1,
                      "applied \(applied), cleared \(cleared), revisions +\(r2 - r1)")
            }
            _ = try await call("effect.add", ["clips": .array([.string(first.raw)]), "effect": .string("fade.in")])
            _ = await until { self.clip(self.project, first)?.effects.count == 1 }
            effectsPanel.update(project: project, selection: [first])
            if let fx = clip(await currentProject(), first)?.effects.first, let s = slider("\(fx.id.raw)|duration", in: effectsPanel) {
                s.doubleValue = 1.25
                s.sendAction(s.action, to: s.target)
            }
            ok = await until { (self.clip(await self.currentProject(), first)?.effects.first?.duration?.seconds ?? 0) == 1.25 }
            check("effect slider sets the effect's duration", ok, "\(clip(await currentProject(), first)?.effects.first?.duration?.seconds ?? -1)")
            if let s = slider("scale", in: effectsPanel) {
                s.doubleValue = 1.2
                s.sendAction(s.action, to: s.target)
            }
            ok = await until { (self.clip(await self.currentProject(), first)?.transform.scale ?? 0) == 1.2 }
            check("transform slider sets the clip's scale", ok, "\(clip(await currentProject(), first)?.transform.scale ?? -1)")

            // More of CapCut's keys: select all, clear, copy and paste, duplicate, marker, nudge, zoom.
            let all = await currentProject()?.tracks.flatMap(\.clips).count ?? 0
            await key("cmd+a", expect: { self.timeline.selection.count == all }, "select every clip")
            await key("escape", expect: { self.timeline.selection.isEmpty }, "clear the selection")
            if let firstMain = await currentProject()?.tracks.first?.clips.first?.id {
                timeline.select([firstMain])
                _ = handleKey("cmd+c")
                _ = await until { self.copiedClips == [firstMain] }
                check("cmd+c: copy the selection", copiedClips == [firstMain])
                let n = await currentProject()?.tracks.first?.clips.count ?? 0
                _ = try await call("player.seek", ["time": .number(0)])
                _ = await until { self.runtime.player.currentTime.seconds == 0 }
                await key("cmd+v", expect: { await self.currentProject()?.tracks.first?.clips.count == n + 1 }, "paste at the playhead")
                timeline.select([firstMain])
                await key("cmd+d", expect: { await self.currentProject()?.tracks.first?.clips.count == n + 2 }, "duplicate the selection")
            }
            let markers = await currentProject()?.markers.count ?? 0
            await key("m", expect: { await self.currentProject()?.markers.count == markers + 1 }, "marker at the playhead")
            if let o = await currentProject()?.tracks.last?.clips.first {
                timeline.select([o.id])
                await key(".", expect: { self.clip(await self.currentProject(), o.id)?.start == o.start + Time(seconds: frame) }, "nudge one frame later")
                await key(",", expect: { self.clip(await self.currentProject(), o.id)?.start == o.start }, "nudge one frame earlier")
            }
            let z = timeline.pixelsPerSecond
            await key("cmd+=", expect: { self.timeline.pixelsPerSecond > z * 1.2 }, "zoom in")
            await key("cmd+-", expect: { abs(self.timeline.pixelsPerSecond - z) < 1 }, "zoom out")
            await key("shift+z", expect: { self.timeline.pixelsPerSecond != z }, "zoom to fit")

            // ---- What the window gained for people: panels, menus, header buttons, drops.
            func setSlider(_ id: String, _ v: Double, in view: NSView) {
                if let s = slider(id, in: view) { s.doubleValue = v; s.sendAction(s.action, to: s.target) }
            }
            func current(_ id: EntityID) async -> Clip? { clip(await currentProject(), id) }

            // The Clip panel.
            let target = await currentProject()?.tracks.first?.clips.first?.id ?? c1
            timeline.select([target])
            _ = await until { self.lastPanelTarget == [target] }
            setSlider("speed", 1.5, in: clipPanel)
            ok = await until { abs((await current(target)?.speed ?? 0) - 1.5) < 0.001 }
            check("Clip panel: speed slider", ok, "\(await current(target)?.speed ?? -1)")
            if (try? await currentProject()?.asset(current(target)?.asset ?? "").info.audio) != nil {
                setSlider("gainDB", clipPanel.fader.position(of: -6), in: clipPanel)
                ok = await until { (await current(target)?.gainDB ?? 0) == -6 }
                check("Clip panel: volume slider", ok, "\(await current(target)?.gainDB ?? 0)")
                setSlider("fadeIn", 0.5, in: clipPanel)
                ok = await until { (await current(target)?.fadeIn.seconds ?? 0) == 0.5 }
                check("Clip panel: fade-in slider", ok)
                if let mute = clipPanel.controls["muted"] as? NSButton {
                    mute.state = .on
                    mute.sendAction(mute.action, to: mute.target)
                }
                ok = await until { await current(target)?.muted == true }
                check("Clip panel: mute checkbox", ok)
            }
            setSlider("cropLeft", 0.1, in: clipPanel)
            ok = await until { (await current(target)?.transform.cropLeft ?? 0) == 0.1 }
            check("Clip panel: crop slider", ok, "\(await current(target)?.transform.cropLeft ?? -1)")
            if let fit = clipPanel.controls["fit"] as? NSPopUpButton {
                fit.selectItem(at: 1)
                fit.sendAction(fit.action, to: fit.target)
            }
            ok = await until { await current(target)?.transform.fit == .fill }
            check("Clip panel: fit popup", ok)
            if let matte = clipPanel.controls["matte"] as? NSPopUpButton {
                matte.selectItem(at: 1)
                matte.sendAction(matte.action, to: matte.target)
            }
            ok = await until { (try? await self.currentProject()?.asset(EntityID(asset)).matte) == .vision }
            check("Clip panel: person matte popup", ok)
            _ = try? await call("media.setMatte", ["id": .string(asset), "source": .string("none")])

            // Track header buttons.
            for (flag, track) in [(TimelineView.TrackFlag.locked, ov), (.hidden, ov), (.muted, main)] {
                if let p = timeline.headerButtonPoint(track, flag) {
                    timeline.mouseDown(with: mouse(.leftMouseDown, p)); timeline.mouseUp(with: mouse(.leftMouseUp, p))
                }
                func value() async -> Bool? {
                    guard let t = await currentProject()?.tracks.first(where: { $0.id == track }) else { return nil }
                    return switch flag { case .locked: t.locked; case .hidden: t.hidden; case .muted: t.muted }
                }
                ok = await until { await value() == true }
                if let p = timeline.headerButtonPoint(track, flag) {
                    timeline.mouseDown(with: mouse(.leftMouseDown, p)); timeline.mouseUp(with: mouse(.leftMouseUp, p))
                }
                let back = await until { await value() == false }
                check("track header: \(flag.rawValue) button turns on and off", ok && back)
            }

            // Markers: drawn in the ruler, a click snaps to one, its menu removes it.
            if let mk = await currentProject()?.markers.first {
                let px = timeline.xPosition(mk.time) + 3
                drag(NSPoint(x: px, y: timeline.rulerY), NSPoint(x: px, y: timeline.rulerY))
                ok = await until { abs(self.runtime.player.currentTime.seconds - mk.time.seconds) < frame / 2 }
                check("a click next to a marker in the ruler goes to it", ok, "player \(runtime.player.currentTime.seconds), marker \(mk.time.seconds)")
                let n = await currentProject()?.markers.count ?? 0
                if let m = timeline.menu(for: mouse(.rightMouseDown, NSPoint(x: px, y: timeline.rulerY))),
                   let i = m.items.first(where: { $0.title == "Remove Marker" }), let a = i.action {
                    NSApp.sendAction(a, to: i.target, from: i)
                }
                ok = await until { await self.currentProject()?.markers.count == n - 1 }
                check("marker menu: Remove Marker", ok)
            } else {
                check("a marker exists to test", false)
            }

            // Right-click menus on a clip and on a track header.
            if let c = await currentProject()?.tracks.first?.clips.first, let p = timeline.point(at: c.start + Time(seconds: 0.5), track: main) {
                let n = await currentProject()?.tracks.first?.clips.count ?? 0
                let m = timeline.menu(for: mouse(.rightMouseDown, p))
                check("clip menu lists split, copy, duplicate, delete", ["Split at Playhead", "Copy", "Duplicate", "Delete"].allSatisfy { t in m?.items.contains { $0.title == t } == true })
                if let i = m?.items.first(where: { $0.title == "Duplicate" }), let a = i.action { NSApp.sendAction(a, to: i.target, from: i) }
                ok = await until { await self.currentProject()?.tracks.first?.clips.count == n + 1 }
                check("clip menu: Duplicate", ok)
            }
            if let p = timeline.point(at: .zero, track: ov) {
                let hp = NSPoint(x: timeline.visibleRect.minX + 20, y: p.y)
                let n = await currentProject()?.tracks.count ?? 0
                if let m = timeline.menu(for: mouse(.rightMouseDown, hp)), let i = m.items.first(where: { $0.title == "Add Audio Track" }), let a = i.action {
                    NSApp.sendAction(a, to: i.target, from: i)
                }
                ok = await until { await self.currentProject()?.tracks.count == n + 1 }
                check("track menu: Add Audio Track", ok)
                let idx = await currentProject()?.tracks.firstIndex { $0.id == ov } ?? -1
                if let m = timeline.menu(for: mouse(.rightMouseDown, hp)), let i = m.items.first(where: { $0.title == "Move Down" }), let a = i.action {
                    NSApp.sendAction(a, to: i.target, from: i)
                }
                ok = await until { await self.currentProject()?.tracks.firstIndex { $0.id == ov } == idx - 1 }
                check("track menu: Move Down", ok, "index \(idx) -> \(await currentProject()?.tracks.firstIndex { $0.id == ov } ?? -1)")
                _ = try? await call("track.reorder", ["id": .string(ov.raw), "index": .number(Double(idx))])
                if let audio = await currentProject()?.tracks.last, audio.kind == .audio, audio.clips.isEmpty,
                   let ap = timeline.point(at: .zero, track: audio.id) {
                    if let m = timeline.menu(for: mouse(.rightMouseDown, NSPoint(x: timeline.visibleRect.minX + 20, y: ap.y))),
                       let i = m.items.first(where: { $0.title == "Remove Track…" }), let a = i.action {
                        NSApp.sendAction(a, to: i.target, from: i)
                    }
                    ok = await until { await self.currentProject()?.tracks.count == n }
                    check("track menu: Remove Track (empty, no question)", ok)
                }
            }

            // Importing a picture puts it on a free overlay track at the playhead.
            let png = FileManager.default.temporaryDirectory.appendingPathComponent("dme-uitest-\(UUID().uuidString).png")
            let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in NSColor.systemPink.setFill(); r.fill(); return true }
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: png) }
            _ = try await call("player.seek", ["time": .number(1)])
            _ = await until { abs(self.runtime.player.currentTime.seconds - 1) < frame }
            await importAndAppend([png])
            ok = await until {
                guard let p = await self.currentProject(), let a = p.media.first(where: { $0.path == png.path }) else { return false }
                return p.tracks.contains { t in t.kind == .overlay && t.clips.contains { $0.asset == a.id && abs($0.start.seconds - 1) < frame } }
            }
            check("import a picture: on an overlay track at the playhead", ok)
            await importAndAppend([URL(fileURLWithPath: path)], at: Time(seconds: 20), track: ov)
            ok = await until { await self.currentProject()?.tracks.first { $0.id == ov }?.clips.contains { abs($0.start.seconds - 20) < frame } == true }
            check("a file dropped on a track goes there at the drop time", ok)

            // The Media panel lists the pool; Add at playhead places the selected file.
            ok = await until { self.mediaPanel.rows.count == (self.project?.media.filter { !$0.isHyperFrames }.count ?? -1) }
            check("Media panel lists every file", ok, "\(mediaPanel.rows.count)")
            if let a = await currentProject()?.media.first(where: { $0.path == png.path }) {
                let n = await currentProject()?.tracks.flatMap(\.clips).filter { $0.asset == a.id }.count ?? 0
                mediaPanel.select([a.id])
                mediaPanel.addAtPlayhead()
                ok = await until { await self.currentProject()?.tracks.flatMap(\.clips).filter { $0.asset == a.id }.count == n + 1 }
                check("Media panel: Add at playhead", ok)
            }

            // The Words panel: an imported transcript, click a word, find a word.
            let json = FileManager.default.temporaryDirectory.appendingPathComponent("dme-uitest-\(UUID().uuidString).json")
            let ws = (0..<60).map { i in "{\"text\": \"w\(i)\", \"start\": \(Double(i)), \"end\": \(Double(i) + 0.6)}" }.joined(separator: ",")
            try? Data("{\"words\": [\(ws)]}".utf8).write(to: json)
            _ = try await call("transcript.import", ["asset": .string(asset), "path": .string(json.path)])
            ok = await until(5) { !self.wordsPanel.words.isEmpty }
            check("Words panel shows the transcript's words", ok, "\(wordsPanel.words.count) words")
            if wordsPanel.words.count > 2 {
                let w = wordsPanel.words[2]
                wordsPanel.text.setSelectedRange(NSRange(location: w.range.location + 1, length: 0))
                ok = await until { abs(self.runtime.player.currentTime.seconds - w.start) < frame }
                check("Words panel: a click on a word moves the playhead there", ok, "player \(runtime.player.currentTime.seconds), word \(w.start)")
                let wanted = (wordsPanel.text.string as NSString).substring(with: wordsPanel.words[1].range)
                wordsPanel.search.stringValue = wanted
                wordsPanel.find()
                ok = await until { self.wordsPanel.status.stringValue.contains("found") }
                check("Words panel: find a word", ok, wordsPanel.status.stringValue)
            }
            try? FileManager.default.trashItem(at: json, resultingItemURL: nil)

            // Marking a range on the ruler with ⌥ and deleting it.
            timeline.select([])
            let d0 = await currentProject()?.duration.seconds ?? 0
            let ra = timeline.xPosition(Time(seconds: 1)), rb = timeline.xPosition(Time(seconds: 2))
            drag(NSPoint(x: ra, y: timeline.rulerY), NSPoint(x: rb, y: timeline.rulerY), .option)
            check("⌥-drag on the ruler marks a range", timeline.markedRange != nil, "\(String(describing: timeline.markedRange))")
            await key("delete", expect: { abs((await self.currentProject()?.duration.seconds ?? 0) - (d0 - 1)) < 2 * frame }, "delete the marked range")

            // Menus run their tools and show the current keys.
            if let app = NSApp.delegate as? AppDelegate {
                let split = app.entries.first { ($0.representedObject as? AppDelegate.Entry)?.tool == "timeline.split" }
                check("menu titles show the bound key", split?.title.hasSuffix("⌘B") == true, split?.title ?? "")
                check("key glyphs", AppDelegate.glyphs("cmd+shift+z") == "⇧⌘Z" && AppDelegate.glyphs("shift+left") == "⇧←")
                let n = await currentProject()?.markers.count ?? 0
                if let m = app.entries.first(where: { ($0.representedObject as? AppDelegate.Entry)?.tool == "marker.add" }) { app.runEntry(m) }
                ok = await until { await self.currentProject()?.markers.count == n + 1 }
                check("Edit menu: Add Marker runs without its key", ok)

                app.showSettings(nil)
                ok = await until(4) { (app.settingsWindow?.leaves.count ?? 0) > 10 && app.settingsWindow?.bindings.count == self.runtime.keymap.current.bindings.count }
                check("Settings window lists settings and keys", ok, "\(app.settingsWindow?.leaves.count ?? 0) settings, \(app.settingsWindow?.bindings.count ?? 0) keys")
                app.settingsWindow?.close()

                app.showHistory(nil)
                let hw = app.historyWindow
                ok = await until(4) { (hw?.rows.count ?? 0) > 3 }
                check("History window lists changes", ok, "\(hw?.rows.count ?? 0)")
                if let hw, hw.rows.count > 2 {
                    let r1 = await rev()
                    let back = hw.rows[2].revision
                    await hw.revert(to: back)
                    ok = await until { await rev() != r1 }
                    check("History: go back to an earlier revision", ok, "to \(back)")
                    _ = try? await call("history.redo", [:]); _ = try? await call("history.redo", [:])
                }
                hw?.close()
            }

            // Transport buttons under the picture.
            _ = try await call("player.seek", ["time": .number(1)])
            let seeked = await until(5) { abs(self.runtime.player.currentTime.seconds - 1) < frame }
            let stepFrom = runtime.player.currentTime.seconds
            if let b = window?.contentView?.allSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Forward one frame" }) { b.performClick(nil) }
            ok = await until { abs(self.runtime.player.currentTime.seconds - (1 + frame)) < frame / 2 }
            check("transport: forward one frame button", ok, "seek landed \(seeked), before \(stepFrom), after \(runtime.player.currentTime.seconds)")
            if let b = window?.contentView?.allSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Go to start" }) { b.performClick(nil) }
            ok = await until { self.runtime.player.currentTime.seconds == 0 }
            check("transport: go to start button", ok)

            // Keyframe easing from the Effects panel.
            if let c = await currentProject()?.tracks.first?.clips.first {
                timeline.select([c.id])
                _ = try await call("player.seek", ["time": .number(c.start.seconds + 0.5)])
                _ = await until { abs(self.runtime.player.currentTime.seconds - (c.start.seconds + 0.5)) < frame }
                let src = c.sourceTime(at: c.start + Time(seconds: 0.5)).seconds
                _ = try await call("clip.setKeyframes", ["clip": .string(c.id.raw), "property": .string("scale"), "timeBase": .string("source"),
                                                         "keyframes": .array([.object(["time": .number(src), "value": .number(1.1)])])])
                _ = await until { await current(c.id)?.keyframes["scale"]?.isEmpty == false }
                effectsPanel.update(project: project, selection: [c.id])
                effectsPanel.playheadMoved(runtime.player.currentTime)
                if let pop = effectsPanel.allSubviews.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.toolTip?.hasPrefix("Easing") == true }) {
                    pop.selectItem(withTitle: "hold")
                    pop.sendAction(pop.action, to: pop.target)
                }
                ok = await until { await current(c.id)?.keyframes["scale"]?.first?.easing == .hold }
                check("Effects panel: easing popup sets the keyframe's easing", ok)
            }

            // Sliders fill from their neutral value.
            if let sp = slider("exposure", in: inspector) { check("a two-sided slider fills from 0", sp.neutral == 0) }
            if let sc = slider("scale", in: effectsPanel) { check("the scale slider fills from 1", sc.neutral == 1) }

            // Colour presets: save, update, rename, apply, delete.
            if let c = await currentProject()?.tracks.first?.clips.first {
                timeline.select([c.id])
                _ = await until { self.lastPanelTarget == [c.id] }
                if let s = slider("exposure", in: inspector) { s.doubleValue = 25; s.sendAction(s.action, to: s.target) }
                _ = await until { (await self.currentProject()).flatMap { p in p.tracks.first.flatMap { t in self.clip(p, c.id).flatMap { p.effectiveLook($0, on: t) } } }?[slider: "exposure"] == 25 }
                let name = "self-test \(UUID().uuidString.prefix(6))"
                await inspector.savePreset(name, replace: false)
                ok = await until { self.inspector.presetPopup.itemTitles.contains(name) && self.inspector.selectedPreset == name }
                check("Colour preset: save as new", ok, inspector.presetPopup.itemTitles.joined(separator: ","))
                check("Colour preset: the last one used is remembered", UserDefaults.standard.string(forKey: InspectorView.lastPresetKey) == name)
                _ = try? await call("look.renameProfile", ["name": .string(name), "newName": .string(name + " b")])
                inspector.refreshPresets(select: name + " b")
                ok = await until { self.inspector.selectedPreset == name + " b" }
                check("Colour preset: rename", ok)
                let looks = await currentProject()?.looks.count ?? 0
                inspector.loadProfile()
                ok = await until { (await self.currentProject()?.looks.count ?? 0) == looks + 1 }
                check("Colour preset: apply to the clip", ok)
                await inspector.deletePreset(name + " b")
                ok = await until { !self.inspector.presetPopup.itemTitles.contains(name + " b") }
                check("Colour preset: delete (to the Trash)", ok)
            }

            // Agent notes in the window.
            _ = try await call("notes.write", ["name": .string("spec"), "content": .string("# The edit\n\n- **cut** the pauses\n- keep it under 60 s"),
                                               "from": .number(1)])
            if let app = NSApp.delegate as? AppDelegate {
                app.showNotes(nil)
                ok = await until(4) { (app.notesWindow?.notes.count ?? 0) >= 1 }
                await app.notesWindow?.open("spec")
                let shownText = app.notesWindow?.text.string ?? ""
                check("Agent Notes lists and shows a note as text", ok && shownText.contains("The edit") && shownText.contains("cut the pauses") && !shownText.contains("**"),
                      String(shownText.prefix(60)))
                app.notesWindow?.close()

                app.showShortcuts(nil)
                let sc = app.shortcutsWindow?.rows ?? []
                check("Keyboard Shortcuts lists the keys", sc.contains { $0.key == "⇞" } && sc.contains { $0.key == "⌘B" } && sc.count > 30, "\(sc.count) rows")
                app.shortcutsWindow?.close()
            }

            // Page Up / Page Down / Return jump along clip edges.
            _ = try await call("player.seek", ["time": .number(5)])
            _ = await until { abs(self.runtime.player.currentTime.seconds - 5) < frame }
            // Jumps follow the main track's edges, the start and the end.
            let pj = await currentProject()
            let edges = ((pj?.tracks.first { $0.kind == .main }?.clips.flatMap { [$0.start.seconds, $0.end.seconds] } ?? []) + [0, pj?.duration.seconds ?? 0]).sorted()
            let prev = edges.last { $0 < 5 - frame / 2 } ?? 0, next = edges.first { $0 > 5 + frame / 2 } ?? 0
            await key("pagedown", expect: { abs(self.runtime.player.currentTime.seconds - next) < frame / 2 }, "end of the clip")
            _ = try await call("player.seek", ["time": .number(5)])
            _ = await until { abs(self.runtime.player.currentTime.seconds - 5) < frame }
            await key("return", expect: { abs(self.runtime.player.currentTime.seconds - prev) < frame / 2 }, "start of the clip")

            // Long timelines: hours in the time, zoom out to hours.
            check("time shows hours from an hour on", MainWindowController.format(Time(seconds: 10000)) == "2:46:40.00" && MainWindowController.format(Time(seconds: 61.5)) == "01:01.50")
            let zp = timeline.pixelsPerSecond
            timeline.pixelsPerSecond = 0.05
            check("the timeline zooms out to hours on one screen", timeline.pixelsPerSecond <= 0.06)
            timeline.pixelsPerSecond = zp

            // File › Download from Link, with a real post.
            if let link = downloadURL, let app = NSApp.delegate as? AppDelegate {
                app.showDownloads(nil)
                if let dw = app.downloadWindow {
                    await dw.reloadNow()
                    let before = dw.rows.count
                    dw.url.stringValue = link
                    dw.quality.selectItem(withTitle: "480")
                    dw.addToProject.state = .on
                    let clipsBefore = await currentProject()?.tracks.flatMap(\.clips).count ?? 0
                    dw.download()
                    ok = await until(300) { dw.job == nil && dw.rows.count == before + 1 }
                    check("Download window: the post downloads and is listed", ok, dw.status.stringValue)
                    let added = await until(20) { (await self.currentProject()?.tracks.flatMap(\.clips).count ?? 0) > clipsBefore }
                    check("Download window: Add to project puts it on the timeline", added, dw.status.stringValue)
                    let entry = dw.rows.last
                    let folder = entry?["folder"]?.stringValue
                    if let id = entry?["id"]?.stringValue {
                        dw.select(id)
                        await dw.inspectNow()
                        let sheetPath = folder.map { URL(fileURLWithPath: $0).appendingPathComponent("inspect").path }
                        let haveSheet = sheetPath.map { (try? FileManager.default.contentsOfDirectory(atPath: $0))?.contains { $0.hasSuffix(".png") } == true } ?? false
                        check("Download window: Look at it makes a contact sheet", haveSheet)
                        // Used by a clip: kept; after undo of the placing, trashed.
                        await dw.cleanup(["ids": .array([.string(id)])])
                        check("Download window: a download the timeline uses is kept", dw.rows.contains { $0["id"]?.stringValue == id }, dw.status.stringValue)
                        let used = await currentProject()?.tracks.flatMap(\.clips).filter { c in
                            (try? self.project?.asset(c.asset).path.hasPrefix(folder ?? "-")) == true
                        }.map { JSONValue.string($0.id.raw) } ?? []
                        if !used.isEmpty { _ = try? await call("clip.remove", ["ids": .array(used)]) }
                        await dw.cleanup(["ids": .array([.string(id)])])
                        let gone = folder.map { !FileManager.default.fileExists(atPath: $0) } ?? false
                        check("Download window: Move to Trash removes it", gone && !dw.rows.contains { $0["id"]?.stringValue == id }, dw.status.stringValue)
                    }
                    dw.close()
                }
            }

            // Export from the window (the menu's path after its save panel), in this release build.
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("dme-uitest-\(UUID().uuidString).mp4")
            await startExport(path: out.path, preset: "lesson", overwrite: true, reveal: false)
            let exported = FileManager.default.fileExists(atPath: out.path)
            let verified = exported ? (try? await call("export.verify", ["path": .string(out.path)])) : nil
            check("export from the window writes a playable file", exported && (verified?["frames"]?.doubleValue ?? 0) > 0,
                  "\(message?.0 ?? "") frames \(verified?["frames"]?.doubleValue ?? 0)")
            try? FileManager.default.trashItem(at: out, resultingItemURL: nil)
            // Only now: the picture is on the timeline that was exported.
            try? FileManager.default.trashItem(at: png, resultingItemURL: nil)

            // The Accent panel: pick a colour in the well and save.
            if let well = accentPanel.allSubviews.compactMap({ $0 as? NSColorWell }).first,
               let save = accentPanel.allSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save pick" }) {
                well.color = NSColor(srgbRed: 0x12 / 255.0, green: 0xAB / 255.0, blue: 0x34 / 255.0, alpha: 1)
                well.sendAction(well.action, to: well.target)
                save.performClick(nil)
            }
            ok = await until { await self.currentProject()?.accent?.acc == "#12AB34" }
            check("Accent panel saves the picked colour", ok, await currentProject()?.accent?.css ?? "none")
        } catch {
            check("self-test ran to the end", false, "\(error)")
        }
        _ = try? await call("project.close", [:])
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        if let previous { _ = try? await call("project.open", ["path": .string(previous.path)]) }
        let passed = results.filter { $0["ok"]?.boolValue == true }.count
        return .object(["passed": .number(Double(passed)), "failed": .number(Double(results.count - passed)), "checks": .array(results)])
    }
}

extension NSView {
    /// Every view under this one.
    var allSubviews: [NSView] { subviews + subviews.flatMap(\.allSubviews) }

    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        allSubviews.lazy.compactMap { $0 as? T }.first
    }
}

/// Hands the window to tool closures; they only touch it on the main actor.
struct AppBox<T>: @unchecked Sendable { let value: T }
