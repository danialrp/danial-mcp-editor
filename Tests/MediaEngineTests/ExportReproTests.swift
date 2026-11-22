import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// Exports a given project package to see that it finishes. Runs only when
/// DME_EXPORT_PROJECT names a .dmeproj (a copy: opening it may write to it).
@Suite("Export of a given project")
struct ExportReproTests {
    static let path = ProcessInfo.processInfo.environment["DME_EXPORT_PROJECT"]

    @Test(.enabled(if: path != nil), .timeLimit(.minutes(5))) func exportFinishes() async throws {
        let s = try await EditorSession.open(at: URL(fileURLWithPath: Self.path!))
        var p = await s.project
        // Clips of files that are gone (a self-test's temporary pictures) are left out.
        let missing = Set(p.media.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
        for i in p.tracks.indices { p.tracks[i].clips.removeAll { missing.contains($0.asset) } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-xr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = MediaContext(editor: Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber()))
        let preset = ExportPreset(width: 540, height: 960, frameRate: .fps30, dynamicRange: .sdr, videoCodec: .h264, videoBitrateMbps: 4, container: .mp4)
        var o = ExportOptions()
        o.parallelSegments = 4
        for t in p.tracks { print("[track]", t.kind, t.clips.map { "\($0.id) \($0.start.seconds)+\($0.duration.seconds) src \($0.sourceStart.seconds)+\($0.sourceDuration.seconds) \($0.asset)" }) }
        let r = try await ExportEngine.run(project: p, revision: 1, preset: preset, options: o, to: dir.appendingPathComponent("out.mp4"),
                                           media: media, cacheFolder: dir.appendingPathComponent("cache")) { done, total, msg in
            print("[export] \(done)/\(total) \(msg)")
        }
        print("[export] done", r)
        try await s.close()
    }
}
