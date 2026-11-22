import EditorCore
import EditorKit
import Foundation
import Testing
@testable import MediaEngine

/// Notes and onboarding, through the same tools an agent calls.
@MainActor
@Suite struct NoteTests {
    let runtime: EditorRuntime

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-n-\(UUID().uuidString)")
        runtime = EditorRuntime(settings: try UserSettingsStore(directory: dir))
    }

    @discardableResult
    func call(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        let tool = try #require(runtime.tool(name), "tool \(name)")
        return try await tool.call(runtime.editor, arguments: .object(args))
    }

    func open() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-n-\(UUID().uuidString)")
        _ = try await runtime.editor.createProject(at: dir.appendingPathComponent("p").path, name: "p",
                                                   settings: ProjectSettings(width: 1080, height: 1920, frameRate: .fps30, dynamicRange: .sdr))
    }

    @Test func onboardingWithoutAProject() async throws {
        let r = try await call("agent_onboard")
        #expect(r["project"] == .null)
        #expect(r["next"]?.stringValue?.contains("project_open") == true)
        let groups = try #require(r["tools"]?.objectValue)
        #expect(groups["notes"]?.arrayValue?.contains(.string("notes_write")) == true)
        #expect(groups["effect"]?.arrayValue?.contains(.string("effect_add")) == true)
        #expect(groups["agent"]?.arrayValue?.contains(.string("agent_onboard")) == true)
    }

    @Test func notesRoundTripWithSections() async throws {
        try await open()
        try await call("notes_write", ["name": .string("spec"), "title": .string("Spec"),
                                       "content": .string("# Reel\n\n## Goal\nA 40 s reel.\n\n## Style\nWarm, fast cuts.\n")])
        try await call("notes_write", ["name": .string("spec"), "mode": .string("section"), "section": .string("Style"),
                                       "content": .string("Cool, slow cuts.")])
        try await call("notes_write", ["name": .string("spec"), "mode": .string("section"), "section": .string("Music"),
                                       "content": .string("None.")])
        let style = try await call("notes_read", ["name": .string("spec"), "section": .string("style")])
        #expect(style["content"]?.stringValue == "## Style\nCool, slow cuts.\n")
        let goal = try await call("notes_read", ["name": .string("spec"), "section": .string("Goal")])
        #expect(goal["content"]?.stringValue?.contains("A 40 s reel.") == true, "other sections untouched")
        let full = try await call("notes_read", ["name": .string("spec")])
        #expect(full["headings"]?.arrayValue?.map(\.stringValue) == ["# Reel", "## Goal", "## Style", "## Music"])

        try await call("notes_write", ["name": .string("progress"), "content": .string("- cut pauses")])
        try await call("notes_write", ["name": .string("progress"), "mode": .string("append"), "content": .string("- colour next")])
        #expect(try await call("notes_read", ["name": .string("progress")])["content"]?.stringValue == "- cut pauses\n- colour next\n")

        try await call("notes_write", ["name": .string("Intro.md"), "content": .string("Hook is weak."),
                                       "clips": .array([.string("clip_x")]), "from": .number(0), "to": .number(3)])
        let list = try await call("notes_list")
        let names = list["notes"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["intro", "progress", "spec"])
        let intro = list["notes"]?.arrayValue?.first { $0["name"]?.stringValue == "intro" }
        #expect(intro?["clipsNoLongerInProject"]?.arrayValue == [.string("clip_x")], "stale clip anchors are flagged")
        #expect(intro?["summary"]?.stringValue == "Hook is weak.")
        #expect(try await call("notes_list", ["clip": .string("clip_x")])["notes"]?.arrayValue?.count == 1)
        #expect(try await call("notes_find", ["query": .string("COLOUR")])["matches"]?.arrayValue?.count == 1)

        await #expect(throws: EditorError.self) { try await call("notes_write", ["name": .string("../x"), "content": .string("x")]) }
        await #expect(throws: EditorError.self) { try await call("notes_read", ["name": .string("spec"), "section": .string("Nope")]) }
    }

    @Test func onboardingShowsSpecAndChangesSinceNotes() async throws {
        try await open()
        try await call("notes_write", ["name": .string("spec"), "content": .string("Make it short.")])
        try await call("marker_add", ["time": .number(1), "name": .string("hook")])
        try await call("marker_add", ["time": .number(2), "name": .string("end")])
        let r = try await call("agent_onboard")
        #expect(r["spec"]?.stringValue == "Make it short.\n")
        #expect(r["project"]?["markers"]?.arrayValue?.count == 2)
        #expect(r["changesSinceNotes"]?["commands"]?["marker.add"]?.doubleValue == 2)
        try await call("notes_write", ["name": .string("progress"), "content": .string("markers set")])
        let again = try await call("agent_onboard")
        #expect(again["changesSinceNotes"] == nil, "notes are up to date")
        #expect(again["progress"]?.stringValue == "markers set\n")
    }

    @Test func guideIsServed() async throws {
        let r = try await call("agent_guide")
        #expect(r["content"]?.stringValue?.contains("## Colour and light") == true)
        let part = try await call("agent_guide", ["section": .string("Effects and zoom")])
        #expect(part["content"]?.stringValue?.hasPrefix("## Effects and zoom") == true)
    }
}
