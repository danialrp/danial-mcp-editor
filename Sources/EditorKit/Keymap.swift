import EditorCore
import Foundation

/// Key bindings as data. Each binding runs a tool, the same tools agents call,
/// so a key can do nothing a tool cannot. Arguments may use placeholders:
/// `$playhead` (the playhead time) and `$selection` (selected clip ids).
public struct Keymap: Codable, Equatable, Sendable {
    public struct Binding: Codable, Equatable, Sendable {
        /// For example "space", "cmd+b", "q", "shift+left", "cmd+shift+z".
        public var key: String
        public var tool: String
        public var args: JSONValue?

        public init(_ key: String, _ tool: String, _ args: JSONValue? = nil) {
            self.key = key
            self.tool = tool
            self.args = args
        }
    }

    public var name: String
    public var bindings: [Binding]

    public init(name: String, bindings: [Binding]) {
        self.name = name
        self.bindings = bindings
    }

    /// CapCut's standard keys for the actions this editor has.
    public static let capcut = Keymap(name: "capcut", bindings: [
        Binding("space", "player.toggle"),
        Binding("cmd+b", "timeline.split", .object(["time": .string("$playhead"), "tracks": .string("$selectedTracks")])),
        Binding("q", "timeline.deleteToEdge", .object(["time": .string("$playhead"), "side": .string("left")])),
        Binding("w", "timeline.deleteToEdge", .object(["time": .string("$playhead"), "side": .string("right")])),
        Binding("left", "player.step", .object(["frames": .number(-1)])),
        Binding("right", "player.step", .object(["frames": .number(1)])),
        Binding("shift+left", "player.step", .object(["frames": .number(-10)])),
        Binding("shift+right", "player.step", .object(["frames": .number(10)])),
        Binding("up", "player.jump", .object(["to": .string("previousEdge")])),
        Binding("down", "player.jump", .object(["to": .string("nextEdge")])),
        Binding("home", "player.jump", .object(["to": .string("start")])),
        Binding("end", "player.jump", .object(["to": .string("end")])),
        // Page Up / Page Down (fn+↑ / fn+↓) and Return: the edges of clips,
        // as CapCut's Page Up and Edits' Return take you to a clip's start.
        Binding("pageup", "player.jump", .object(["to": .string("previousEdge")])),
        Binding("pagedown", "player.jump", .object(["to": .string("nextEdge")])),
        Binding("return", "player.jump", .object(["to": .string("previousEdge")])),
        Binding("delete", "clip.remove", .object(["ids": .string("$selection")])),
        Binding("forwarddelete", "clip.remove", .object(["ids": .string("$selection")])),
        Binding("cmd+z", "history.undo"),
        Binding("cmd+shift+z", "history.redo"),
        Binding("cmd+c", "ui.copy"),
        Binding("cmd+v", "clip.copyTo", .object(["ids": .string("$copied"), "start": .string("$playhead")])),
        Binding("cmd+d", "clip.duplicate", .object(["ids": .string("$selection")])),
        Binding("cmd+a", "ui.select", .object(["ids": .string("$all")])),
        Binding("escape", "ui.select", .object(["ids": .array([])])),
        Binding("m", "marker.add", .object(["time": .string("$playhead")])),
        Binding("r", "audio.record", .object(["action": .string("toggle")])),
        Binding("cmd+=", "ui.zoom", .object(["to": .string("in")])),
        Binding("cmd+-", "ui.zoom", .object(["to": .string("out")])),
        Binding("shift+z", "ui.zoom", .object(["to": .string("fit")])),
        Binding(",", "clip.nudge", .object(["ids": .string("$selection"), "frames": .number(-1)])),
        Binding(".", "clip.nudge", .object(["ids": .string("$selection"), "frames": .number(1)])),
    ])

    /// Puts the playhead and selection into a binding's arguments.
    /// `$selectedTracks` becomes the tracks of the selected clips; with
    /// nothing selected the argument is left out, so the tool's default applies.
    public func arguments(for b: Binding, playhead: Time, selection: [EntityID], selectedTracks: [EntityID] = []) -> JSONValue {
        func fill(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string("$playhead"): .number(playhead.seconds)
            case .string("$selection"): .array(selection.map { .string($0.raw) })
            case .string("$selectedTracks"): .array(selectedTracks.map { .string($0.raw) })
            case .object(let o): .object(o.filter { !($0.value == .string("$selectedTracks") && selectedTracks.isEmpty) }.mapValues(fill))
            case .array(let a): .array(a.map(fill))
            default: v
            }
        }
        return fill(b.args ?? .object([:]))
    }

    /// Normalises a key string: lower case, modifiers in a fixed order.
    public static func normalize(_ key: String) -> String {
        let parts = key.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return key }
        let order = ["ctrl", "alt", "shift", "cmd"]
        let mods = Set(parts.dropLast().map { $0 == "option" ? "alt" : $0 == "command" ? "cmd" : $0 == "control" ? "ctrl" : $0 })
        return (order.filter(mods.contains) + [last]).joined(separator: "+")
    }
}

/// The active keymap: the user's `keymap.json` next to the settings file if
/// there is one, otherwise CapCut's keys.
public final class KeymapStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cached: Keymap

    public init(settings: UserSettingsStore) {
        url = settings.directory.appendingPathComponent("keymap.json")
        if let d = try? Data(contentsOf: url), let k = try? JSONDecoder().decode(Keymap.self, from: d) {
            cached = k
        } else {
            cached = .capcut
        }
    }

    public var current: Keymap {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func save(_ k: Keymap) throws {
        lock.lock(); defer { lock.unlock() }
        try JSON.prettyEncoder.encode(k).write(to: url, options: .atomic)
        cached = k
    }

    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        cached = .capcut
    }

    /// Tools to read and change the keymap.
    public func tools(validTools: @escaping @Sendable () -> Set<String>) -> [Tool] {
        [
            Tool("keymap.get", .read, "The active key bindings. Each runs a tool; $playhead, $selection, $selectedTracks, $copied (clips copied with Cmd+C) and $all fill in the playhead time, the selected clips, their tracks, the copied clips and every clip. ui.* tools act on the app window.") { [self] _, _ in
                try JSONValue(encoding: current)
            },
            Tool("keymap.set", .manage, "Bind a key to a tool, or remove a binding when tool is omitted. Saved to keymap.json next to the settings file.", [
                Parameter("key", .string, "For example \"cmd+b\", \"q\", \"shift+left\"", required: true),
                Parameter("tool", .string, "Tool name, for example timeline.split; omit to unbind"),
                Parameter("args", .object, "Fixed arguments; $playhead, $selection, $selectedTracks, $copied and $all are filled in"),
            ]) { [self] _, args in
                let key = Keymap.normalize(try args.requiredString("key"))
                var k = current
                k.bindings.removeAll { Keymap.normalize($0.key) == key }
                if let tool = try args.string("tool") {
                    let name = tool.contains(".") ? tool : tool.replacingOccurrences(of: "_", with: ".", options: [], range: tool.range(of: "_"))
                    // ui.* tools belong to the app window (dme has no window to act on).
                    guard validTools().contains(name) || name.hasPrefix("ui.") else { throw EditorError.invalid("no tool \(tool)", parameter: "tool") }
                    k.bindings.append(.init(key, name, args.values["args"]))
                }
                k.name = "custom"
                try save(k)
                return try JSONValue(encoding: k)
            },
            Tool("keymap.reset", .manage, "Go back to CapCut's keys; a custom keymap.json is moved to the Trash.") { [self] _, _ in
                try reset()
                return try JSONValue(encoding: current)
            },
        ]
    }
}
