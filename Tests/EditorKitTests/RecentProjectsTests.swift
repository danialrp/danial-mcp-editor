import EditorCore
import Foundation
import Testing
@testable import EditorKit

@Suite struct RecentProjectsTests {
    struct NoProbe: MediaProber {
        func probe(_ url: URL) async throws -> MediaInfo { MediaInfo(duration: .zero, video: nil, audio: nil) }
    }

    /// Scratch projects in the temporary folder stay out of Open Recent;
    /// a project anywhere else goes to the top.
    @Test func scratchProjectsAreNotRemembered() async throws {
        let home = tempDir()
        let editor = Editor(settings: try UserSettingsStore(directory: home), prober: NoProbe())
        let settings = ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: .sdr)
        _ = try await editor.createProject(at: tempDir().appendingPathComponent("scratch.dmeproj").path, name: "s", settings: settings)
        try await editor.closeProject()
        #expect(editor.settings.current.recentProjects.isEmpty)

        let kept = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dme-test-\(UUID().uuidString).dmeproj")
        defer { try? FileManager.default.trashItem(at: kept, resultingItemURL: nil) }
        _ = try await editor.createProject(at: kept.path, name: "k", settings: settings)
        try await editor.closeProject()
        #expect(editor.settings.current.recentProjects == [kept.path])
    }
}
