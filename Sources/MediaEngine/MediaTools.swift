import CoreGraphics
import EditorCore
import EditorKit
import Foundation

/// Tools that need the media engine: rendered frames now, playback in the app.
public enum MediaTools {
    public static func make(_ media: MediaContext) -> [Tool] {
        [
            Tool("frame.capture", .read, "The rendered timeline frame at a time, as an image, as export draws it, whatever range the player previews in. HDR projects are shown tone mapped to SDR.", [
                Parameter("time", .seconds, "Timeline time", required: true),
                Parameter("maxWidth", .integer, "Largest width in pixels; default 720"),
                Parameter("path", .string, "Also save the PNG to this file"),
            ]) { _, args in
                let built = try await media.composition()
                let t = try args.time("time")!.snapped(to: built.frameRate)
                let img = try await FrameCapture.timelineFrame(built, at: t, maxWidth: try args.int("maxWidth") ?? 720)
                return try imageResult(img, time: t, path: try args.string("path"))
            },
            Tool("frame.sheet", .read, "Frames over a time range in one grid image, each labelled with its time.", [
                Parameter("start", .seconds, "Range start; default 0"),
                Parameter("end", .seconds, "Range end; default the end of the project"),
                Parameter("count", .integer, "Number of frames, 1 to 48; default 12"),
                Parameter("columns", .integer, "Frames per row; default 4"),
                Parameter("frameWidth", .integer, "Width of each frame in pixels; default 240"),
                Parameter("path", .string, "Also save the PNG to this file"),
            ]) { _, args in
                let built = try await media.composition()
                let start = try args.time("start") ?? .zero
                let end = Time.min(try args.time("end") ?? built.duration, built.duration)
                let count = try args.int("count") ?? 12
                guard (1...48).contains(count) else { throw EditorError.invalid("count must be 1 to 48", parameter: "count") }
                guard end > start else { throw EditorError.invalid("end must be after start", parameter: "end") }
                let last = built.duration - built.frameRate.frameDuration
                let step = Double((end - start).ticks) / Double(count)
                var frames: [(Time, CGImage)] = []
                for i in 0..<count {
                    let t = Time.min(Time(ticks: start.ticks + Int64(step * (Double(i) + 0.5))).snapped(to: built.frameRate), last)
                    frames.append((t, try await FrameCapture.timelineFrame(built, at: t, maxWidth: try args.int("frameWidth") ?? 240)))
                }
                guard let sheet = FrameCapture.sheet(frames, columns: try args.int("columns") ?? 4) else {
                    throw EditorError(.io, "cannot draw the sheet")
                }
                return try imageResult(sheet, time: nil, path: try args.string("path"))
            },
            Tool("frame.captureSource", .read, "A frame of a media file as stored, before cuts, speed, transform or colour.", [
                Parameter("asset", .id, "Media asset id", required: true),
                Parameter("time", .seconds, "Time in the file", required: true),
                Parameter("maxWidth", .integer, "Largest width in pixels; default 720"),
                Parameter("path", .string, "Also save the PNG to this file"),
            ]) { editor, args in
                let session = try await editor.requireSession()
                let a = try await session.project.asset(EntityID(try args.requiredString("asset")))
                let t = try args.time("time")!
                let img = try await FrameCapture.sourceFrame(path: a.path, at: t, maxWidth: try args.int("maxWidth") ?? 720)
                return try imageResult(img, time: t, path: try args.string("path"))
            },
        ]
    }

    static func imageResult(_ img: CGImage, time: Time?, path: String?) throws -> JSONValue {
        let png = try FrameCapture.png(img)
        var o: [String: JSONValue] = [
            "width": .number(Double(img.width)), "height": .number(Double(img.height)),
            "images": .array([.object(["mimeType": .string("image/png"), "data": .string(png.base64EncodedString())])]),
        ]
        if let time { o["time"] = .number(time.seconds) }
        if let path {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try png.write(to: url, options: .atomic)
            o["savedTo"] = .string(url.path)
        }
        return .object(o)
    }
}
