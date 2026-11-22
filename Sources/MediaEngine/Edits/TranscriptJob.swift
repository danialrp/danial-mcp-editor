import EditorCore
import EditorKit
import Foundation

extension AnalysisTools {
    /// `transcript.create`: a job that transcribes through the Edits bridge
    /// and stores the result in the project.
    public static func transcriptTools(_ media: MediaContext, jobs: JobCenter, bridge: EditsBridge) -> [Tool] {
        let editor = media.editor
        return [
            Tool("transcript.create", .write, "Transcribe a media file (or part of it) word by word through the Edits app, as a job. Only the sound is sent. If Edits is in use the job waits; everything the job creates in Edits is removed and Edits is quit again if the job started it. Returns a job id; job.wait gives the transcript id.", [
                Parameter("asset", .id, "Media asset id", required: true),
                Parameter("sourceStart", .seconds, "From this time in the file; default 0"),
                Parameter("sourceEnd", .seconds, "To this time in the file; default the end"),
                Parameter("language", .string, "Language code; default settings.edits.language (fa)"),
            ]) { _, args in
                let session = try await editor.requireSession()
                let a = try await session.project.asset(EntityID(try args.requiredString("asset")))
                guard a.info.audio != nil else { throw EditorError.invalid("media \(a.id) has no sound") }
                let start = try args.time("sourceStart") ?? .zero
                let end = Time.min(try args.time("sourceEnd") ?? a.info.duration, a.info.duration)
                guard end > start else { throw EditorError.invalid("sourceEnd must be after sourceStart") }
                let language = try args.string("language") ?? editor.settings.current.edits.language
                let id = await jobs.start("transcript") { job in
                    let r = try await bridge.transcribe(a, from: start, to: end, language: language, job: job)
                    let t = Transcript(id: .random("transcript"), asset: a.id, language: language, engine: "edits",
                                       sourceStart: start, sourceEnd: end, words: r.words)
                    // The project may have been closed or switched while the job ran.
                    guard let s = await editor.session, s === session else {
                        throw EditorError(.conflict, "the project was closed before the transcript arrived")
                    }
                    let applied = try await s.apply([AddTranscript(transcript: t)])
                    return .object([
                        "transcript": .string(t.id.raw), "words": .number(Double(r.words.count)),
                        "revision": .number(Double(applied.revision)),
                        "leftovers": .array(r.leftovers.map { .string($0) }),
                        "otherNewFilesInEditsLibrary": .array(r.otherNewFiles.map { .string($0) }),
                    ])
                }
                return .object(["job": .string(id)])
            },
            Tool("bridge.status", .read, "Whether Edits is running, and if so whether it is in use (a project open or an export running).") { _, _ in
                let cfg = editor.settings.current.edits
                guard EditsBridge.running(cfg.bundleID) != nil else { return .object(["running": .bool(false), "inUse": .bool(false)]) }
                let client = try EditsClient(url: cfg.url, token: cfg.token)
                let screen = (try? await client.call("appState")["screen"]?.stringValue) ?? "unreachable"
                let export = (try? await client.call("exportStatus")["state"]?.stringValue) ?? "unknown"
                return .object(["running": .bool(true), "screen": .string(screen), "export": .string(export),
                                "inUse": .bool(screen == "editor" || ["preparing", "exporting", "rendering", "running"].contains(export))])
            },
        ]
    }
}
