import EditorCore
import EditorKit
import Foundation
import Testing
@testable import MCPServer
@testable import MediaEngine

@MainActor
@Suite struct RuntimeTests {
    func runtime() throws -> EditorRuntime {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-r-\(UUID().uuidString)")
        return EditorRuntime(settings: try UserSettingsStore(directory: dir))
    }

    @Test func everyKeyBindingRunsAnExistingTool() throws {
        let r = try runtime()
        let names = Set(r.tools.map(\.name))
        for b in Keymap.capcut.bindings {
            // ui.* tools belong to the app window; ui.selfTest checks those keys.
            #expect(names.contains(b.tool) || b.tool.hasPrefix("ui."), "key \(b.key) runs unknown tool \(b.tool)")
        }
    }

    @Test func capcutKeysAreTheOnesTheOwnerAskedFor() {
        let k = Dictionary(uniqueKeysWithValues: Keymap.capcut.bindings.map { (Keymap.normalize($0.key), $0) })
        #expect(k["space"]?.tool == "player.toggle")
        #expect(k["cmd+b"]?.tool == "timeline.split")
        #expect(k["q"]?.args?["side"]?.stringValue == "left")
        #expect(k["w"]?.args?["side"]?.stringValue == "right")
        #expect(k["home"]?.args?["to"]?.stringValue == "start")
        #expect(k["end"]?.args?["to"]?.stringValue == "end")
    }

    @Test func placeholdersAreFilled() {
        let b = Keymap.Binding("q", "timeline.deleteToEdge", .object(["time": .string("$playhead"), "ids": .string("$selection")]))
        let a = Keymap.capcut.arguments(for: b, playhead: Time(seconds: 2.5), selection: ["c1"])
        #expect(a["time"]?.doubleValue == 2.5)
        #expect(a["ids"]?.arrayValue == [.string("c1")])
    }

    /// Cmd+B cuts the tracks of the selected clips, or the main track when nothing is selected.
    @Test func splitCutsTheSelectedClipsTracks() {
        let b = Keymap.capcut.bindings.first { $0.key == "cmd+b" }!
        let picked = Keymap.capcut.arguments(for: b, playhead: Time(seconds: 1), selection: ["c1"], selectedTracks: ["overlay1"])
        #expect(picked["tracks"]?.arrayValue == [.string("overlay1")])
        let none = Keymap.capcut.arguments(for: b, playhead: Time(seconds: 1), selection: [])
        #expect(none["tracks"] == nil, "no selection: the tool's default track")
        #expect(none["time"]?.doubleValue == 1)
    }

    @Test func keyNamesNormalise() {
        #expect(Keymap.normalize("Shift+Cmd+Z") == "shift+cmd+z")
        #expect(Keymap.normalize("command+option+b") == "alt+cmd+b")
    }

    @Test func allToolNamesAreValidForMCPAndUnique() throws {
        let names = try runtime().tools.map { MCPHandler.mcpName($0.name) }
        #expect(Set(names).count == names.count)
        for n in names { #expect(n.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil, "bad name \(n)") }
    }
}
