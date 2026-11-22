import AVFoundation
import Foundation

// Phase 0 measurement tool. Usage is in docs/phase0.md.

func arg(_ name: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--\(name)"), i + 1 < a.count { return a[i + 1] }
    return fallback
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    usage:
      dme-probe playback <source> [--cuts 500] [--speed 1.22] [--seconds 30] [--input native|half|bgra] [--scale 0.5] [--no-compositor]
      dme-probe export   <source> <out.mov> [--cuts 500] [--speed 1.22] [--segment 2] [--hdr]
      dme-probe sync     <file>
      dme-probe compare  <source> <exported> [--hdr]
      dme-probe pitch    <tone.wav> [--voice <file> --out <dir>] [--speed 1.22]
    """)
    exit(2)
}

let source = URL(fileURLWithPath: args[2])
MetalCompositor.input = MetalCompositor.Input(rawValue: arg("input", "native")) ?? .native
if args.contains("--hdr") {
    MetalCompositor.matrix = YUV.rec2020
}

do {
    switch args[1] {
    case "playback":
        try await runPlayback(source: source,
                              cuts: Int(arg("cuts", "500"))!,
                              speed: Double(arg("speed", "1.22"))!,
                              seconds: Double(arg("seconds", "30"))!,
                              scale: Double(arg("scale", "1"))!)
    case "export":
        try await runSegmentExport(source: source,
                                   output: URL(fileURLWithPath: args[3]),
                                   cuts: Int(arg("cuts", "500"))!,
                                   speed: Double(arg("speed", "1.22"))!,
                                   segmentSeconds: Double(arg("segment", "2"))!,
                                   hdr: args.contains("--hdr"))
    case "formats":
        // Which pixel format the decoder hands the compositor when nothing is requested.
        MetalCompositor.input = .raw
        for path in args.dropFirst(2) {
            let cc = try await buildCutComposition(source: URL(fileURLWithPath: path), cuts: 0, speed: 1)
            let reader = try AVAssetReader(asset: cc.composition)
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: try await cc.composition.loadTracks(withMediaType: .video), videoSettings: nil)
            out.videoComposition = cc.videoComposition
            reader.add(out)
            reader.startReading()
            for _ in 0..<5 { _ = out.copyNextSampleBuffer() }
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(MetalCompositor.formats.all())")
        }
    case "sync":
        try await runSync(file: source)
    case "compare":
        try await runCompare(source: source, exported: URL(fileURLWithPath: args[3]), hdr: args.contains("--hdr"))
    case "pitch":
        try await runPitch(tone: source,
                           voice: args.contains("--voice") ? URL(fileURLWithPath: arg("voice", "")) : nil,
                           outDir: URL(fileURLWithPath: arg("out", "local/probe-results")),
                           speed: Double(arg("speed", "1.22"))!)
    default:
        print("unknown command \(args[1])")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
