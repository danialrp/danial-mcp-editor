import AVFoundation
import EditorCore
import EditorKit
import Foundation

/// Voice-over (A-1): records the microphone into the project and puts the
/// take on a "Voice" audio track where recording started.
public actor VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var startedAt: Time = .zero
    private var trackName = "Voice"
    private var began: Date?

    public init() {}

    public var isRecording: Bool { recorder?.isRecording ?? false }

    /// Asks for the microphone if macOS has not been told yet.
    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            // macOS asks the owner once; nobody may be there to answer.
            return await withTaskGroup(of: Bool.self) { g in
                g.addTask { await AVCaptureDevice.requestAccess(for: .audio) }
                g.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return false }
                let first = await g.next() ?? false
                g.cancelAll()
                return first
            }
        default: return false
        }
    }

    public func start(package: URL, at t: Time, track: String, settings s: UserSettings.VoiceSettings) async throws -> URL {
        guard recorder == nil else { throw EditorError(.conflict, "already recording; stop first") }
        guard await Self.microphoneAllowed() else {
            throw EditorError(.io, "the microphone is not allowed for this app (or the question went unanswered for 30 s); the owner allows it when macOS asks, or in System Settings › Privacy & Security › Microphone")
        }
        let folder = package.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("voice-\(stamp).m4a")
        let r = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: s.sampleRate, AVNumberOfChannelsKey: s.channels,
            AVEncoderBitRateKey: s.bitrateKbps * 1000, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ])
        guard r.prepareToRecord(), r.record() else { throw EditorError(.io, "the microphone could not start recording") }
        recorder = r
        file = url
        startedAt = t
        trackName = track
        began = Date()
        return url
    }

    /// Stops and returns the take: its file, where it starts and the track name.
    public func stop() throws -> (file: URL, at: Time, track: String, seconds: Double) {
        guard let r = recorder, let file else { throw EditorError(.conflict, "not recording") }
        r.stop()
        recorder = nil
        self.file = nil
        return (file, startedAt, trackName, began.map { Date().timeIntervalSince($0) } ?? 0)
    }

    public func status() -> JSONValue {
        .object(["recording": .bool(isRecording), "since": began.map { .number(Date().timeIntervalSince($0)) } ?? .null,
                 "at": .number(startedAt.seconds)])
    }
}

extension MediaTools {
    /// Voice-over recording tools.
    public static func voiceTools(_ media: MediaContext, player: PlayerController, recorder: VoiceRecorder) -> [Tool] {
        let pl = Unchecked(player)
        return [Tool("audio.record", .write, "Voice-over: start or stop recording the microphone (toggle switches). Recording starts at a timeline time (default the playhead) and, by default, plays the timeline meanwhile; stop puts the take on an audio track named Voice (made when missing) at that time, in one undo step. The file is kept in the project's audio folder.", [
            Parameter("action", .oneOf(["start", "stop", "toggle", "status"]), "start, stop, toggle or status", required: true),
            Parameter("at", .seconds, "Where the take starts; default the playhead"),
            Parameter("track", .string, "Name of the audio track; default Voice"),
            Parameter("play", .boolean, "Play the timeline while recording; default true"),
        ]) { editor, args in
            let session = try await editor.requireSession()
            var action = try args.requiredString("action")
            if action == "status" { return await recorder.status() }
            if action == "toggle" { action = await recorder.isRecording ? "stop" : "start" }
            let play = try args.bool("play") ?? true
            if action == "start" {
                let playhead = await MainActor.run { pl.value.currentTime }
                let at = try args.time("at") ?? playhead
                let url = try await recorder.start(package: session.url, at: await session.project.snap(at, "at"),
                                                   track: try args.string("track") ?? "Voice", settings: editor.settings.current.voice)
                if play {
                    await pl.value.seek(at)
                    await MainActor.run { pl.value.play() }
                }
                return .object(["recording": .bool(true), "file": .string(url.path), "at": .number(at.seconds)])
            }
            let take = try await recorder.stop()
            if play { await MainActor.run { pl.value.pause() } }
            let info = try await editor.prober.probe(take.file)
            let asset = MediaAsset(id: .random("media"), path: take.file.path, name: take.file.lastPathComponent,
                                   fingerprint: try Editor.fingerprint(take.file), info: info)
            let p = await session.project
            var commands: [StoredCommand] = [try StoredCommand(AddMedia(assets: [asset]))]
            let clipID = EntityID.random("clip")
            let range = TimeRange(start: take.at, duration: info.duration)
            var trackID = p.tracks.first { $0.kind == .audio && $0.name == take.track && !$0.locked && $0.overlapping(range).isEmpty }?.id
            if trackID == nil {
                let id = EntityID.random("track")
                commands.append(StoredCommand(name: "track.add", args: .object(["kind": .string("audio"), "name": .string(take.track), "id": .string(id.raw)])))
                trackID = id
            }
            commands.append(StoredCommand(name: "clip.add", args: .object(["track": .string(trackID!.raw), "asset": .string(asset.id.raw),
                                                                           "id": .string(clipID.raw), "start": .number(take.at.seconds)])))
            let r = try await session.applyStored(commands)
            await media.invalidate()
            return .object(["clip": .string(clipID.raw), "track": .string(trackID!.raw), "file": .string(take.file.path),
                            "seconds": .number(info.duration.seconds), "revision": .number(Double(r.revision))])
        }]
    }
}
